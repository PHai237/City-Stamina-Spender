from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from play import click, find_nte_window, focus_window


WORKSPACE = Path(__file__).resolve().parent
RECIPE_DIR = WORKSPACE / "stage_1_1_assets" / "recipes"
OPEN_SHOP_BASE_POINT = (1138, 665)


def latest_recipe(item: str) -> Path | None:
    item_dir = RECIPE_DIR / item
    if not item_dir.exists():
        return None
    folders = [path for path in item_dir.iterdir() if path.is_dir()]
    if not folders:
        return None
    return max(folders, key=lambda path: path.stat().st_mtime) / "recipe.json"


def load_recipe(item: str, recipe_path: str | None) -> dict:
    path = Path(recipe_path) if recipe_path else latest_recipe(item)
    if path is None or not path.exists():
        raise FileNotFoundError(f"No recipe found for {item}.")
    return json.loads(path.read_text(encoding="utf-8"))


def step_screen_point(client: dict[str, int], step: dict) -> tuple[int, int]:
    ratio = step.get("ratio")
    if ratio:
        local_x = round(float(ratio["x"]) * client["width"])
        local_y = round(float(ratio["y"]) * client["height"])
    else:
        base = step["base_1280x720"]
        local_x = round(base["x"] * client["width"] / 1280)
        local_y = round(base["y"] * client["height"] / 720)
    return client["left"] + local_x, client["top"] + local_y


def looks_like_open_shop_step(step: dict) -> bool:
    base = step.get("base_1280x720")
    if not base:
        return False
    return (
        abs(int(base["x"]) - OPEN_SHOP_BASE_POINT[0]) <= 45
        and abs(int(base["y"]) - OPEN_SHOP_BASE_POINT[1]) <= 35
    )


def play_recipe(
    item: str,
    recipe_path: str | None,
    skip_open_shop: bool,
    start_step_index: int = 0,
    delay: float = 0.22,
) -> int:
    recipe = load_recipe(item, recipe_path)
    target = find_nte_window()
    if not target:
        print("NTE window was not found.")
        return 2

    hwnd = target["hwnd"]
    focus_window(hwnd, 0.4)
    target = find_nte_window() or target
    client = target["client"]

    steps = recipe.get("steps", [])
    if skip_open_shop and steps and looks_like_open_shop_step(steps[0]):
        # Recipes recorded from the stage screen usually include Open Shop first.
        steps = steps[1:]
    if start_step_index > 0:
        steps = steps[start_step_index:]
    if not steps:
        print("Recipe has no playable steps.")
        return 3

    print(f"Playing {recipe.get('item', item)} recipe: {len(steps)} step(s).")
    for step in steps:
        x, y = step_screen_point(client, step)
        print(f"Step {step.get('index')}: click {x},{y}")
        click(hwnd, x, y)
        time.sleep(max(0.05, delay))
    print("Recipe playback finished.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Replay a Stage 1-1 item recipe.")
    parser.add_argument("item", help="Recipe item name, e.g. black_coffee.")
    parser.add_argument("--recipe")
    parser.add_argument("--include-open-shop", action="store_true")
    parser.add_argument("--start-step-index", type=int, default=0)
    parser.add_argument("--delay", type=float, default=0.22)
    args = parser.parse_args()
    return play_recipe(args.item, args.recipe, not args.include_open_shop, args.start_step_index, args.delay)


if __name__ == "__main__":
    raise SystemExit(main())
