from __future__ import annotations

import argparse
import json
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from play import (
    capture_client_band_color,
    capture_region,
    find_nte_window,
    find_template_multiscale,
    focus_window,
    log,
    ui_scale,
)


WORKSPACE = Path(__file__).resolve().parent
ASSET_DIR = WORKSPACE / "stage_1_1_assets" / "items"
ORDER_ASSET_DIR = WORKSPACE / "stage_1_1_assets" / "orders"
DEBUG_DIR = WORKSPACE / "stage_1_1_debug"
TUNING_PATH = WORKSPACE / "stage_1_1_tuning.json"
DEFAULT_ORDER_THRESHOLD = 0.82

# Base 1280x720 regions. Keep the first pass broad because order bubbles need
# real gameplay screenshots before we can tighten this properly.
DEFAULT_SCAN_REGION = {"left": 220, "top": 80, "width": 1040, "height": 560}
# NPC order bubbles are above the counter. Scanning lower than this picks up
# chairs, table edges, and food props that look close enough to create false
# positives, especially for sandwich/croissant.
ORDER_SCAN_REGION = {"left": 24, "top": 48, "width": 984, "height": 265}
ORDER_SCAN_RATIOS = {
    "left": 0.0,
    "top": 0.045,
    "right": 0.985,
    "bottom": 0.49,
}


