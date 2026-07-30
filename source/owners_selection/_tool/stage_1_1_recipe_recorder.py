from __future__ import annotations

import argparse
import ctypes
import json
import time
from ctypes import wintypes
from pathlib import Path

import mss
from PIL import Image

from play import BASE_HEIGHT, BASE_WIDTH, find_nte_window, focus_window


WORKSPACE = Path(__file__).resolve().parent
RECIPE_DIR = WORKSPACE / "stage_1_1_assets" / "recipes"

VK_LBUTTON = 0x01
VK_ESCAPE = 0x1B

user32 = ctypes.windll.user32


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


ITEMS = {
    "1": "black_coffee",
    "black": "black_coffee",
    "black_coffee": "black_coffee",
    "2": "white_coffee",
    "white": "white_coffee",
    "white_coffee": "white_coffee",
    "3": "sandwich",
    "sandwich": "sandwich",
    "4": "croissant",
    "croissant": "croissant",
    "5": "cupcake",
    "cupcake": "cupcake",
    "6": "tomato_juice",
    "tomato": "tomato_juice",
    "tomato_juice": "tomato_juice",
}


def normalize_item(value: str) -> str:
    key = value.strip().casefold().replace("-", "_").replace(" ", "_")
    if key not in ITEMS:
        valid = ", ".join(sorted(set(ITEMS.values())))
        raise argparse.ArgumentTypeError(f"unknown item '{value}'. Valid items: {valid}")
    return ITEMS[key]


def cursor_position() -> tuple[int, int]:
    point = POINT()
    user32.GetCursorPos(ctypes.byref(point))
    return point.x, point.y


def key_down(vk: int) -> bool:
    return bool(user32.GetAsyncKeyState(vk) & 0x8000)


def inside_client(client: dict[str, int], x: int, y: int) -> bool:
    return (
        client["left"] <= x < client["right"]
        and client["top"] <= y < client["bottom"]
    )


def capture_client(client: dict[str, int]) -> Image.Image:
    region = {
        "left": client["left"],
        "top": client["top"],
        "width": client["width"],
        "height": client["height"],
    }
    with mss.MSS() as sct:
        shot = sct.grab(region)
    return Image.frombytes("RGB", shot.size, shot.rgb)


def step_payload(
    index: int,
    client: dict[str, int],
    screen_x: int,
    screen_y: int,
    elapsed: float,
) -> dict:
    local_x = screen_x - client["left"]
    local_y = screen_y - client["top"]
    return {
        "index": index,
        "elapsed_sec": round(elapsed, 3),
        "screen": {"x": screen_x, "y": screen_y},
        "local": {"x": local_x, "y": local_y},
        "base_1280x720": {
            "x": round(local_x * BASE_WIDTH / client["width"]),
            "y": round(local_y * BASE_HEIGHT / client["height"]),
        },
        "ratio": {
            "x": round(local_x / client["width"], 6),
            "y": round(local_y / client["height"], 6),
        },
        "before_image": f"step_{index:02d}_before.png",
        "after_image": f"step_{index:02d}_after.png",
    }


def record_recipe(item: str, duration: float, start_delay: float, overwrite: bool) -> int:
    target = find_nte_window()
    if not target:
        print("NTE window was not found.")
        return 2

    hwnd = target["hwnd"]
    focus_window(hwnd, 0.4)
    target = find_nte_window() or target
    client = target["client"]

    output_dir = RECIPE_DIR / item / time.strftime("%Y%m%d_%H%M%S")
    if output_dir.exists() and not overwrite:
        print(f"Recipe folder already exists: {output_dir}")
        return 3
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Recording item: {item}")
    print(f"NTE client: {client['width']}x{client['height']}")
    print(f"Output: {output_dir}")
    print("Move to the game and prepare the item normally.")
    print("Recording starts after the countdown. Press ESC to stop early.")
    for remaining in range(max(0, int(start_delay)), 0, -1):
        print(f"Start in {remaining}...")
        time.sleep(1)

    start = time.monotonic()
    deadline = start + max(1.0, duration)
    was_down = key_down(VK_LBUTTON)
    steps: list[dict] = []
    index = 1

    while time.monotonic() < deadline:
        if key_down(VK_ESCAPE):
            break

        is_down = key_down(VK_LBUTTON)
        if is_down and not was_down:
            screen_x, screen_y = cursor_position()
            if inside_client(client, screen_x, screen_y):
                before = capture_client(client)
                elapsed = time.monotonic() - start
                step = step_payload(index, client, screen_x, screen_y, elapsed)
                before.save(output_dir / step["before_image"])

                while key_down(VK_LBUTTON):
                    time.sleep(0.01)
                time.sleep(0.18)

                after = capture_client(client)
                after.save(output_dir / step["after_image"])
                steps.append(step)
                print(
                    f"Step {index}: local=({step['local']['x']},{step['local']['y']}) "
                    f"base=({step['base_1280x720']['x']},{step['base_1280x720']['y']})"
                )
                index += 1
            else:
                while key_down(VK_LBUTTON):
                    time.sleep(0.01)

        was_down = is_down
        time.sleep(0.015)

    payload = {
        "version": 1,
        "stage": "1-1",
        "item": item,
        "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "client": {
            "width": client["width"],
            "height": client["height"],
        },
        "steps": steps,
    }
    (output_dir / "recipe.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"Recorded {len(steps)} step(s).")
    print(f"Saved recipe: {output_dir / 'recipe.json'}")
    return 0 if steps else 4


def main() -> int:
    parser = argparse.ArgumentParser(description="Record a Stage 1-1 item preparation recipe.")
    parser.add_argument("item", type=normalize_item, help="Item id/name, e.g. 1, 2, black_coffee, white_coffee.")
    parser.add_argument("--duration", type=float, default=25.0, help="Recording seconds.")
    parser.add_argument("--start-delay", type=float, default=4.0, help="Countdown before recording starts.")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    return record_recipe(args.item, args.duration, args.start_delay, args.overwrite)


if __name__ == "__main__":
    raise SystemExit(main())
