from __future__ import annotations

import argparse
import time

from stage_1_1_orders import ORDER_TEMPLATES, detect_order_bubbles
from stage_1_1_recipe_player import play_recipe
from play import find_nte_window


ITEM_RECIPES = {
    1: "black_coffee",
    2: "white_coffee",
}


def run_item(item_id: int, watch: float, interval: float, threshold: float, cooldown: float) -> int:
    if item_id not in ITEM_RECIPES:
        print(f"Item {item_id} is not wired yet.")
        return 3

    templates = [item for item in ORDER_TEMPLATES if item.item_id == item_id]
    if not templates:
        print(f"Item {item_id} template was not found.")
        return 3

    recipe = ITEM_RECIPES[item_id]
    deadline = time.monotonic() + max(1.0, watch)
    handled = 0
    last_action_at = 0.0
    last_report = ""

    print(f"Watching item {item_id}...")
    while time.monotonic() < deadline:
        target = find_nte_window()
        if not target:
            print("NTE window was not found.")
            return 2

        _, matches = detect_order_bubbles(
            target["client"],
            threshold=threshold,
            templates=templates,
            multi=True,
        )
        report = "|".join(f"{match.x}:{match.y}:{match.score:.3f}" for match in matches)
        if matches and report != last_report:
            print(f"Item {item_id} detected: {len(matches)} order(s).")
            last_report = report

        now = time.monotonic()
        if matches and now - last_action_at >= cooldown:
            handled += 1
            best = max(matches, key=lambda match: match.score)
            print(f"Handling item {item_id}: order {handled}, score={best.score:.3f}.")
            result = play_recipe(recipe, None, skip_open_shop=True)
            if result != 0:
                print(f"Item {item_id} recipe failed.")
                return result
            last_action_at = time.monotonic()
            time.sleep(max(0.2, cooldown))
            continue

        time.sleep(max(0.1, interval))

    if handled:
        print(f"Handled item {item_id}: {handled} order(s).")
        return 0

    print(f"Item {item_id} was not seen.")
    return 4


def main() -> int:
    parser = argparse.ArgumentParser(description="Watch Stage 1-1 orders and handle one wired item.")
    parser.add_argument("item_id", type=int, choices=range(1, 7))
    parser.add_argument("--watch", type=float, default=60.0)
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--threshold", type=float, default=0.82)
    parser.add_argument("--cooldown", type=float, default=2.2)
    args = parser.parse_args()
    return run_item(args.item_id, args.watch, args.interval, args.threshold, args.cooldown)


if __name__ == "__main__":
    raise SystemExit(main())
