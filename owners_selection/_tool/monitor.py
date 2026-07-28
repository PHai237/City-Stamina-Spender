from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

import cv2
import numpy as np

from play import (
    WORKSPACE,
    capture_region,
    click,
    find_template,
    find_template_multiscale,
    find_nte_window,
    human_sleep,
    is_elevated,
    log,
    scale_point,
    scale_local_point,
    scale_region,
    scale_template,
    ui_scale,
)


# Coordinates relative to the 1280x720 NTE client area.
OBJECTIVES_REGION = {"left": 1000, "top": 90, "width": 265, "height": 155}
GAMEPLAY_TITLE_REGION = {"left": 990, "top": 10, "width": 280, "height": 60}
REVENUE_ROW_REGION = {"left": 1140, "top": 60, "width": 120, "height": 30}
STAR_CENTERS = [(219, 32), (219, 76), (219, 118)]
EXIT_POINT = (30, 30)
GAMEPLAY_TITLE_TEMPLATE = cv2.imread(
    str(WORKSPACE / "stage_1_9_assets/gameplay_1_9_title.png"), cv2.IMREAD_GRAYSCALE
)
CHALLENGE_REGION = {"left": 350, "top": 85, "width": 580, "height": 115}
CLAIM_REGION = {"left": 640, "top": 500, "width": 270, "height": 110}
CLAIM_POINT = (775, 558)
CHALLENGE_TEMPLATE = cv2.imread(
    str(WORKSPACE / "loop_assets/challenge_successful_title.png"), cv2.IMREAD_GRAYSCALE
)
CLAIM_TEMPLATE = cv2.imread(
    str(WORKSPACE / "loop_assets/claim_button.png"), cv2.IMREAD_GRAYSCALE
)
CLAIM_COST_12_TEMPLATE = cv2.imread(
    str(WORKSPACE / "loop_assets/claim_cost_12.png"), cv2.IMREAD_GRAYSCALE
)
CLAIM_COST_8_TEMPLATE = cv2.imread(
    str(WORKSPACE / "loop_assets/claim_cost_8.png"), cv2.IMREAD_GRAYSCALE
)
DEBUG_DIR = WORKSPACE / "gameplay_exit_debug"
REVENUE_SAMPLE_DIR = WORKSPACE / "revenue_samples"
REVENUE_DIGIT_DIR = WORKSPACE / "loop_assets/revenue_digits"
REVENUE_DIGIT_SIZE = (18, 28)
REVENUE_DIGIT_TEMPLATES: dict[str, list[np.ndarray]] | None = None


def configure_console_encoding() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def relaunch_as_admin() -> bool:
    script = str(Path(__file__).resolve())
    parameters = subprocess.list2cmdline([script, *sys.argv[1:], "--elevated-child"])
    result = __import__("ctypes").windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, parameters, str(Path.cwd()), 1
    )
    return result > 32


def star_is_lit(image: np.ndarray, center: tuple[int, int]) -> tuple[bool, float]:
    x, y = center
    roi = image[max(0, y - 13) : y + 14, max(0, x - 13) : x + 14]
    hsv = cv2.cvtColor(roi, cv2.COLOR_BGR2HSV)
    yellow = cv2.inRange(hsv, np.array([15, 100, 130]), np.array([45, 255, 255]))
    ratio = float(np.count_nonzero(yellow)) / yellow.size
    return ratio >= 0.12, ratio


def revenue_is_1500(client: dict[str, int]) -> tuple[bool, int, int, float]:
    image = capture_revenue_region(client)
    cv2.imwrite(str(DEBUG_DIR / "latest_revenue_region.png"), image)
    current = read_revenue_value(image)
    if current is not None:
        return current >= 1500, current, current, 1.0
    return revenue_metrics(image, client)


def capture_revenue_region(client: dict[str, int]) -> np.ndarray:
    import mss

    scaled_region = scale_region(client, REVENUE_ROW_REGION, "right")
    region = {
        "left": client["left"] + scaled_region["left"],
        "top": client["top"] + scaled_region["top"],
        "width": scaled_region["width"],
        "height": scaled_region["height"],
    }
    with mss.MSS() as sct:
        raw = np.asarray(sct.grab(region))
    return cv2.cvtColor(raw, cv2.COLOR_BGRA2BGR)


