from __future__ import annotations

import json
import time
from pathlib import Path

import cv2

from play import capture_region, find_nte_window, focus_window
from stage_1_1_orders import (
    DEBUG_DIR,
    DEFAULT_ORDER_THRESHOLD,
    ORDER_TEMPLATES,
    detect_order_bubbles,
    save_debug,
    tuned_order_region,
    tuned_order_threshold,
)


TUNING_PATH = DEBUG_DIR.parent / "stage_1_1_tuning.json"


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


def main() -> int:
    return run_tune(save=True)


if __name__ == "__main__":
    raise SystemExit(main())
