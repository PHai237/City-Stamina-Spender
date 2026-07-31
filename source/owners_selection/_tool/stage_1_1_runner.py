from __future__ import annotations

import argparse
import time

import cv2

from stage_1_1_actions import StageOneOneActions
from stage_1_1_orders import DEBUG_DIR as ORDER_DEBUG_DIR
from stage_1_1_orders import (
    ItemMatch,
    ORDER_TEMPLATES,
    detect_order_bubbles,
    match_conflicts,
    save_debug,
)
from play import click, find_nte_window, focus_window, scale_point
from monitor import (
    DEBUG_DIR as MONITOR_DEBUG_DIR,
    EXIT_POINT,
    capture_revenue_region,
    read_revenue_value,
    wait_for_challenge_and_claim,
)


ITEM_RECIPES = {
    1: "black_coffee",
    2: "white_coffee",
    3: "sandwich",
    4: "croissant",
    5: "cupcake",
    6: "tomato_juice",
}

ORDER_CONFIRMATION_SCANS = 1
REVENUE_CONFIRMATION_SCANS = 2
READY_OVERLAY_SECONDS = 5.2


def runner_log(message: str) -> None:
    print(message, flush=True)


def choose_match(matches: list[ItemMatch]) -> ItemMatch:
    kept: list[ItemMatch] = []
    for match in sorted(matches, key=lambda item: item.score, reverse=True):
        conflict_index = next(
            (
                index
                for index, existing in enumerate(kept)
                if match_conflicts(match, existing, overlap_threshold=0.45)
            ),
            None,
        )
        if conflict_index is None:
            kept.append(match)
        elif match.score > kept[conflict_index].score:
            kept[conflict_index] = match
    if len(kept) != len(matches):
        runner_log(f"ORDER_DEDUPED kept={len(kept)} dropped={len(matches) - len(kept)}")

    # Handle the leftmost visible order first. Overlapping template classes have
    # already been resolved in stage_1_1_orders.
    return sorted(kept, key=lambda match: (match.x, match.y, -match.score))[0]


def same_visible_order(previous: ItemMatch | None, current: ItemMatch) -> bool:
    if previous is None or previous.item.item_id != current.item.item_id:
        return False
    previous_center = (previous.x + previous.width / 2, previous.y + previous.height / 2)
    current_center = (current.x + current.width / 2, current.y + current.height / 2)
    tolerance_x = max(18.0, min(previous.width, current.width) * 0.55)
    tolerance_y = max(14.0, min(previous.height, current.height) * 0.55)
    return (
        abs(previous_center[0] - current_center[0]) <= tolerance_x
        and abs(previous_center[1] - current_center[1]) <= tolerance_y
    )


def read_revenue(target: dict) -> int | None:
    image = capture_revenue_region(target["client"])
    MONITOR_DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(MONITOR_DEBUG_DIR / "latest_stage_1_1_revenue_region.png"), image)
    return read_revenue_value(image)


def wait_for_ready_overlay() -> None:
    runner_log("ORDER_READY_WAIT")
    time.sleep(READY_OVERLAY_SECONDS)


def exit_and_claim(target: dict, reason: str) -> int:
    focus_window(target["hwnd"], 0.08)
    exit_rel_x, exit_rel_y = scale_point(target["client"], EXIT_POINT)
    click(
        target["hwnd"],
        target["client"]["left"] + exit_rel_x,
        target["client"]["top"] + exit_rel_y,
    )
    runner_log(f"ORDER_EXIT reason={reason}")
    result = wait_for_challenge_and_claim(25.0)
    if result == 0:
        runner_log("ORDER_CLAIMED")
    else:
        runner_log(f"ORDER_CLAIM_FAILED code={result}")
    return result


