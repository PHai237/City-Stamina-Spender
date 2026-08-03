from __future__ import annotations

import argparse
import contextlib
import ctypes
import io
import queue
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path

import cv2

from play import main as play_main
from play import (
    WORKSPACE,
    capture_region,
    find_nte_window,
    focus_window,
    human_sleep,
    is_owner_selection_screen,
    log,
    find_template_multiscale,
)
from stage_1_1_tuner import run_tune


OWNER_TEMPLATE = cv2.imread(
    str(WORKSPACE / "loop_assets/owners_selection_title.png"), cv2.IMREAD_GRAYSCALE
)
ENERGY_0_TEMPLATE = cv2.imread(
    str(WORKSPACE / "loop_assets/energy_0_700.png"), cv2.IMREAD_GRAYSCALE
)
ENERGY_REGION = {"left": 1050, "top": 18, "width": 140, "height": 32}
DEFAULT_MIN_SPEND_PER_CYCLE = 8
STAGE_1_1_ITEM_NAMES = {
    1: "Black coffee",
    2: "White coffee",
    3: "Sandwich",
    4: "Croissant",
    5: "Cupcake",
    6: "Tomato juice",
}


def format_amount(value: int) -> str:
    return f"{value:,}"


def configure_console_encoding() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def is_admin() -> bool:
    return bool(ctypes.windll.shell32.IsUserAnAdmin())


def relaunch_as_admin() -> bool:
    parameters = subprocess.list2cmdline(
        [str(Path(__file__).resolve()), *sys.argv[1:], "--elevated-child"]
    )
    return (
        ctypes.windll.shell32.ShellExecuteW(
            None, "runas", sys.executable, parameters, str(WORKSPACE), 1
        )
        > 32
    )


def wait_for_owner_selection(timeout: float) -> bool:
    log(f"Waiting for Owner's Selection timeout={timeout}")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        target = find_nte_window()
        if target:
            focus_window(target["hwnd"], 0.08)
            target = find_nte_window()
            if not target:
                human_sleep(0.4, 0.35)
                continue
            log(
                "Owner wait target "
                f"hwnd={target['hwnd']} title={target['title']!r} "
                f"client={target['client']}"
            )
            if is_owner_selection_screen(target["client"], OWNER_TEMPLATE):
                log("Owner's Selection verified")
                return True
        else:
            log("Owner wait did not find NTE")
        human_sleep(0.4, 0.35)
    log("Owner's Selection wait timed out")
    return False


def current_energy_digit_count(image) -> int | None:
    _, binary = cv2.threshold(image, 180, 255, cv2.THRESH_BINARY)
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    boxes: list[tuple[int, int, int, int]] = []
    for contour in contours:
        x, y, width, height = cv2.boundingRect(contour)
        if height < 9 or width < 2 or width > 18:
            continue
        boxes.append((x, y, width, height))

    boxes.sort()
    slash_candidates = [
        (x, y, width, height)
        for x, y, width, height in boxes
        if 4 <= width <= 9 and height >= 12
    ]
    if not slash_candidates:
        return None

    slash_x = slash_candidates[0][0]
    current_digits = [
        box
        for box in boxes
        if box[0] < slash_x and box[2] >= 6
    ]
    return len(current_digits)


def energy_is_empty() -> bool:
    if ENERGY_0_TEMPLATE is None:
        return False
    target = find_nte_window()
    if not target:
        return False
    image = capture_region(target["client"], ENERGY_REGION, "right")
    debug_path = WORKSPACE / "stage_1_9_debug/latest_energy_region.png"
    debug_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(debug_path), image)

    digit_count = current_energy_digit_count(image)
    if digit_count is not None:
        log(f"Energy current digit count before slash={digit_count}")
        if digit_count > 1:
            return False

    match = find_template_multiscale(image, ENERGY_0_TEMPLATE, 0.78)
    if not match:
        return False

    (x, y), width, height, score = match
    # Avoid matching the trailing "0/700" inside values like 50/700 or 150/700.
    # Multi-digit values are filtered above. Empty energy is right-aligned in
    # this crop, so x is not stable enough to use as a hard guard.
    starts_at_value_left = x <= max(4, round(width * 0.08))
    is_single_zero = digit_count == 1 and score >= 0.95
    log(
        "Energy 0/700 candidate "
        f"score={score:.3f} x={x} y={y} w={width} h={height} "
        f"starts_at_value_left={starts_at_value_left} single_zero={is_single_zero}"
    )
    return starts_at_value_left or is_single_zero