def revenue_metrics(
    image: np.ndarray,
    client: dict[str, int],
) -> tuple[bool, int, int, float]:
    scale = ui_scale(client)
    current_end = max(1, round(55 * scale))
    target_start = min(image.shape[1] - 1, max(current_end + 1, round(60 * scale)))
    target_end = min(image.shape[1], max(target_start + 1, round(115 * scale)))
    current_value = image[:, :current_end]
    target_value = image[:, target_start:target_end]
    hsv = cv2.cvtColor(current_value, cv2.COLOR_BGR2HSV)
    yellow = cv2.inRange(hsv, np.array([15, 100, 130]), np.array([45, 255, 255]))

    projection = np.any(yellow > 0, axis=0)
    groups = 0
    in_group = False
    for occupied in projection:
        if occupied and not in_group:
            groups += 1
            in_group = True
        elif not occupied:
            in_group = False
    occupied_x = np.flatnonzero(projection)
    span = int(occupied_x[-1] - occupied_x[0] + 1) if occupied_x.size else 0

    target_gray = cv2.cvtColor(target_value, cv2.COLOR_BGR2GRAY)
    _, target_binary = cv2.threshold(target_gray, 120, 255, cv2.THRESH_BINARY)

    def normalize_text(mask: np.ndarray) -> np.ndarray | None:
        y_positions, x_positions = np.where(mask > 0)
        if not x_positions.size:
            return None
        cropped = mask[
            y_positions.min() : y_positions.max() + 1,
            x_positions.min() : x_positions.max() + 1,
        ]
        return cv2.resize(cropped, (64, 24), interpolation=cv2.INTER_NEAREST)

    normalized_current = normalize_text(yellow)
    normalized_target = normalize_text(target_binary)
    similarity = (
        float(
            cv2.matchTemplate(
                normalized_current, normalized_target, cv2.TM_CCOEFF_NORMED
            )[0, 0]
        )
        if normalized_current is not None and normalized_target is not None
        else 0.0
    )

    # The current value is 1,500 when it has the expected five-character width,
    # and its shape closely matches the fixed "/ 1,500" target shown beside it.
    reached = groups >= 4 and span >= 32 and similarity >= 0.60
    return reached, groups, span, similarity


def load_revenue_digit_templates() -> dict[str, list[np.ndarray]]:
    global REVENUE_DIGIT_TEMPLATES
    if REVENUE_DIGIT_TEMPLATES is not None:
        return REVENUE_DIGIT_TEMPLATES

    templates: dict[str, list[np.ndarray]] = {str(digit): [] for digit in range(10)}
    for path in sorted(REVENUE_DIGIT_DIR.glob("*.png")):
        digit = path.stem.split("_", 1)[0]
        image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if digit in templates and image is not None:
            templates[digit].append(image)
    REVENUE_DIGIT_TEMPLATES = templates
    return templates


def normalize_digit(mask: np.ndarray) -> np.ndarray:
    return cv2.resize(mask, REVENUE_DIGIT_SIZE, interpolation=cv2.INTER_NEAREST)


def classify_revenue_digit(mask: np.ndarray) -> tuple[str, float] | None:
    templates = load_revenue_digit_templates()
    normalized = normalize_digit(mask)
    best: tuple[str, float] | None = None
    for digit, digit_templates in templates.items():
        for template in digit_templates:
            score = float(cv2.matchTemplate(normalized, template, cv2.TM_CCOEFF_NORMED)[0, 0])
            if best is None or score > best[1]:
                best = digit, score
    if best and best[1] >= 0.45:
        return best
    return None


