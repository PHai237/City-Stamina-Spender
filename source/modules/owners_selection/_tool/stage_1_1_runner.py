from __future__ import annotations

import argparse
import time
from typing import Any

import cv2

from stage_1_1_actions import StageOneOneActions
from stage_1_1_orders import DEBUG_DIR as ORDER_DEBUG_DIR
from stage_1_1_orders import (
    ItemMatch,
    ORDER_TEMPLATES,
    detect_order_bubbles,
    load_item_template,
    match_conflicts,
    save_debug,
)
from stage_1_1_samples import SampleRing
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
READY_OVERLAY_SECONDS = 5.2
TOMATO_JUICE_ITEM_ID = 6


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


def should_exit_after_order(
    target: dict,
    handled: int,
    tomato_juice_served: int,
    revenue_goal: int,
) -> tuple[bool, int | None, str]:
    if tomato_juice_served >= 2:
        runner_log(f"ORDER_EXIT_RULE tomato_juice={tomato_juice_served} handled={handled}")
        return True, None, "2 tomato juice orders"

    if handled < 2:
        return False, None, ""

    revenue_value = read_revenue(target)
    if revenue_value is None:
        runner_log(f"ORDER_REVENUE_UNREADABLE order={handled} goal={revenue_goal}")
        if handled >= 3:
            return True, None, "3 orders served"
        return False, None, ""
    runner_log(f"ORDER_REVENUE value={revenue_value} goal={revenue_goal}")
    if revenue_value >= revenue_goal:
        return True, revenue_value, f"revenue {revenue_value}/{revenue_goal}"
    return False, revenue_value, ""


def wait_for_ready_overlay() -> None:
    runner_log("ORDER_READY_WAIT")
    time.sleep(READY_OVERLAY_SECONDS)


def warm_order_templates() -> None:
    for template in ORDER_TEMPLATES:
        load_item_template(template)


def capture_orders(
    target: dict,
    threshold: float,
) -> tuple[Any, list[ItemMatch]]:
    return detect_order_bubbles(
        target["client"],
        threshold=threshold,
        templates=ORDER_TEMPLATES,
        multi=True,
    )


def save_order_scan(
    order_image,
    matches: list[ItemMatch],
    samples: SampleRing,
    scans: int,
    handled: int,
) -> None:
    ORDER_DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(ORDER_DEBUG_DIR / "latest_order_scan.png"), order_image)
    save_debug(order_image, matches, ORDER_DEBUG_DIR / "latest_order_scan_marked.png")
    samples.save(scans, order_image, matches, handled)


def filter_recent_order(matches: list[ItemMatch], recent: ItemMatch | None) -> list[ItemMatch]:
    if recent is None:
        return matches
    return [match for match in matches if not same_visible_order(recent, match)]


def prewarm_until_order(
    actions: StageOneOneActions,
    target: dict,
    threshold: float,
    samples: SampleRing,
    ignore_recent: ItemMatch | None = None,
) -> tuple[bool, int, Any | None, list[ItemMatch]]:
    if not actions.refresh_target():
        return False, 0, None, []
    refreshed = find_nte_window()
    if not refreshed:
        return False, 0, None, []
    target.update(refreshed)

    steps = (
        ("sandwich", lambda: True if actions.sandwich_stock > 0 else actions.refill_sandwich()),
        ("cupcake", lambda: True if actions.cupcake_stock > 0 or actions.cupcake_ready else actions.refill_cupcake()),
        ("croissant", lambda: True if actions.croissant_stock > 0 else actions.refill_croissant()),
        ("cupcake_ready", lambda: True if actions.cupcake_ready else actions.prime_cupcake()),
    )
    scans = 0
    for name, step in steps:
        order_image, matches = capture_orders(target, threshold)
        matches = filter_recent_order(matches, ignore_recent)
        scans += 1
        save_order_scan(order_image, matches, samples, scans, 0)
        if matches:
            runner_log(f"ORDER_STATION_PREP_INTERRUPTED name={name} matches={len(matches)} before_step=1")
            return True, scans, order_image, matches

        runner_log(f"ORDER_STATION_PREP name={name}")
        if not step():
            return False, scans, None, []
        refreshed = find_nte_window() or target
        target.update(refreshed)
        order_image, matches = capture_orders(target, threshold)
        matches = filter_recent_order(matches, ignore_recent)
        scans += 1
        save_order_scan(order_image, matches, samples, scans, 0)
        if matches:
            runner_log(f"ORDER_STATION_PREP_INTERRUPTED name={name} matches={len(matches)}")
            return True, scans, order_image, matches
    return True, scans, None, []