def run_cycle(
    compact: bool,
    first_line: int = 2,
    stage: str = "1-9",
    skip_support_employee_check: bool = False,
    verify_timeout: float | None = None,
) -> tuple[int, int | None, int]:
    child_lines, wait_for_child = start_play_cycle(stage, skip_support_employee_check, verify_timeout)
    stage_label = f"stage {stage}"
    spent = None
    opened_shop = False
    reached_exit = False
    revenue_milestones: set[int] = set()
    stage_1_1_revenue_bucket = -1
    last_stage_1_1_scan: tuple[int, int] | None = None
    line_number = first_line

    def emit(message: str) -> None:
        nonlocal line_number
        print(f"  Line {line_number}: {message}")
        line_number += 1

    for line in child_lines:
        stripped = line.rstrip()
        if compact:
            log(f"child stdout: {stripped}")
        if not compact:
            print(line, end="")
        elif "Da bam Open Shop." in line and not opened_shop:
            opened_shop = True
            emit(f"{stage_label.capitalize()} found, clicked Open Shop.")
            if stage == "1-1":
                emit("Handling orders.")
            else:
                emit("Revenue is updating.")
        elif stage == "1-1" and stripped.startswith("ORDER_RUNNER_STARTED"):
            emit("Order handling started.")
        elif stage == "1-1" and stripped.startswith("ORDER_SCANNING "):
            parts = dict(
                part.split("=", 1)
                for part in stripped.split()[1:]
                if "=" in part
            )
            try:
                matches = int(parts.get("matches", "0"))
                handled = int(parts.get("handled", "0"))
            except ValueError:
                matches = 0
                handled = 0
            scan_state = (matches, handled)
            if scan_state != last_stage_1_1_scan:
                last_stage_1_1_scan = scan_state
                emit(f"Order scan: {matches} NPC / {matches} orders.")
        elif stage == "1-1" and stripped.startswith("ORDER_DETECTED "):
            emit("Order detected.")
        elif stage == "1-1" and stripped.startswith("ORDER_REVENUE "):
            parts = dict(
                part.split("=", 1)
                for part in stripped.split()[1:]
                if "=" in part
            )
            try:
                value = int(parts.get("value", "-1"))
                goal = int(parts.get("goal", "100"))
            except ValueError:
                value = -1
                goal = 100
            if value >= 0:
                bucket_size = max(10, goal // 4)
                bucket = min(goal, (value // bucket_size) * bucket_size)
                if value >= goal:
                    bucket = goal
                if bucket > stage_1_1_revenue_bucket:
                    stage_1_1_revenue_bucket = bucket
                    emit(f"Revenue {value}/{goal}.")
        elif stage == "1-1" and stripped.startswith("ORDER_RUNNER_ERROR "):
            emit("Runner error: " + stripped.removeprefix("ORDER_RUNNER_ERROR ").strip())
        elif stage == "1-1" and stripped.startswith("ORDER_HANDLING "):
            parts = dict(
                part.split("=", 1)
                for part in stripped.split()[1:]
                if "=" in part
            )
            try:
                item_id = int(parts.get("item", "0"))
            except ValueError:
                item_id = 0
            emit(f"Preparing {STAGE_1_1_ITEM_NAMES.get(item_id, f'item {item_id or "?"}')}.")
        elif stage == "1-1" and stripped.startswith("ORDER_DONE "):
            parts = dict(
                part.split("=", 1)
                for part in stripped.split()[1:]
                if "=" in part
            )
            emit(f"Order {parts.get('order', '?')} served.")
        elif stage == "1-1" and stripped.startswith("ORDER_FAILED "):
            emit("Order failed: " + stripped.removeprefix("ORDER_FAILED ").strip())
        elif stage == "1-1" and stripped.startswith("ORDER_RUNNER_TIMEOUT "):
            emit("Revenue goal was not reached before the safety timeout.")
        elif stage == "1-1" and stripped.startswith("ORDER_EXIT "):
            emit("Revenue goal confirmed, exiting the stage.")
        elif stage == "1-1" and stripped == "ORDER_CLAIMED":
            emit("Reward claimed.")
        elif stage == "1-1" and stripped.startswith("ORDER_CLAIM_FAILED "):
            emit("Claim failed: " + stripped.removeprefix("ORDER_CLAIM_FAILED ").strip())
        elif "REVENUE_VALUE=" in line:
            try:
                value = int(line.split("REVENUE_VALUE=", 1)[1].strip().split()[0])
            except ValueError:
                value = None
            if value is not None:
                for milestone in (535, 1030, 1525):
                    if value >= milestone and milestone not in revenue_milestones:
                        revenue_milestones.add(milestone)
                        emit(f"Revenue {format_amount(value)}/1,500.")
        elif "Da du dieu kien" in line and not reached_exit:
            reached_exit = True
            if "3 stars" in line:
                emit("3 stars reached, clicked Claim.")
            else:
                emit("Revenue reached 1,500, clicked Claim.")
        marker = "SPENT_AMOUNT="
        if marker in line:
            try:
                spent = int(line.split(marker, 1)[1].strip().split()[0])
            except ValueError:
                log(f"Could not parse spent marker line={line!r}")
    result = wait_for_child()
    if compact and result != 0:
        emit("Stopped.")
    return result, spent, line_number


class QueueWriter(io.TextIOBase):
    def __init__(self, output_queue: "queue.Queue[str | None]") -> None:
        self.output_queue = output_queue
        self.buffer = ""

    def write(self, text: str) -> int:
        self.buffer += text
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            self.output_queue.put(line + "\n")
        return len(text)

    def flush(self) -> None:
        if self.buffer:
            self.output_queue.put(self.buffer)
            self.buffer = ""


def start_play_cycle(
    stage: str = "1-9",
    skip_support_employee_check: bool = False,
    verify_timeout: float | None = None,
) -> tuple[Iterator[str], Callable[[], int]]:
    output_queue: "queue.Queue[str | None]" = queue.Queue()
    result_holder = {"code": 1}

    def worker() -> None:
        old_argv = sys.argv[:]
        writer = QueueWriter(output_queue)
        try:
            sys.argv = ["play.py", "--elevated-child"]
            sys.argv.extend(["--stage", stage])
            if verify_timeout is not None:
                sys.argv.extend(["--verify-timeout", str(verify_timeout)])
            if skip_support_employee_check:
                sys.argv.append("--skip-support-employee-check")
            with contextlib.redirect_stdout(writer), contextlib.redirect_stderr(writer):
                result_holder["code"] = play_main()
        except Exception as exc:
            output_queue.put(f"Packaged play cycle failed: {exc}\n")
            result_holder["code"] = 1
        finally:
            sys.argv = old_argv
            writer.flush()
            output_queue.put(None)

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    def queued_lines() -> Iterator[str]:
        while True:
            item = output_queue.get()
            if item is None:
                break
            yield item

    def wait_for_thread() -> int:
        thread.join()
        return result_holder["code"]

    return queued_lines(), wait_for_thread


def main() -> int:
    configure_console_encoding()
    parser = argparse.ArgumentParser(
        description="Run Owner's Selection stage 1-9 until the City Stamina target is reached."
    )
    parser.add_argument(
        "spend",
        nargs="?",
        type=int,
        help="City Stamina amount to spend. The tool stops after total spent reaches or exceeds this value.",
    )
    parser.add_argument("--cycles", type=int, help="Fixed cycle count for debugging.")
    parser.add_argument(
        "--spend",
        dest="spend_option",
        type=int,
        help="City Stamina amount to spend; same as the positional argument.",
    )
    parser.add_argument(
        "--min-spend-per-cycle",
        type=int,
        default=DEFAULT_MIN_SPEND_PER_CYCLE,
        help="Minimum City Stamina spent per cycle, used as a fallback.",
    )
    parser.add_argument("--between-cycles", type=float, default=3.0)
    parser.add_argument("--owner-timeout", type=float, default=20.0)
    parser.add_argument("--verify-timeout", type=float, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--stage", choices=["1-9", "1-1"], default="1-9")
    parser.add_argument("--skip-support-employee-check", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--no-admin-relaunch", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--tune-stage-1-1", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--elevated-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.tune_stage_1_1:
        return run_tune(save=True)

    spend_target = args.spend_option if args.spend_option is not None else args.spend
    if spend_target is not None and spend_target <= 0:
        print("City Stamina target must be greater than 0.")
        return 1
    if args.min_spend_per_cycle <= 0:
        print("--min-spend-per-cycle must be greater than 0.")
        return 1
    if spend_target is None:
        cycles = args.cycles if args.cycles is not None else 1

    if not is_admin():
        if args.elevated_child:
            print("Elevated child process did not receive Administrator permission.")
            log("Loop elevated child did not receive Administrator")
            return 4
        if args.no_admin_relaunch:
            print("Administrator permission is required. Please restart the app as Administrator.")
            log("Loop stopped because Administrator permission is required")
            return 4
        print("Requesting Administrator permission...")
        log("Loop requesting Administrator")
        if relaunch_as_admin():
            print("Opened an elevated helper. The current process will stop.")
            return 7
        return 4

    if spend_target is not None:
        log(
            "Loop spend target "
            f"target={spend_target} min_per_cycle={args.min_spend_per_cycle} "
        )

    spent_total = 0
    cycle = 0
    stopped_by_energy = False
    stopped_by_zero_spent = False
    compact_output = spend_target is not None
    support_employee_checked = args.skip_support_employee_check
    while True:
        if spend_target is not None and spent_total >= spend_target:
            break
        if spend_target is None and cycle >= cycles:
            break

        cycle += 1
        if spend_target is not None:
            print(
                f"Run {cycle}: "
                f"{format_amount(spent_total)}/{format_amount(spend_target)} City Stamina"
            )
            log(
                f"Loop cycle {cycle} started elevated=True "
                f"spent_total={spent_total} target={spend_target}"
            )
        else:
            print(f"Starting cycle {cycle}/{cycles}.")
            log(f"Loop cycle {cycle}/{cycles} started elevated=True")
        next_line = 1
        if compact_output:
            print(f"  Line 1: Looking for stage {args.stage}.")
            next_line = 2
        if not wait_for_owner_selection(args.owner_timeout):
            print(f"  Line {next_line}: Owner's Selection was not found, stopping.")
            log("Loop stopped because Owner's Selection was not found")
            return 6
        # Temporarily disabled for Stage 1-1/low-stamina testing. Keep
        # energy_is_empty() intact so this guard can be restored quickly.
        # if energy_is_empty():
        #     print(f"  Line {next_line}: City Stamina is 0/700, stopping.")
        #     log("Loop stopped because energy is 0/700")
        #     stopped_by_energy = True
        #     break
        if compact_output:
            log("Owner's Selection ready and energy is available")
        result, spent, next_line = run_cycle(
            compact_output,
            next_line,
            args.stage,
            support_employee_checked,
            args.verify_timeout,
        )
        if result != 0:
            print(f"  Line {next_line}: Stopped.")
            log(f"Loop cycle {cycle} stopped with return code {result}")
            return result
        support_employee_checked = True
        if spend_target is not None:
            if spent is None:
                spent = args.min_spend_per_cycle
                print(f"  Line {next_line}: Could not read City Stamina spent, using fallback {spent}.")
                next_line += 1
                log(f"Loop cycle {cycle} missing spent marker; fallback spent={spent}")
            if spent <= 0:
                # Temporarily allow 0-cost claims while testing Stage 1-1 with
                # empty City Stamina. Count the fallback so the test loop can
                # finish instead of getting stuck forever at 0/target.
                spent = args.min_spend_per_cycle
                print(f"  Line {next_line}: Claim cost was 0, using test fallback {spent}.")
                next_line += 1
                log(f"Loop test fallback because spent marker was 0; fallback spent={spent}")
            spent_total += spent
            print(
                f"  Line {next_line}: Spent {spent} City Stamina. "
                f"Total {format_amount(spent_total)}/{format_amount(spend_target)} City Stamina."
            )
            next_line += 1
            log(f"Loop cycle {cycle} spent={spent} spent_total={spent_total}")
        if spend_target is None and cycle < cycles:
            print(f"Cycle {cycle} completed. Waiting for the UI to settle...")
            human_sleep(args.between_cycles, 0.3)
        elif spend_target is not None and spent_total < spend_target:
            log("Loop waiting between spend cycles")
            human_sleep(args.between_cycles, 0.3)

    if stopped_by_energy:
        target_text = format_amount(spend_target or 0)
        print(
            f"Stopped because City Stamina is 0/700. "
            f"Spent {format_amount(spent_total)}/{target_text} City Stamina."
        )
        log(f"Loop stopped by energy spent_total={spent_total} target={spend_target}")
    elif stopped_by_zero_spent:
        target_text = format_amount(spend_target or 0)
        print(
            f"Stopped because the claim cost could not be confirmed. "
            f"Spent {format_amount(spent_total)}/{target_text} City Stamina."
        )
        log(f"Loop stopped by zero spent marker spent_total={spent_total} target={spend_target}")
    elif spend_target is not None:
        print(
            f"Target reached: "
            f"spent {format_amount(spent_total)} >= {format_amount(spend_target)} City Stamina."
        )
        log(f"Loop completed spend target spent_total={spent_total} target={spend_target}")
    else:
        print("All cycles completed.")
        log("Loop completed all cycles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