def read_revenue_value(image: np.ndarray) -> int | None:
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    yellow = cv2.inRange(hsv, np.array([15, 80, 100]), np.array([45, 255, 255]))
    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(yellow, 8)

    components = []
    for label in range(1, num_labels):
        x, y, width, height, area = stats[label]
        # Current revenue is yellow; comma is lower/smaller and ignored here.
        if area >= 20 and height >= 10 and y < image.shape[0] * 0.68:
            components.append((int(x), int(y), int(width), int(height), label))
    components.sort(key=lambda item: item[0])
    if not components:
        return None

    digits = []
    scores = []
    for x, y, width, height, label in components:
        crop = (labels[y : y + height, x : x + width] == label).astype("uint8") * 255
        padded = np.zeros((height + 6, width + 6), dtype="uint8")
        padded[3 : 3 + height, 3 : 3 + width] = crop
        classified = classify_revenue_digit(padded)
        if not classified:
            return None
        digit, score = classified
        digits.append(digit)
        scores.append(score)

    try:
        value = int("".join(digits))
    except ValueError:
        return None
    log(
        f"Read revenue value={value} digits={''.join(digits)} "
        + "scores="
        + ",".join(f"{score:.2f}" for score in scores)
    )
    return value


def check_objectives(
    client: dict[str, int],
) -> tuple[bool, bool, int | None, list[float], np.ndarray, int, int, float]:
    # Capture color separately because star completion is encoded by yellow saturation.
    import mss

    scaled_region = scale_region(client, OBJECTIVES_REGION, "right")
    region = {
        "left": client["left"] + scaled_region["left"],
        "top": client["top"] + scaled_region["top"],
        "width": scaled_region["width"],
        "height": scaled_region["height"],
    }
    with mss.MSS() as sct:
        raw = np.asarray(sct.grab(region))
    image = cv2.cvtColor(raw, cv2.COLOR_BGRA2BGR)
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(DEBUG_DIR / "latest_objectives_region.png"), image)

    states = [star_is_lit(image, scale_local_point(client, center)) for center in STAR_CENTERS]
    ratios = [state[1] for state in states]
    all_three_lit = all(state[0] for state in states)
    revenue_image = capture_revenue_region(client)
    cv2.imwrite(str(DEBUG_DIR / "latest_revenue_region.png"), revenue_image)
    revenue_value = read_revenue_value(revenue_image)
    if revenue_value is not None:
        revenue_reached = revenue_value >= 1500
        revenue_groups = revenue_value
        revenue_span = revenue_value
        revenue_similarity = 1.0
    else:
        revenue_reached, revenue_groups, revenue_span, revenue_similarity = revenue_metrics(
            revenue_image,
            client,
        )
    return (
        all_three_lit,
        revenue_reached,
        revenue_value,
        ratios,
        image,
        revenue_groups,
        revenue_span,
        revenue_similarity,
    )


def is_stage_1_9_gameplay(client: dict[str, int]) -> bool:
    if GAMEPLAY_TITLE_TEMPLATE is None:
        return False
    image = capture_region(client, GAMEPLAY_TITLE_REGION, "right")
    return find_template(image, scale_template(GAMEPLAY_TITLE_TEMPLATE, client), 0.55) is not None


def save_debug(
    image: np.ndarray,
    centers: list[tuple[int, int]],
    ratios: list[float],
    path: Path,
) -> None:
    debug = image.copy()
    for center, ratio in zip(centers, ratios):
        cv2.circle(debug, center, 19, (0, 0, 255), 2)
        cv2.putText(
            debug,
            f"{ratio:.2f}",
            (center[0] - 42, center[1] + 5),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.45,
            (0, 0, 255),
            1,
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(path), debug)


def click_claim_if_visible(target: dict) -> bool:
    challenge = capture_region(target["client"], CHALLENGE_REGION, "center")
    claim_area = capture_region(target["client"], CLAIM_REGION, "center")
    challenge_match = find_template(
        challenge, scale_template(CHALLENGE_TEMPLATE, target["client"]), 0.45
    )
    claim_match = find_template(
        claim_area, scale_template(CLAIM_TEMPLATE, target["client"]), 0.70
    )
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(DEBUG_DIR / "latest_challenge_region.png"), challenge)
    cv2.imwrite(str(DEBUG_DIR / "latest_claim_region.png"), claim_area)
    bright = cv2.inRange(claim_area, 170, 255)
    bright_ratio = float(cv2.countNonZero(bright)) / bright.size
    if not challenge_match:
        log(
            "Challenge Successful not verified; skip Claim "
            f"challenge=0.000 claim={(claim_match[3] if claim_match else 0):.3f} "
            f"bright={bright_ratio:.3f}"
        )
        return False
    if not claim_match and bright_ratio < 0.35:
        return False

    spent = detect_claim_cost(claim_area)
    log(
        "Verified Claim button "
        f"claim={(claim_match[3] if claim_match else 0):.3f} "
        f"challenge={(challenge_match[3] if challenge_match else 0):.3f}"
        f" bright={bright_ratio:.3f} spent={spent}"
    )
    human_sleep(0.4, 0.35)
    claim_rel_x, claim_rel_y = scale_point(target["client"], CLAIM_POINT, "center")
    click(
        target["hwnd"],
        target["client"]["left"] + claim_rel_x,
        target["client"]["top"] + claim_rel_y,
    )
    print("Da thay Claim va bam Claim.")
    print(f"SPENT_AMOUNT={spent}")
    return True