def load_tuning() -> dict:
    if not TUNING_PATH.exists():
        return {}
    try:
        data = json.loads(TUNING_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        log(f"Stage 1-1 tuning could not be loaded: {exc}")
        return {}
    return data if isinstance(data, dict) else {}


def tuned_order_region() -> dict[str, int]:
    region = load_tuning().get("order_scan_region")
    if not isinstance(region, dict):
        return ORDER_SCAN_REGION
    try:
        return {
            "left": int(region["left"]),
            "top": int(region["top"]),
            "width": int(region["width"]),
            "height": int(region["height"]),
        }
    except Exception:
        return ORDER_SCAN_REGION


def tuned_order_threshold(default: float = DEFAULT_ORDER_THRESHOLD) -> float:
    value = load_tuning().get("order_threshold")
    try:
        return min(0.98, max(0.50, float(value)))
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class ItemTemplate:
    item_id: int
    key: str
    label: str
    path: Path
    min_score: float = 0.82
    bias: float = 0.0


@dataclass(frozen=True)
class ItemMatch:
    item: ItemTemplate
    x: int
    y: int
    width: int
    height: int
    score: float
    scale: float = 1.0


ITEM_TEMPLATES = [
    ItemTemplate(1, "black_coffee", "Black coffee", ASSET_DIR / "01_black_coffee.png"),
    ItemTemplate(2, "white_coffee", "White coffee", ASSET_DIR / "02_white_coffee.png"),
    ItemTemplate(3, "sandwich", "Sandwich", ASSET_DIR / "03_sandwich.png"),
    ItemTemplate(4, "croissant", "Croissant", ASSET_DIR / "04_croissant.png"),
    ItemTemplate(5, "cupcake", "Cupcake", ASSET_DIR / "05_cupcake.png"),
    ItemTemplate(6, "tomato_juice", "Tomato juice", ASSET_DIR / "06_tomato_juice.png"),
]

ORDER_TEMPLATES = [
    ItemTemplate(1, "black_coffee", "Black coffee", ORDER_ASSET_DIR / "01_black_coffee_order_icon.png", 0.82),
    ItemTemplate(2, "white_coffee", "White coffee", ORDER_ASSET_DIR / "02_white_coffee_order_icon.png", 0.84),
    ItemTemplate(3, "sandwich", "Sandwich", ORDER_ASSET_DIR / "03_sandwich_order_icon.png", 0.84),
    ItemTemplate(4, "croissant", "Croissant", ORDER_ASSET_DIR / "04_croissant_order_icon.png", 0.90),
    ItemTemplate(5, "cupcake", "Cupcake", ORDER_ASSET_DIR / "05_cupcake_order_icon.png"),
    ItemTemplate(6, "tomato_juice", "Tomato juice", ORDER_ASSET_DIR / "06_tomato_juice_order_icon.png", 0.80, 0.03),
    ItemTemplate(6, "tomato_juice_bubble", "Tomato juice", ORDER_ASSET_DIR / "06_tomato_juice_order.png", 0.72, 0.08),
]
TEMPLATE_CACHE: dict[Path, np.ndarray | None] = {}


def load_item_template(item: ItemTemplate) -> np.ndarray | None:
    if item.path in TEMPLATE_CACHE:
        return TEMPLATE_CACHE[item.path]

    template = cv2.imread(str(item.path), cv2.IMREAD_GRAYSCALE)
    if template is None:
        log(f"Stage 1-1 item template missing item={item.key} path={item.path}")
    TEMPLATE_CACHE[item.path] = template
    return template


def effective_threshold(item: ItemTemplate, requested: float) -> float:
    if item.path.parent != ORDER_ASSET_DIR:
        return requested

    # Keep each order template's tuned offset, while still allowing the CLI
    # threshold to raise/lower the whole detector consistently.
    adjusted = item.min_score + (requested - DEFAULT_ORDER_THRESHOLD)
    return min(0.98, max(0.55, adjusted))


def candidate_scales(client: dict[str, int], item: ItemTemplate) -> tuple[float, ...]:
    base = ui_scale(client)
    # Order icons change size slightly with NPC depth. Search around the actual
    # client UI scale instead of using the same absolute scales at every resolution.
    if item.path.parent == ORDER_ASSET_DIR:
        if item.key == "tomato_juice_bubble":
            multipliers = (0.72, 0.92, 1.0, 1.16)
        elif item.item_id in (1, 2, 6):
            multipliers = (0.72, 0.92, 1.0, 1.16)
        else:
            multipliers = (0.72, 0.88, 1.0, 1.14)
    else:
        multipliers = (0.78, 0.93, 1.0, 1.2) if item.item_id == 2 else (0.78, 0.93, 1.0)
    return tuple(sorted({round(base * multiplier, 3) for multiplier in multipliers}))


def overlap_ratio(a: ItemMatch, b: ItemMatch) -> float:
    left = max(a.x, b.x)
    top = max(a.y, b.y)
    right = min(a.x + a.width, b.x + b.width)
    bottom = min(a.y + a.height, b.y + b.height)
    overlap = max(0, right - left) * max(0, bottom - top)
    if overlap <= 0:
        return 0.0
    smaller = min(a.width * a.height, b.width * b.height)
    return overlap / max(1, smaller)


def detect_templates(
    client: dict[str, int],
    templates: list[ItemTemplate],
    region: dict[str, int] | None = None,
    threshold: float = 0.66,
    multi: bool = False,
) -> tuple[np.ndarray, list[ItemMatch]]:
    region = region or DEFAULT_SCAN_REGION
    image = capture_region(client, region, "left")
    matches: list[ItemMatch] = []
    for item in templates:
        template = load_item_template(item)
        if template is None:
            continue

        item_threshold = effective_threshold(item, threshold)
        scales = candidate_scales(client, item)
        if multi:
            matches.extend(
                find_template_multiscale_all(
                    image,
                    template,
                    item,
                    item_threshold,
                    scales=scales,
                )
            )
            continue

        match = find_template_multiscale(image, template, item_threshold, scales=scales)
        if not match:
            best = find_template_multiscale(image, template, 0.0, scales=scales)
            if best:
                log(
                    f"Stage 1-1 item not matched item={item.key} "
                    f"best={best[3]:.3f} threshold={item_threshold:.3f}"
                )
            continue
        location, width, height, score = match
        scale = width / max(1, template.shape[1])
        matches.append(ItemMatch(item, location[0], location[1], width, height, score, scale))

    kept = suppress_overlapping_matches(matches, overlap_threshold=0.45)
    kept.sort(key=lambda match: (match.y, match.x))
    return image, kept


def find_order_circle_candidates(image: np.ndarray, client: dict[str, int]) -> list[tuple[int, int, int]]:
    scale = ui_scale(client)
    min_radius = max(16, round(22 * scale))
    max_radius = max(min_radius + 8, round(48 * scale))
    min_distance = max(34, round(46 * scale))
    blurred = cv2.medianBlur(image, 5)
    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1.2,
        minDist=min_distance,
        param1=90,
        param2=18,
        minRadius=min_radius,
        maxRadius=max_radius,
    )
    if circles is None:
        return []

    candidates: list[tuple[int, int, int]] = []
    height, width = image.shape[:2]
    for circle in np.round(circles[0]).astype(int):
        x, y, radius = int(circle[0]), int(circle[1]), int(circle[2])
        if x - radius < 0 or y - radius < 0 or x + radius >= width or y + radius >= height:
            continue
        # Ignore the timer/clock UI near the top. NPC order bubbles sit lower.
        if y < round(56 * scale):
            continue
        # Ignore the counter/skill UI and character bodies. The order circle can
        # move with NPC height, but it remains in the upper band of this crop.
        if y > round(height * 0.74):
            continue
        candidates.append((x, y, radius))
    return candidates