def run_stage_1_1(
    watch: float,
    interval: float,
    threshold: float,
    cooldown: float,
    revenue_goal: int = 100,
) -> int:
    deadline = None if watch <= 0 else time.monotonic() + max(1.0, watch)
    handled = 0
    scans = 0
    last_report = ""
    last_scan_log = 0.0
    last_revenue_log = 0.0
    last_revenue_value: int | None = None
    revenue_confirmations = 0
    pending_match: ItemMatch | None = None
    pending_count = 0
    last_handled_match: ItemMatch | None = None
    last_handled_until = 0.0

    runner_log(f"ORDER_RUNNER_STARTED revenue_goal={revenue_goal}")
    wait_for_ready_overlay()
    actions = StageOneOneActions()
    runner_log("ORDER_STATIONS_PREPARING")
    if not actions.prewarm():
        runner_log("ORDER_STATIONS_FAILED")
        return 9
    runner_log("ORDER_STATIONS_READY")

    while deadline is None or time.monotonic() < deadline:
        target = find_nte_window()
        if not target:
            runner_log("ORDER_RUNNER_ERROR NTE window was not found.")
            return 2
        focus_window(target["hwnd"], 0.05)
        target = find_nte_window() or target

        revenue_value = read_revenue(target)
        now = time.monotonic()
        if revenue_value is not None and (
            revenue_value != last_revenue_value or now - last_revenue_log >= 2.0
        ):
            runner_log(f"ORDER_REVENUE value={revenue_value} goal={revenue_goal}")
            last_revenue_value = revenue_value
            last_revenue_log = now

        if revenue_value is not None and revenue_value >= revenue_goal:
            revenue_confirmations += 1
            runner_log(
                f"ORDER_REVENUE_CONFIRMING value={revenue_value} "
                f"count={revenue_confirmations}/{REVENUE_CONFIRMATION_SCANS}"
            )
            if revenue_confirmations >= REVENUE_CONFIRMATION_SCANS:
                return exit_and_claim(target, f"revenue {revenue_value}/{revenue_goal}")
            time.sleep(max(0.10, interval))
            continue
        revenue_confirmations = 0

        order_image, matches = detect_order_bubbles(
            target["client"],
            threshold=threshold,
            templates=ORDER_TEMPLATES,
            multi=True,
        )
        ORDER_DEBUG_DIR.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(ORDER_DEBUG_DIR / "latest_order_scan.png"), order_image)
        save_debug(order_image, matches, ORDER_DEBUG_DIR / "latest_order_scan_marked.png")
        scans += 1
        if now - last_scan_log >= 2.0:
            runner_log(f"ORDER_SCANNING scans={scans} matches={len(matches)} handled={handled}")
            last_scan_log = now

        if not matches:
            pending_match = None
            pending_count = 0
            time.sleep(max(0.08, interval))
            continue

        report = "|".join(
            f"{match.item.item_id}:{match.x}:{match.y}:{match.score:.3f}:{match.scale:.3f}"
            for match in matches
        )
        if report != last_report:
            summary = ", ".join(
                f"{match.item.item_id}@{match.x},{match.y}:{match.score:.2f}/s{match.scale:.2f}"
                for match in matches[:6]
            )
            runner_log(f"ORDER_DETECTED {summary}")
            save_debug(
                image=order_image,
                matches=matches,
                output_path=ORDER_DEBUG_DIR / f"runner_{time.strftime('%Y%m%d_%H%M%S')}_{scans:04d}.png",
            )
            last_report = report

        match = choose_match(matches)
        item_id = match.item.item_id
        if time.monotonic() < last_handled_until and same_visible_order(last_handled_match, match):
            time.sleep(max(0.08, interval))
            continue

        if same_visible_order(pending_match, match):
            pending_count += 1
        else:
            pending_match = match
            pending_count = 1

        if pending_count < ORDER_CONFIRMATION_SCANS:
            runner_log(
                f"ORDER_CONFIRMING item={item_id} score={match.score:.3f} "
                f"scale={match.scale:.3f} count={pending_count}/{ORDER_CONFIRMATION_SCANS}"
            )
            time.sleep(max(0.08, interval))
            continue

        recipe = ITEM_RECIPES.get(item_id)
        if not recipe:
            runner_log(f"ORDER_SKIPPED item={item_id} reason=no_recipe")
            time.sleep(max(0.08, interval))
            continue

        pending_match = None
        pending_count = 0
        handled += 1
        runner_log(
            f"ORDER_HANDLING item={item_id} recipe={recipe} "
            f"score={match.score:.3f} scale={match.scale:.3f} "
            f"x={match.x} y={match.y} order={handled}"
        )
        if not actions.serve(item_id):
            runner_log(f"ORDER_FAILED item={item_id} code=9")
            return 9

        runner_log(f"ORDER_DONE item={item_id} order={handled}")
        last_handled_match = match
        last_handled_until = time.monotonic() + max(1.0, cooldown * 3.0)
        time.sleep(max(0.06, cooldown * 0.5))

    runner_log(f"ORDER_RUNNER_TIMEOUT handled={handled} revenue={last_revenue_value}")
    # Do not exit/claim on timeout: Stage 1-1 must only finish after revenue is
    # confirmed at or above the configured goal.
    return 8


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Stage 1-1 order handling.")
    parser.add_argument("--watch", type=float, default=0.0, help="0 means no timeout.")
    parser.add_argument("--interval", type=float, default=0.18)
    parser.add_argument("--threshold", type=float, default=0.82)
    parser.add_argument("--cooldown", type=float, default=0.18)
    parser.add_argument("--revenue-goal", type=int, default=100)
    args = parser.parse_args()
    return run_stage_1_1(args.watch, args.interval, args.threshold, args.cooldown, args.revenue_goal)


if __name__ == "__main__":
    raise SystemExit(main())