def detect_claim_cost(claim_area: np.ndarray) -> int:
    cost_scores: list[tuple[int, float]] = []
    if CLAIM_COST_12_TEMPLATE is not None:
        match_12 = find_template_multiscale(claim_area, CLAIM_COST_12_TEMPLATE, 0.0)
        if match_12:
            cost_scores.append((12, match_12[3]))
    if CLAIM_COST_8_TEMPLATE is not None:
        match_8 = find_template_multiscale(claim_area, CLAIM_COST_8_TEMPLATE, 0.0)
        if match_8:
            cost_scores.append((8, match_8[3]))

    if not cost_scores:
        log("Claim cost templates missing or not comparable; fallback spent=8")
        return 8

    cost, score = max(cost_scores, key=lambda item: item[1])
    log(
        "Detected claim cost candidate "
        + " ".join(f"{candidate}={candidate_score:.3f}" for candidate, candidate_score in cost_scores)
    )
    if score >= 0.70:
        return cost

    log(f"Claim cost score too low ({score:.3f}); fallback spent=8")
    return 8


def wait_for_challenge_and_claim(timeout: float = 15.0) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        target = find_nte_window()
        if not target:
            return 2
        if click_claim_if_visible(target):
            return 0
        human_sleep(0.35, 0.35)
    print("Khong xac minh duoc man Challenge Successful/Claim.")
    return 5


def monitor_and_exit(
    timeout: float,
    interval: float,
    wait_for_3_stars: bool = False,
) -> int:
    deadline = None if timeout <= 0 else time.monotonic() + timeout
    while deadline is None or time.monotonic() < deadline:
        target = find_nte_window()
        if not target:
            print("Khong tim thay cua so NTE.")
            return 2

        if not is_stage_1_9_gameplay(target["client"]):
            if click_claim_if_visible(target):
                return 0
            human_sleep(interval, 0.25)
            continue

        (
            all_three_lit,
            revenue_reached,
            revenue_value,
            ratios,
            image,
            revenue_groups,
            revenue_span,
            revenue_similarity,
        ) = check_objectives(target["client"])
        if revenue_value is not None:
            print(f"REVENUE_VALUE={revenue_value}")
        ready = all_three_lit or (revenue_reached and not wait_for_3_stars)
        if revenue_reached and not all_three_lit and wait_for_3_stars:
            log(
                "Revenue reached but waiting for 3 stars; star ratios="
                + ", ".join(f"{ratio:.3f}" for ratio in ratios)
                + f"; revenue groups={revenue_groups}, span={revenue_span}, "
                + f"similarity={revenue_similarity:.3f}"
            )
        if ready:
            reason = "3 stars" if all_three_lit else "revenue 1,500"
            log(
                f"Exit condition met by {reason}; star ratios="
                + ", ".join(f"{ratio:.3f}" for ratio in ratios)
                + f"; revenue groups={revenue_groups}, span={revenue_span}, "
                + f"similarity={revenue_similarity:.3f}"
            )
            save_debug(
                image,
                [scale_local_point(target["client"], center) for center in STAR_CENTERS],
                ratios,
                DEBUG_DIR / "exit_condition_met.png",
            )
            exit_rel_x, exit_rel_y = scale_point(target["client"], EXIT_POINT)
            exit_x = target["client"]["left"] + exit_rel_x
            exit_y = target["client"]["top"] + exit_rel_y
            log(f"Clicking exit because {reason}.")
            click(target["hwnd"], exit_x, exit_y)
            print(f"Da du dieu kien ({reason}). Da bam nut thoat.")
            return wait_for_challenge_and_claim(25.0)
        human_sleep(interval, 0.25)

    print("Het thoi gian cho, chua du dieu kien nen KHONG bam thoat.")
    return 3