def classify_order_circle(
    image: np.ndarray,
    circle: tuple[int, int, int],
    templates: list[ItemTemplate],
    threshold: float,
) -> ItemMatch | None:
    center_x, center_y, radius = circle
    pad = max(8, round(radius * 0.35))
    left = max(0, center_x - radius - pad)
    top = max(0, center_y - radius - pad)
    right = min(image.shape[1], center_x + radius + pad)
    bottom = min(image.shape[0], center_y + radius + pad)
    crop = image[top:bottom, left:right]
    if crop.size == 0:
        return None

    best: ItemMatch | None = None
    for item in templates:
        template = load_item_template(item)
        if template is None:
            continue

        base_threshold = effective_threshold(item, threshold)
        if item.item_id in (1, 2, 3, 4):
            # Coffee and bread icons are easy to confuse in grayscale. Keep
            # these strict; a missed frame is better than serving the wrong item.
            circle_threshold = base_threshold
        else:
            circle_threshold = max(0.62, base_threshold - 0.10)
        if item.key.endswith("_bubble"):
            scale_base = max(0.45, (radius * 2) / max(template.shape[0], template.shape[1]))
        else:
            scale_base = max(0.45, (radius * 1.30) / max(template.shape[0], template.shape[1]))
        scales = tuple(sorted({round(scale_base * factor, 3) for factor in (0.72, 0.86, 1.0, 1.14)}))
        matches = find_template_multiscale_all(
            crop,
            template,
            item,
            circle_threshold,
            scales=scales,
            max_per_scale=4,
        )
        if not matches:
            continue
        matches = [
            match
            for match in matches
            if item.key.endswith("_bubble")
            or icon_match_is_inside_circle(match, left, top, center_x, center_y, radius)
        ]
        if not matches:
            continue
        candidate = max(matches, key=rank_match)
        candidate = ItemMatch(
            candidate.item,
            left + candidate.x,
            top + candidate.y,
            candidate.width,
            candidate.height,
            candidate.score,
            candidate.scale,
        )
        if best is None or better_match(candidate, best):
            best = candidate
    return best


def icon_match_is_inside_circle(
    match: ItemMatch,
    crop_left: int,
    crop_top: int,
    circle_x: int,
    circle_y: int,
    radius: int,
) -> bool:
    match_center_x = crop_left + match.x + match.width / 2
    match_center_y = crop_top + match.y + match.height / 2
    dx = abs(match_center_x - circle_x)
    dy = abs(match_center_y - circle_y)

    # The visible item icon sits near the center of the circular order bubble.
    # Matches lower than the bubble are usually NPC clothing/animation effects.
    return dx <= radius * 0.78 and dy <= radius * 0.72


