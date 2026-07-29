from __future__ import annotations

import argparse
import ctypes
import json
from ctypes import wintypes
from pathlib import Path

import mss
from PIL import Image, ImageDraw


user32 = ctypes.windll.user32
dwmapi = ctypes.windll.dwmapi

try:
    user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
except Exception:
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        user32.SetProcessDPIAware()


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", ctypes.c_long),
        ("top", ctypes.c_long),
        ("right", ctypes.c_long),
        ("bottom", ctypes.c_long),
    ]


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


class MONITORINFO(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("rcMonitor", RECT),
        ("rcWork", RECT),
        ("dwFlags", wintypes.DWORD),
    ]


def rect_dict(rect: RECT) -> dict[str, int]:
    return {
        "left": rect.left,
        "top": rect.top,
        "right": rect.right,
        "bottom": rect.bottom,
        "width": rect.right - rect.left,
        "height": rect.bottom - rect.top,
    }


def get_monitors() -> list[dict[str, int]]:
    monitors: list[dict[str, int]] = []
    callback_type = ctypes.WINFUNCTYPE(
        ctypes.c_int, wintypes.HMONITOR, wintypes.HDC, ctypes.POINTER(RECT), wintypes.LPARAM
    )

    def callback(handle, _hdc, _rect, _data):
        info = MONITORINFO()
        info.cbSize = ctypes.sizeof(info)
        user32.GetMonitorInfoW(handle, ctypes.byref(info))
        monitor = rect_dict(info.rcMonitor)
        monitor["primary"] = bool(info.dwFlags & 1)
        monitors.append(monitor)
        return 1

    user32.EnumDisplayMonitors(None, None, callback_type(callback), 0)
    return sorted(monitors, key=lambda item: item["left"])


def get_title(hwnd: int) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buffer, length + 1)
    return buffer.value


def get_class_name(hwnd: int) -> str:
    buffer = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buffer, len(buffer))
    return buffer.value


def is_cloaked(hwnd: int) -> bool:
    cloaked = wintypes.DWORD()
    result = dwmapi.DwmGetWindowAttribute(
        hwnd, 14, ctypes.byref(cloaked), ctypes.sizeof(cloaked)
    )
    return result == 0 and bool(cloaked.value)


def get_client_bounds(hwnd: int) -> dict[str, int] | None:
    client = RECT()
    origin = POINT(0, 0)
    if not user32.GetClientRect(hwnd, ctypes.byref(client)):
        return None
    if not user32.ClientToScreen(hwnd, ctypes.byref(origin)):
        return None
    return {
        "left": origin.x,
        "top": origin.y,
        "right": origin.x + client.right,
        "bottom": origin.y + client.bottom,
        "width": client.right,
        "height": client.bottom,
    }


def get_windows() -> list[dict]:
    windows: list[dict] = []
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_int, wintypes.HWND, wintypes.LPARAM)

    def callback(hwnd, _data):
        if not user32.IsWindowVisible(hwnd) or user32.IsIconic(hwnd) or is_cloaked(hwnd):
            return 1
        title = get_title(hwnd).strip()
        class_name = get_class_name(hwnd)
        bounds = get_client_bounds(hwnd)
        has_identity = bool(title) or class_name == "UnrealWindow"
        if has_identity and bounds and bounds["width"] > 0 and bounds["height"] > 0:
            windows.append(
                {
                    "hwnd": int(hwnd),
                    "title": title,
                    "class_name": class_name,
                    "client": bounds,
                }
            )
        return 1

    user32.EnumWindows(callback_type(callback), 0)
    return windows


def overlap_area(a: dict[str, int], b: dict[str, int]) -> int:
    width = max(0, min(a["right"], b["right"]) - max(a["left"], b["left"]))
    height = max(0, min(a["bottom"], b["bottom"]) - max(a["top"], b["top"]))
    return width * height


