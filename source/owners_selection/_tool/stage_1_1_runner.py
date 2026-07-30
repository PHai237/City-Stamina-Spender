from __future__ import annotations

import argparse
import time

import cv2

from stage_1_1_orders import DEBUG_DIR as ORDER_DEBUG_DIR
from stage_1_1_orders import ItemMatch, ORDER_TEMPLATES, detect_order_bubbles, save_debug
from stage_1_1_recipe_player import play_recipe
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

PREP_BATCH_SIZE = {
    3: 3,
    4: 3,
    5: 6,
}

AMBIGUOUS_ITEMS = {4, 6}
ORDER_CONFIRMATION_SCANS = 2
REVENUE_CONFIRMATION_SCANS = 2


def runner_log(message: str) -> None:
    print(message, flush=True)


def choose_match(matches: list[ItemMatch]) -> ItemMatch:
    # Handle the leftmost visible order first. Overlapping template classes have
    # already been resolved in stage_1_1_orders.
    return sorted(matches, key=lambda match: (match.x, match.y, -match.score))[0]


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
    stock = {item_id: 0 for item_id in PREP_BATCH_SIZE}
    last_report = ""
    last_scan_log = 0.0
    last_revenue_log = 0.0
    last_revenue_value: int | None = None
    revenue_confirmations = 0
    pending_match: ItemMatch | None = None
    pending_count = 0

    runner_log(f"ORDER_RUNNER_STARTED revenue_goal={revenue_goal}")
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
        if item_id in AMBIGUOUS_ITEMS:
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
        else:
            pending_match = None
            pending_count = 0

        recipe = ITEM_RECIPES.get(item_id)
        if not recipe:
            runner_log(f"ORDER_SKIPPED item={item_id} reason=no_recipe")
            time.sleep(max(0.08, interval))
            continue

        start_step_index = 0
        if item_id in PREP_BATCH_SIZE:
            if stock[item_id] > 0:
                start_step_index = 1
                stock[item_id] -= 1
                runner_log(f"ORDER_BUFFER_USED item={item_id} remaining={stock[item_id]}")
            else:
                stock[item_id] = PREP_BATCH_SIZE[item_id] - 1
                runner_log(f"ORDER_BUFFER_REFILLED item={item_id} remaining={stock[item_id]}")

        pending_match = None
        pending_count = 0
        handled += 1
        runner_log(
            f"ORDER_HANDLING item={item_id} recipe={recipe} "
            f"score={match.score:.3f} scale={match.scale:.3f} "
            f"x={match.x} y={match.y} order={handled}"
        )
        result = play_recipe(
            recipe,
            None,
            skip_open_shop=True,
            start_step_index=start_step_index,
            delay=0.18,
        )
        if result != 0:
            runner_log(f"ORDER_FAILED item={item_id} code={result}")
            return result

        runner_log(f"ORDER_DONE item={item_id} order={handled}")
        time.sleep(max(0.1, cooldown))

    runner_log(f"ORDER_RUNNER_TIMEOUT handled={handled} revenue={last_revenue_value}")
    # Do not exit/claim on timeout: Stage 1-1 must only finish after revenue is
    # confirmed at or above the configured goal.
    return 8


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Stage 1-1 order handling.")
    parser.add_argument("--watch", type=float, default=0.0, help="0 means no timeout.")
    parser.add_argument("--interval", type=float, default=0.18)
    parser.add_argument("--threshold", type=float, default=0.82)
    parser.add_argument("--cooldown", type=float, default=0.3)
    parser.add_argument("--revenue-goal", type=int, default=100)
    args = parser.parse_args()
    return run_stage_1_1(args.watch, args.interval, args.threshold, args.cooldown, args.revenue_goal)


if __name__ == "__main__":
    raise SystemExit(main())