def detect_order_circles(
    image: np.ndarray,
    client: dict[str, int],
    templates: list[ItemTemplate],
    threshold: float,
) -> list[ItemMatch]:
    matches: list[ItemMatch] = []
    for circle in find_order_circle_candidates(image, client):
        match = classify_order_circle(image, circle, templates, threshold)
        if match is not None:
            matches.append(match)
    return suppress_overlapping_matches(matches, overlap_threshold=0.28)


def rank_match(match: ItemMatch) -> float:
    return match.score + match.item.bias


SAME_BUBBLE_CENTER_RATIO = 0.75
NEAR_MISS_CENTER_RATIO = 1.1


def match_conflicts(a: ItemMatch, b: ItemMatch, overlap_threshold: float) -> bool:
    if overlap_ratio(a, b) >= overlap_threshold:
        return True

    # The full tomato bubble template is larger than the cropped item icons.
    # Nearby centers are therefore a better same-bubble signal than IoU alone.
    center_a = (a.x + a.width / 2, a.y + a.height / 2)
    center_b = (b.x + b.width / 2, b.y + b.height / 2)
    distance_x = abs(center_a[0] - center_b[0])
    distance_y = abs(center_a[1] - center_b[1])
    max_dim = max(a.width, b.width, a.height, b.height)
    is_conflict = (
        distance_x <= max(a.width, b.width) * SAME_BUBBLE_CENTER_RATIO
        and distance_y <= max(a.height, b.height) * SAME_BUBBLE_CENTER_RATIO
    )
    if (
        not is_conflict
        and {a.item.item_id, b.item.item_id} == {4, 6}
        and distance_x <= max_dim * NEAR_MISS_CENTER_RATIO
        and distance_y <= max_dim * NEAR_MISS_CENTER_RATIO
    ):
        log(
            "Stage 1-1 item4/item6 near-miss "
            f"a={a.item.key}:{a.score:.3f}@({a.x},{a.y}) "
            f"b={b.item.key}:{b.score:.3f}@({b.x},{b.y}) "
            f"dx={distance_x:.0f} dy={distance_y:.0f}"
        )
    return is_conflict


def better_match(candidate: ItemMatch, existing: ItemMatch) -> bool:
    if candidate.item.item_id == 6 and existing.item.item_id == 4:
        return rank_match(candidate) >= existing.score - 0.08
    if candidate.item.item_id == 4 and existing.item.item_id == 6:
        return rank_match(candidate) > rank_match(existing) + 0.12

    item_pair = {candidate.item.item_id, existing.item.item_id}
    if item_pair == {4, 6}:
        tomato = candidate if candidate.item.item_id == 6 else existing
        croissant = candidate if candidate.item.item_id == 4 else existing
        tomato_rank = rank_match(tomato)
        croissant_rank = rank_match(croissant)

        # The full-bubble tomato template is independent evidence and should
        # beat a visually similar croissant icon unless croissant wins clearly.
        tomato_has_bubble_evidence = (
            tomato.item.key == "tomato_juice_bubble"
            and tomato.score >= effective_threshold(tomato.item, DEFAULT_ORDER_THRESHOLD)
        )
        if tomato_has_bubble_evidence or tomato_rank >= croissant_rank - 0.025:
            winner = tomato
        elif croissant_rank >= tomato_rank + 0.065:
            winner = croissant
        else:
            winner = tomato

        log(
            "Stage 1-1 order conflict croissant/tomato "
            f"croissant={croissant.score:.3f}/{croissant_rank:.3f} "
            f"tomato={tomato.score:.3f}/{tomato_rank:.3f} "
            f"tomato_template={tomato.item.key} winner={winner.item.key}"
        )
        return winner is candidate

    return rank_match(candidate) > rank_match(existing)