def choose_window(
    windows: list[dict],
    left_monitor: dict[str, int],
    width: int,
    height: int,
    tolerance: int,
    title_text: str,
) -> tuple[dict | None, list[dict]]:
    candidates = []
    monitor_center = (
        (left_monitor["left"] + left_monitor["right"]) / 2,
        (left_monitor["top"] + left_monitor["bottom"]) / 2,
    )
    for window in windows:
        client = window["client"]
        if title_text and title_text.casefold() not in window["title"].casefold():
            continue
        if overlap_area(client, left_monitor) == 0:
            continue
        size_error = abs(client["width"] - width) + abs(client["height"] - height)
        if size_error > tolerance * 2:
            continue
        center = (
            (client["left"] + client["right"]) / 2,
            (client["top"] + client["bottom"]) / 2,
        )
        center_error = abs(center[0] - monitor_center[0]) + abs(center[1] - monitor_center[1])
        window = {**window, "size_error": size_error, "center_error": round(center_error)}
        candidates.append(window)
    candidates.sort(key=lambda item: (item["size_error"], item["center_error"]))
    return (candidates[0] if candidates else None), candidates


def choose_window_any_monitor(
    windows: list[dict],
    width: int,
    height: int,
    tolerance: int,
    title_text: str,
) -> tuple[dict | None, list[dict]]:
    candidates = []
    for window in windows:
        client = window["client"]
        if title_text and title_text.casefold() not in window["title"].casefold():
            continue
        size_error = abs(client["width"] - width) + abs(client["height"] - height)
        aspect = client["width"] / max(1, client["height"])
        is_named_target = (
            "nte" in window["title"].casefold()
            or window.get("class_name") == "UnrealWindow"
        )
        if size_error <= tolerance * 2 or (is_named_target and 1.65 <= aspect <= 1.85):
            candidates.append({**window, "size_error": size_error})
    candidates.sort(key=lambda item: item["size_error"])
    return (candidates[0] if candidates else None), candidates


def grab_region(sct: mss.MSS, bounds: dict[str, int]) -> Image.Image:
    shot = sct.grab(
        {
            "left": bounds["left"],
            "top": bounds["top"],
            "width": bounds["width"],
            "height": bounds["height"],
        }
    )
    return Image.frombytes("RGB", shot.size, shot.rgb)


def save_screenshots(target: dict, monitor: dict[str, int], output_dir: Path) -> list[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    target_path = output_dir / "detected_app.png"
    overview_path = output_dir / "left_monitor_detected.png"
    with mss.MSS() as sct:
        grab_region(sct, target["client"]).save(target_path)
        overview = grab_region(sct, monitor)
    draw = ImageDraw.Draw(overview)
    client = target["client"]
    box = (
        client["left"] - monitor["left"],
        client["top"] - monitor["top"],
        client["right"] - monitor["left"] - 1,
        client["bottom"] - monitor["top"] - 1,
    )
    draw.rectangle(box, outline="red", width=5)
    draw.rectangle((box[0], max(0, box[1] - 28), box[0] + 360, box[1]), fill="red")
    draw.text((box[0] + 6, max(2, box[1] - 23)), target["title"][:48], fill="white")
    overview.save(overview_path)
    return [target_path, overview_path]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Find a centered app window on the leftmost monitor and screenshot it."
    )
    parser.add_argument("--width", type=int, default=1280, help="Expected client width")
    parser.add_argument("--height", type=int, default=720, help="Expected client height")
    parser.add_argument("--tolerance", type=int, default=40, help="Allowed pixel difference")
    parser.add_argument("--title", default="", help="Optional text contained in the window title")
    parser.add_argument("--output-dir", default="screenshots", help="Screenshot folder")
    args = parser.parse_args()

    monitors = get_monitors()
    if not monitors:
        print("Khong tim thay man hinh nao.")
        return 1
    target, candidates = choose_window_any_monitor(
        get_windows(), args.width, args.height, args.tolerance, args.title
    )

    print("Monitors:")
    print(json.dumps(monitors, ensure_ascii=False, indent=2))
    print("\nMatching windows:")
    print(json.dumps(candidates, ensure_ascii=False, indent=2))
    if not target:
        print("\nKhong tim thay cua so phu hop tren desktop ao.")
        print("Thu tang --tolerance hoac them --title \"mot phan ten app\".")
        return 2

    target_monitor = max(monitors, key=lambda monitor: overlap_area(target["client"], monitor))
    paths = save_screenshots(target, target_monitor, Path(args.output_dir))
    print("\nSelected window:")
    print(json.dumps(target, ensure_ascii=False, indent=2))
    print("\nScreenshots:")
    for path in paths:
        print(path.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