def sample_revenue_and_exit(
    timeout: float,
    interval: float,
    output_dir: Path = REVENUE_SAMPLE_DIR,
) -> int:
    run_dir = output_dir / time.strftime("%Y%m%d_%H%M%S")
    run_dir.mkdir(parents=True, exist_ok=True)
    deadline = None if timeout <= 0 else time.monotonic() + timeout
    sample_index = 0
    print(f"Revenue sample run: {run_dir}")

    while deadline is None or time.monotonic() < deadline:
        target = find_nte_window()
        if not target:
            print("Khong tim thay cua so NTE.")
            return 2

        if not is_stage_1_9_gameplay(target["client"]):
            if click_claim_if_visible(target):
                return 0
            human_sleep(interval, 0.25)
            continue

        image = capture_revenue_region(target["client"])
        revenue_value = read_revenue_value(image)
        if revenue_value is not None:
            reached = revenue_value >= 1500
            groups = revenue_value
            span = revenue_value
            similarity = 1.0
            print(f"REVENUE_VALUE={revenue_value}")
        else:
            reached, groups, span, similarity = revenue_metrics(image, target["client"])
        sample_index += 1
        value_part = f"_v{revenue_value:04d}" if revenue_value is not None else ""
        cv2.imwrite(
            str(
                run_dir
                / f"{sample_index:03d}{value_part}_g{groups}_s{span}_sim{similarity:.3f}.png"
            ),
            image,
        )
        if sample_index == 1:
            print("  Line 3: Revenue sample dang chay.")

        if reached:
            print("  Line 4: Revenue dat 1,500, bam Claim.")
            log(
                f"Revenue sample reached 1500 sample={sample_index} "
                f"groups={groups} span={span} similarity={similarity:.3f}"
            )
            (
                _all_three_lit,
                _revenue_reached,
                _revenue_value,
                ratios,
                objectives,
                *_,
            ) = check_objectives(target["client"])
            save_debug(
                objectives,
                [scale_local_point(target["client"], center) for center in STAR_CENTERS],
                ratios,
                DEBUG_DIR / "exit_condition_met.png",
            )
            exit_rel_x, exit_rel_y = scale_point(target["client"], EXIT_POINT)
            click(
                target["hwnd"],
                target["client"]["left"] + exit_rel_x,
                target["client"]["top"] + exit_rel_y,
            )
            return wait_for_challenge_and_claim(25.0)

        human_sleep(interval, 0.25)

    print("Het thoi gian sample revenue, chua thay 1,500.")
    return 3


def main() -> int:
    configure_console_encoding()
    parser = argparse.ArgumentParser(
        description="Exit gameplay when revenue reaches 1,500 or all 3 stars are lit."
    )
    parser.add_argument("--timeout", type=float, default=0, help="0 means monitor forever")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--sample-revenue", action="store_true")
    parser.add_argument(
        "--revenue-sample-dir",
        default=str(REVENUE_SAMPLE_DIR),
    )
    parser.add_argument(
        "--wait-for-3-stars",
        action="store_true",
        help="Do not exit at revenue 1,500; wait until all 3 stars are lit.",
    )
    parser.add_argument("--elevated-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if not is_elevated():
        if args.elevated_child:
            print("Tien trinh con khong nhan duoc quyen Administrator.")
            return 4
        print("Dang yeu cau quyen Administrator de co the bam nut thoat...")
        return 0 if relaunch_as_admin() else 4
    if args.sample_revenue:
        return sample_revenue_and_exit(
            args.timeout,
            args.interval,
            Path(args.revenue_sample_dir),
        )
    return monitor_and_exit(args.timeout, args.interval, args.wait_for_3_stars)


if __name__ == "__main__":
    raise SystemExit(main())