def suppress_overlapping_matches(matches: list[ItemMatch], overlap_threshold: float) -> list[ItemMatch]:
    ordered = sorted(matches, key=rank_match, reverse=True)
    kept: list[ItemMatch] = []
    for match in ordered:
        conflict_index = next(
            (
                index
                for index, existing in enumerate(kept)
                if match_conflicts(match, existing, overlap_threshold)
            ),
            None,
        )
        if conflict_index is None:
            kept.append(match)
        elif better_match(match, kept[conflict_index]):
            kept[conflict_index] = match
    return kept


def find_template_multiscale_all(
    image: np.ndarray,
    template: np.ndarray,
    item: ItemTemplate,
    threshold: float,
    scales: tuple[float, ...],
    max_per_scale: int = 18,
) -> list[ItemMatch]:
    candidates: list[ItemMatch] = []
    for scale in scales:
        width = max(1, round(template.shape[1] * scale))
        height = max(1, round(template.shape[0] * scale))
        if width > image.shape[1] or height > image.shape[0]:
            continue

        interpolation = cv2.INTER_AREA if scale <= 1.0 else cv2.INTER_CUBIC
        scaled_template = cv2.resize(template, (width, height), interpolation=interpolation)
        result = cv2.matchTemplate(image, scaled_template, cv2.TM_CCOEFF_NORMED)
        ys, xs = np.where(result >= threshold)
        if len(xs) == 0:
            continue

        scale_candidates = sorted(
            (
                ItemMatch(item, int(x), int(y), width, height, float(result[y, x]), scale)
                for x, y in zip(xs, ys)
            ),
            key=lambda match: match.score,
            reverse=True,
        )[:max_per_scale]
        candidates.extend(scale_candidates)

    return suppress_overlapping_matches(candidates, overlap_threshold=0.28)


def detect_items(
    client: dict[str, int],
    region: dict[str, int] | None = None,
    threshold: float = 0.66,
) -> tuple[np.ndarray, list[ItemMatch]]:
    return detect_templates(client, ITEM_TEMPLATES, region or DEFAULT_SCAN_REGION, threshold)


def capture_order_scan_image(
    client: dict[str, int],
    region: dict[str, int] | None,
) -> np.ndarray:
    if region is not None:
        return capture_region(client, region, "left")
    image, _ = capture_client_band_color(
        client,
        ORDER_SCAN_RATIOS["left"],
        ORDER_SCAN_RATIOS["top"],
        ORDER_SCAN_RATIOS["right"],
        ORDER_SCAN_RATIOS["bottom"],
    )
    return cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)


def detect_order_bubbles(
    client: dict[str, int],
    region: dict[str, int] | None = None,
    threshold: float = DEFAULT_ORDER_THRESHOLD,
    templates: list[ItemTemplate] | None = None,
    multi: bool = False,
) -> tuple[np.ndarray, list[ItemMatch]]:
    order_templates = templates or ORDER_TEMPLATES
    threshold = tuned_order_threshold(threshold)
    tuned_region = region
    if tuned_region is None and "order_scan_region" in load_tuning():
        tuned_region = tuned_order_region()
    image = capture_order_scan_image(client, tuned_region)
    circle_matches = detect_order_circles(image, client, order_templates, threshold)
    if circle_matches:
        return image, circle_matches

    # Fallback for unusual frames where the bubble rim is hidden or Hough misses.
    if tuned_region is None:
        template_matches: list[ItemMatch] = []
        for item in order_templates:
            template = load_item_template(item)
            if template is None:
                continue
            template_matches.extend(
                find_template_multiscale_all(
                    image,
                    template,
                    item,
                    effective_threshold(item, threshold),
                    scales=candidate_scales(client, item),
                    max_per_scale=8 if multi else 2,
                )
            )
        template_matches = suppress_overlapping_matches(template_matches, overlap_threshold=0.45)
        template_matches.sort(key=lambda match: (match.y, match.x))
    else:
        _, template_matches = detect_templates(client, order_templates, tuned_region, threshold, multi)
    return image, template_matches