def stations_are_ready(actions: StageOneOneActions) -> bool:
    return actions.sandwich_stock > 0 and actions.croissant_stock > 0 and (
        actions.cupcake_ready or actions.cupcake_stock > 0
    )


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
    last_revenue_value: int | None = None
    tomato_juice_served = 0
    pending_match: ItemMatch | None = None
    pending_count = 0
    last_handled_match: ItemMatch | None = None
    last_handled_until = 0.0
    samples = SampleRing()
    queued_order_image: Any | None = None
    queued_matches: list[ItemMatch] = []
    stations_ready = False

    runner_log(f"ORDER_RUNNER_STARTED revenue_goal={revenue_goal}")
    warm_order_templates()
    wait_for_ready_overlay()
    actions = StageOneOneActions()
    runner_log("ORDER_STATIONS_PREPARING")
    prepared, prep_scans, queued_order_image, queued_matches = prewarm_until_order(
        actions,
        find_nte_window() or {},
        threshold,
        samples,
    )
    scans += prep_scans
    if not prepared:
        runner_log("ORDER_STATIONS_FAILED")
        return 9
    if queued_matches:
        runner_log("ORDER_STATIONS_PAUSED_FOR_ORDER")
    else:
        stations_ready = stations_are_ready(actions)
        runner_log("ORDER_STATIONS_READY")

    while deadline is None or time.monotonic() < deadline:
        target = find_nte_window()
        if not target:
            runner_log("ORDER_RUNNER_ERROR NTE window was not found.")
            return 2
        focus_window(target["hwnd"], 0.05)
        target = find_nte_window() or target

        now = time.monotonic()

        if queued_matches:
            order_image = queued_order_image
            matches = queued_matches
            queued_order_image = None
            queued_matches = []
        else:
            order_image, matches = capture_orders(target, threshold)
            scans += 1
            save_order_scan(order_image, matches, samples, scans, handled)
        if now - last_scan_log >= 2.0:
            runner_log(f"ORDER_SCANNING scans={scans} matches={len(matches)} handled={handled}")
            last_scan_log = now

        if not matches:
            pending_match = None
            pending_count = 0
            if not stations_ready:
                prepared, prep_scans, queued_order_image, queued_matches = prewarm_until_order(
                    actions,
                    target,
                    threshold,
                    samples,
                    last_handled_match,
                )
                scans += prep_scans
                if not prepared:
                    runner_log("ORDER_STATIONS_FAILED")
                    return 9
                stations_ready = stations_are_ready(actions) and not queued_matches
                if queued_matches:
                    runner_log("ORDER_STATIONS_PAUSED_FOR_ORDER")
                    continue
                runner_log("ORDER_STATIONS_READY")
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
            if order_image is not None:
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

        stations_ready = stations_are_ready(actions)
        if item_id == TOMATO_JUICE_ITEM_ID:
            tomato_juice_served += 1
        runner_log(f"ORDER_DONE item={item_id} order={handled}")
        should_exit, revenue_value, exit_reason = should_exit_after_order(
            target,
            handled,
            tomato_juice_served,
            revenue_goal,
        )
        if revenue_value is not None:
            last_revenue_value = revenue_value
        if should_exit:
            return exit_and_claim(target, exit_reason)
        if not stations_ready:
            prepared, prep_scans, queued_order_image, queued_matches = prewarm_until_order(
                actions,
                target,
                threshold,
                samples,
                match,
            )
            scans += prep_scans
            if not prepared:
                runner_log("ORDER_STATIONS_FAILED")
                return 9
            stations_ready = stations_are_ready(actions) and not queued_matches
            if queued_matches:
                runner_log("ORDER_STATIONS_PAUSED_FOR_ORDER")
            else:
                runner_log("ORDER_STATIONS_READY")
        last_handled_match = match
        last_handled_until = time.monotonic() + max(0.22, cooldown * 1.4)
        time.sleep(max(0.03, cooldown * 0.3))

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
