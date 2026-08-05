from __future__ import annotations

import json
import time
from pathlib import Path

import cv2

from monitor import EXIT_POINT, wait_for_challenge_and_claim
from play import capture_client_band_color, capture_region, click, find_nte_window, focus_window, scale_point
from stage_1_1_orders import (
    DEBUG_DIR,
    DEFAULT_ORDER_THRESHOLD,
    ORDER_SCAN_RATIOS,
    ORDER_TEMPLATES,
    detect_order_circles,
    save_debug,
    tuned_order_region,
    tuned_order_threshold,
)


TUNING_PATH = DEBUG_DIR.parent / "stage_1_1_tuning.json"
CALIBRATION_REGION = {
    "left": ORDER_SCAN_RATIOS["left"],
    "top": ORDER_SCAN_RATIOS["top"],
    "right": ORDER_SCAN_RATIOS["right"],
    "bottom": ORDER_SCAN_RATIOS["bottom"],
}


def summarize_matches(matches) -> str:
    if not matches:
        return "No order detected"
    counts: dict[str, int] = {}
    for match in matches:
        counts[match.item.label] = counts.get(match.item.label, 0) + 1
    summary = ", ".join(
        f"{label} x{count}" if count > 1 else label
        for label, count in sorted(counts.items())
    )
    return f"{len(matches)} orders: {summary}"


def run_tune(save: bool = True) -> int:
    target = find_nte_window()
    if not target:
        print("TUNE_ERROR=NTE window was not found.")
        return 2

    focus_window(target["hwnd"], 0.08)
    target = find_nte_window() or target

    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    raw_path = DEBUG_DIR / f"tune_order_scan_{timestamp}.png"
    marked_path = DEBUG_DIR / f"tune_order_scan_{timestamp}_marked.png"
    latest_raw_path = DEBUG_DIR / "latest_tune_order_scan.png"
    latest_marked_path = DEBUG_DIR / "latest_tune_order_scan_marked.png"

    region = tuned_order_region()
    threshold = tuned_order_threshold(DEFAULT_ORDER_THRESHOLD)
    raw_image = capture_region(target["client"], region, "left")
    image, matches = detect_order_bubbles(
        target["client"],
        region=region,
        threshold=threshold,
        templates=ORDER_TEMPLATES,
        multi=True,
    )
    cv2.imwrite(str(raw_path), raw_image)
    cv2.imwrite(str(latest_raw_path), raw_image)
    save_debug(image, matches, marked_path)
    save_debug(image, matches, latest_marked_path)

    if save:
        config = {
            "resolution": {
                "width": target["client"]["width"],
                "height": target["client"]["height"],
            },
            "order_scan_region": region,
            "order_threshold": threshold,
            "updated_at": timestamp,
        }
        TUNING_PATH.write_text(json.dumps(config, indent=2), encoding="utf-8")

    summary = summarize_matches(matches)
    print(f"TUNE_IMAGE={marked_path.resolve()}")
    print(f"TUNE_RAW_IMAGE={raw_path.resolve()}")
    print(f"TUNE_MATCHES={len(matches)}")
    print(f"TUNE_SUMMARY={summary}")
    print(f"TUNE_CONFIG={TUNING_PATH.resolve()}")
    return 0


def run_open_shop_calibration(exit_after: bool = True) -> int:
    target = find_nte_window()
    if not target:
        print("CALIBRATION_ERROR=NTE window was not found.")
        return 2

    focus_window(target["hwnd"], 0.08)
    target = find_nte_window() or target
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")

    # Wait for the opening READY overlay to clear, then capture the gameplay
    # layout in the exact client size reported on this machine.
    time.sleep(5.6)
    target = find_nte_window() or target
    full_color, _ = capture_client_band_color(target["client"], 0.0, 0.0, 1.0, 1.0)
    order_color, actual_region = capture_client_band_color(
        target["client"],
        CALIBRATION_REGION["left"],
        CALIBRATION_REGION["top"],
        CALIBRATION_REGION["right"],
        CALIBRATION_REGION["bottom"],
    )
    order_gray = cv2.cvtColor(order_color, cv2.COLOR_BGR2GRAY)

    full_path = DEBUG_DIR / f"calibration_full_{timestamp}.png"
    crop_path = DEBUG_DIR / f"calibration_order_crop_{timestamp}.png"
    marked_path = DEBUG_DIR / f"calibration_order_marked_{timestamp}.png"
    latest_full_path = DEBUG_DIR / "latest_calibration_full.png"
    latest_crop_path = DEBUG_DIR / "latest_calibration_order_crop.png"
    latest_marked_path = DEBUG_DIR / "latest_calibration_marked.png"

    threshold = tuned_order_threshold(DEFAULT_ORDER_THRESHOLD)
    matches = detect_order_circles(order_gray, target["client"], ORDER_TEMPLATES, threshold)

    cv2.imwrite(str(full_path), full_color)
    cv2.imwrite(str(latest_full_path), full_color)
    cv2.imwrite(str(crop_path), order_color)
    cv2.imwrite(str(latest_crop_path), order_color)
    save_debug(order_gray, matches, marked_path)
    save_debug(order_gray, matches, latest_marked_path)

    config = {
        "resolution": {
            "width": target["client"]["width"],
            "height": target["client"]["height"],
        },
        "order_scan_ratios": CALIBRATION_REGION,
        "order_threshold": threshold,
        "calibration": {
            "full_image": str(full_path.resolve()),
            "order_crop": str(crop_path.resolve()),
            "marked_crop": str(marked_path.resolve()),
            "actual_screen_region": actual_region,
        },
        "updated_at": timestamp,
    }
    TUNING_PATH.write_text(json.dumps(config, indent=2), encoding="utf-8")

    print(f"CALIBRATION_FULL_IMAGE={full_path.resolve()}")
    print(f"CALIBRATION_ORDER_CROP={crop_path.resolve()}")
    print(f"CALIBRATION_MARKED_IMAGE={marked_path.resolve()}")
    print(f"CALIBRATION_MATCHES={len(matches)}")
    print(f"CALIBRATION_CONFIG={TUNING_PATH.resolve()}")

    if exit_after:
        exit_rel_x, exit_rel_y = scale_point(target["client"], EXIT_POINT)
        click(
            target["hwnd"],
            target["client"]["left"] + exit_rel_x,
            target["client"]["top"] + exit_rel_y,
        )
        print("CALIBRATION_EXIT_CLICKED")
        wait_for_challenge_and_claim(12.0)

    return 0


def main() -> int:
    return run_tune(save=True)


if __name__ == "__main__":
    raise SystemExit(main())