def save_debug(image: np.ndarray, matches: list[ItemMatch], output_path: Path) -> None:
    debug = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    for match in matches:
        color = {
            1: (0, 180, 255),
            2: (255, 220, 120),
            4: (255, 170, 40),
            6: (40, 80, 255),
        }.get(match.item.item_id, (255, 255, 255))
        cv2.rectangle(
            debug,
            (match.x, match.y),
            (match.x + match.width, match.y + match.height),
            color,
            2,
        )
        cv2.putText(
            debug,
            f"{match.item.item_id}:{match.score:.2f} s={match.scale:.2f}",
            (match.x, max(18, match.y - 6)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.50,
            color,
            2,
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(output_path), debug)


def main() -> int:
    parser = argparse.ArgumentParser(description="Detect Stage 1-1 order/item icons on the NTE screen.")
    parser.add_argument("--threshold", type=float, default=DEFAULT_ORDER_THRESHOLD)
    parser.add_argument("--orders", action="store_true", help="Detect NPC order bubbles instead of item cards.")
    parser.add_argument("--item-id", type=int, choices=range(1, 7), help="Only detect one item id.")
    parser.add_argument("--multi", action="store_true", help="Return every visible match for the selected template.")
    parser.add_argument("--debug-dir", default=str(DEBUG_DIR))
    parser.add_argument("--watch", type=float, default=0.0, help="Seconds to keep scanning; 0 means one scan.")
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--no-focus", action="store_true")
    args = parser.parse_args()

    prefix = "orders" if args.orders else "items"
    none_line = "ORDER_MATCHES=none" if args.orders else "ITEM_MATCHES=none"
    line_prefix = "ORDER_MATCH" if args.orders else "ITEM_MATCH"
    deadline = time.monotonic() + args.watch if args.watch > 0 else None
    last_report = ""
    found_any = False

    while True:
        target = find_nte_window()
        if not target:
            print("NTE window was not found.")
            return 2
        if not args.no_focus:
            focus_window(target["hwnd"], 0.25)
            target = find_nte_window() or target

        if args.item_id:
            templates = [
                item
                for item in (ORDER_TEMPLATES if args.orders else ITEM_TEMPLATES)
                if item.item_id == args.item_id
            ]
        else:
            templates = ORDER_TEMPLATES if args.orders else ITEM_TEMPLATES

        if args.orders:
            image, matches = detect_order_bubbles(
                target["client"],
                threshold=args.threshold,
                templates=templates,
                multi=args.multi,
            )
        else:
            image, matches = detect_templates(
                target["client"],
                templates,
                DEFAULT_SCAN_REGION,
                args.threshold,
                args.multi,
            )

        timestamp = time.strftime("%Y%m%d_%H%M%S")
        save_debug(image, matches, Path(args.debug_dir) / f"{prefix}_{timestamp}.png")

        if matches:
            found_any = True
            report = "|".join(
                f"{match.item.item_id}:{match.x}:{match.y}:{match.score:.3f}:{match.scale:.3f}"
                for match in matches
            )
            if report != last_report:
                last_report = report
                for match in matches:
                    print(
                        f"{line_prefix} "
                        f"id={match.item.item_id} key={match.item.key} score={match.score:.3f} "
                        f"scale={match.scale:.3f} x={match.x} y={match.y} "
                        f"w={match.width} h={match.height}"
                    )
        elif deadline is None:
            print(none_line)
            return 3

        if deadline is None or time.monotonic() >= deadline:
            break
        time.sleep(max(0.1, args.interval))

    if not found_any:
        print(none_line)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
