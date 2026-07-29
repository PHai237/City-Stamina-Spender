from __future__ import annotations

import argparse
import ctypes
import random
import subprocess
import sys
import time
from ctypes import wintypes
from pathlib import Path

import cv2
import mss
import numpy as np

from locate_app_window import get_client_bounds, get_title, get_windows


user32 = ctypes.windll.user32
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_ABSOLUTE = 0x8000
MOUSEEVENTF_VIRTUALDESK = 0x4000
INPUT_MOUSE = 0
SW_RESTORE = 9

# Coordinates relative to the base 1280x720 NTE client area.
BASE_WIDTH = 1280
BASE_HEIGHT = 720
LIST_REGION = {"left": 8, "top": 82, "width": 214, "height": 606}
LIST_MOUSE_POINT = (110, 360)
TITLE_REGION = {"left": 245, "top": 80, "width": 760, "height": 80}
OWNER_REGION = {"left": 10, "top": 5, "width": 280, "height": 65}
OWNER_THRESHOLD = 0.60
OPEN_SHOP_POINT = (1145, 670)
SWAP_EMPLOYEE_POINT = (777, 670)
SUPPORT_CONFIRM_POINT = (640, 564)
SUPPORT_TOP_SLOT_POINTS = {
    "slot_1": (514, 221),
    "slot_2": (643, 221),
    "slot_3": (774, 221),
}
SUPPORT_LIST_POINTS = {
    "Sakiri": (380, 440),
    "Mint": (380, 337),
}
SUPPORT_EMPLOYEE_REGION = {"left": 676, "top": 408, "width": 432, "height": 236}
SUPPORT_EMPLOYEE_THRESHOLD = 0.68
SUPPORT_PAGE_REGION = {"left": 238, "top": 106, "width": 804, "height": 510}
SUPPORT_PAGE_TITLE_REGION = {"left": 450, "top": 108, "width": 310, "height": 52}
SUPPORT_TOP_SLOT_REGIONS = {
    "Sakiri": {"left": 460, "top": 166, "width": 115, "height": 112},
    "Mint": {"left": 590, "top": 166, "width": 115, "height": 112},
    "Adler": {"left": 720, "top": 166, "width": 115, "height": 112},
}
SUPPORT_PAGE_THRESHOLD = 0.58
SUPPORT_TOP_SLOT_THRESHOLD = 0.60
WORKSPACE = (
    Path(sys.executable).resolve().parent
    if getattr(sys, "frozen", False)
    else Path(__file__).resolve().parent
)
LOG_PATH = WORKSPACE / "stage_1_9_debug/run.log"
SUPPORT_EMPLOYEE_ASSET_DIR = WORKSPACE / "stage_1_9_assets" / "support_employee"
SUPPORT_EMPLOYEE_PAGE_ASSET_DIR = WORKSPACE / "stage_1_9_assets" / "support_employee_page"


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.c_long),
        ("dy", ctypes.c_long),
        ("mouseData", ctypes.c_ulong),
        ("dwFlags", ctypes.c_ulong),
        ("time", ctypes.c_ulong),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]


class INPUT_UNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", ctypes.c_ulong), ("union", INPUT_UNION)]


def log(message: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as file:
        file.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n")


def human_sleep(seconds: float, jitter: float = 0.25, minimum: float = 0.03) -> None:
    low = max(minimum, seconds * (1 - jitter))
    high = max(low, seconds * (1 + jitter))
    time.sleep(random.uniform(low, high))


def is_elevated() -> bool:
    return bool(ctypes.windll.shell32.IsUserAnAdmin())


def relaunch_as_admin() -> bool:
    script = str(Path(__file__).resolve())
    parameters = subprocess.list2cmdline([script, *sys.argv[1:], "--elevated-child"])
    result = ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, parameters, str(Path.cwd()), 1
    )
    return result > 32


def find_nte_window() -> dict | None:
    # Find visible NTE/Unreal windows only. FindWindowW can return hidden launcher
    # windows that share the "NTE" title, which breaks screenshot matching.
    # Some DPI/scaling setups expose
    # a 1280x720 window as roughly 1020x567 through Win32 APIs.
    candidates = []
    for window in get_windows():
        client = window["client"]
        is_nte_title = "nte" in window["title"].casefold()
        is_unreal_window = window.get("class_name") == "UnrealWindow"
        if not (is_nte_title or is_unreal_window):
            continue
        if is_usable_nte_size(client):
            expected_height = client["width"] * BASE_HEIGHT / BASE_WIDTH
            size_error = abs(client["height"] - expected_height)
            class_priority = 0 if is_unreal_window else 1
            title_priority = 0 if window["title"].strip().casefold() == "nte" else 1
            candidates.append({**window, "size_error": size_error})
            candidates[-1]["class_priority"] = class_priority
            candidates[-1]["title_priority"] = title_priority
    candidates.sort(
        key=lambda window: (
            window["class_priority"],
            window["title_priority"],
            window["size_error"],
        )
    )
    return candidates[0] if candidates else None


def is_usable_nte_size(client: dict[str, int]) -> bool:
    if client["width"] < 900 or client["height"] < 500:
        return False
    aspect = client["width"] / max(1, client["height"])
    return 1.6 <= aspect <= 2.45


def ui_scale(client: dict[str, int]) -> float:
    return min(client["width"] / BASE_WIDTH, client["height"] / BASE_HEIGHT)


def anchor_left(client: dict[str, int], base_left: int, width: int, anchor: str) -> int:
    if anchor == "right":
        return client["width"] - round((BASE_WIDTH - base_left) * ui_scale(client))
    if anchor == "center":
        viewport_width = BASE_WIDTH * ui_scale(client)
        return round((client["width"] - viewport_width) / 2 + base_left * ui_scale(client))
    return round(base_left * ui_scale(client))


def scale_point(
    client: dict[str, int],
    point: tuple[int, int],
    anchor: str = "left",
) -> tuple[int, int]:
    scale = ui_scale(client)
    return anchor_left(client, point[0], 0, anchor), round(point[1] * scale)


def scale_local_point(client: dict[str, int], point: tuple[int, int]) -> tuple[int, int]:
    scale = ui_scale(client)
    return round(point[0] * scale), round(point[1] * scale)


def scale_region(
    client: dict[str, int],
    relative_region: dict[str, int],
    anchor: str = "left",
) -> dict[str, int]:
    scale = ui_scale(client)
    width = max(1, round(relative_region["width"] * scale))
    return {
        "left": anchor_left(client, relative_region["left"], width, anchor),
        "top": round(relative_region["top"] * scale),
        "width": width,
        "height": max(1, round(relative_region["height"] * scale)),
    }


def scale_template(template: np.ndarray, client: dict[str, int]) -> np.ndarray:
    scale = ui_scale(client)
    if abs(scale - 1.0) < 0.02:
        return template
    height, width = template.shape[:2]
    scaled_width = max(1, round(width * scale))
    scaled_height = max(1, round(height * scale))
    return cv2.resize(template, (scaled_width, scaled_height), interpolation=cv2.INTER_AREA)


def capture_region(
    client: dict[str, int],
    relative_region: dict[str, int],
    anchor: str = "left",
) -> np.ndarray:
    scaled = scale_region(client, relative_region, anchor)
    region = {
        "left": client["left"] + scaled["left"],
        "top": client["top"] + scaled["top"],
        "width": scaled["width"],
        "height": scaled["height"],
    }
    with mss.MSS() as sct:
        image = np.asarray(sct.grab(region))
    return cv2.cvtColor(image, cv2.COLOR_BGRA2GRAY)


def capture_list(client: dict[str, int]) -> np.ndarray:
    return capture_region(client, LIST_REGION)


def find_template(image: np.ndarray, template: np.ndarray, threshold: float) -> tuple | None:
    if template.shape[0] > image.shape[0] or template.shape[1] > image.shape[1]:
        return None
    result = cv2.matchTemplate(image, template, cv2.TM_CCOEFF_NORMED)
    _, score, _, location = cv2.minMaxLoc(result)
    if score < threshold:
        return None
    height, width = template.shape
    return location, width, height, score


def best_template_match(image: np.ndarray, template: np.ndarray) -> tuple | None:
    if template.shape[0] > image.shape[0] or template.shape[1] > image.shape[1]:
        return None
    result = cv2.matchTemplate(image, template, cv2.TM_CCOEFF_NORMED)
    _, score, _, location = cv2.minMaxLoc(result)
    height, width = template.shape
    return location, width, height, score


def find_template_multiscale(
    image: np.ndarray,
    template: np.ndarray,
    threshold: float,
    scales: tuple[float, ...] = (
        0.55,
        0.65,
        0.75,
        0.85,
        0.95,
        1.0,
        1.1,
        1.25,
        1.4,
        1.5,
        1.6,
    ),
) -> tuple | None:
    best: tuple | None = None
    for scale in scales:
        width = max(1, round(template.shape[1] * scale))
        height = max(1, round(template.shape[0] * scale))
        scaled_template = cv2.resize(template, (width, height), interpolation=cv2.INTER_AREA)
        match = best_template_match(image, scaled_template)
        if match and (best is None or match[3] > best[3]):
            best = match
    if best and best[3] >= threshold:
        return best
    return None


def find_stage_1_9_in_list(
    image: np.ndarray,
    label_template: np.ndarray,
    number_template: np.ndarray | None,
    client: dict[str, int],
    threshold: float,
) -> tuple | None:
    if number_template is not None:
        number_match = find_template_multiscale(image, number_template, 0.65)
        if number_match:
            log(f"Matched stage 1-9 number score={number_match[3]:.3f}")
            return number_match
        best_number = find_template_multiscale(image, number_template, 0.0)
        if best_number:
            log(f"Stage 1-9 number best_score={best_number[3]:.3f}")

    scaled_template = scale_template(label_template, client)
    return find_template(image, scaled_template, threshold)


def focus_window(hwnd: int, settle: float = 0.5) -> None:
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, SW_RESTORE)
        human_sleep(0.2, 0.35)
    user32.SetForegroundWindow(hwnd)
    human_sleep(settle, 0.25)


def move_mouse(x: int, y: int) -> None:
    user32.SetCursorPos(x, y)


def send_mouse(flags: int, dx: int = 0, dy: int = 0) -> None:
    event = INPUT(
        type=INPUT_MOUSE,
        union=INPUT_UNION(
            mi=MOUSEINPUT(
                dx=dx,
                dy=dy,
                mouseData=0,
                dwFlags=flags,
                time=0,
                dwExtraInfo=None,
            )
        ),
    )
    sent = user32.SendInput(1, ctypes.byref(event), ctypes.sizeof(INPUT))
    log(f"SendInput flags={flags:#x} dx={dx} dy={dy} sent={sent}")
    if sent != 1:
        raise ctypes.WinError()


def click(hwnd: int, x: int, y: int) -> None:
    log(f"Click start elevated={is_elevated()} hwnd={hwnd} point=({x},{y})")
    focus_window(hwnd, 0.7)

    virtual_left = user32.GetSystemMetrics(76)
    virtual_top = user32.GetSystemMetrics(77)
    virtual_width = user32.GetSystemMetrics(78)
    virtual_height = user32.GetSystemMetrics(79)
    absolute_x = round((x - virtual_left) * 65535 / (virtual_width - 1))
    absolute_y = round((y - virtual_top) * 65535 / (virtual_height - 1))
    send_mouse(
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
        absolute_x,
        absolute_y,
    )
    human_sleep(0.3, 0.35)
    send_mouse(MOUSEEVENTF_LEFTDOWN)
    human_sleep(0.12, 0.45)
    send_mouse(MOUSEEVENTF_LEFTUP)
    log("Click finished")


def scroll_up(hwnd: int, client: dict[str, int], wheel_steps: int) -> None:
    focus_window(hwnd, 0.2)
    x, y = scale_point(client, LIST_MOUSE_POINT)
    move_mouse(
        client["left"] + x,
        client["top"] + y,
    )
    for _ in range(max(1, wheel_steps + random.randint(-2, 2))):
        user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, 120, 0)
        human_sleep(0.06, 0.6, 0.02)


def save_debug_image(
    image: np.ndarray, match: tuple, output_path: Path
) -> None:
    location, width, height, score = match
    debug = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    cv2.rectangle(
        debug,
        location,
        (location[0] + width, location[1] + height),
        (0, 0, 255),
        2,
    )
    cv2.putText(
        debug,
        f"match={score:.3f}",
        (8, 24),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.65,
        (0, 0, 255),
        2,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(output_path), debug)


def save_calibration_shots(output_dir: Path) -> int:
    import mss

    target = find_nte_window()
    if not target:
        print("Khong tim thay cua so NTE de chup calibration.")
        return 2
    focus_window(target["hwnd"], 0.7)
    target = find_nte_window()
    if not target:
        print("Khong tim thay cua so NTE sau khi dua len truoc.")
        return 2

    client = target["client"]
    folder = output_dir / f"{client['width']}x{client['height']}_{time.strftime('%Y%m%d_%H%M%S')}"
    folder.mkdir(parents=True, exist_ok=True)
    with mss.MSS() as sct:
        raw = np.asarray(
            sct.grab(
                {
                    "left": client["left"],
                    "top": client["top"],
                    "width": client["width"],
                    "height": client["height"],
                }
            )
        )
    cv2.imwrite(str(folder / "full.png"), cv2.cvtColor(raw, cv2.COLOR_BGRA2BGR))

    regions = {
        "owner_title": (OWNER_REGION, "left"),
        "stage_list": (LIST_REGION, "left"),
        "selected_stage_title": (TITLE_REGION, "left"),
        "open_shop_area": ({"left": 1040, "top": 625, "width": 225, "height": 80}, "right"),
        "gameplay_title": ({"left": 990, "top": 10, "width": 280, "height": 60}, "right"),
        "gameplay_revenue": ({"left": 1140, "top": 60, "width": 120, "height": 30}, "right"),
        "gameplay_objectives": ({"left": 1000, "top": 90, "width": 265, "height": 155}, "right"),
        "gameplay_exit_button": ({"left": 0, "top": 0, "width": 75, "height": 75}, "left"),
        "challenge_title": ({"left": 350, "top": 85, "width": 580, "height": 115}, "center"),
        "claim_area": ({"left": 640, "top": 500, "width": 270, "height": 110}, "center"),
    }
    for name, (region, anchor) in regions.items():
        image = capture_region(client, region, anchor)
        cv2.imwrite(str(folder / f"{name}.png"), image)

    metadata = folder / "metadata.txt"
    metadata.write_text(
        "\n".join(
            [
                f"title={target['title']}",
                f"class_name={target['class_name']}",
                f"hwnd={target['hwnd']}",
                f"client={client}",
                f"ui_scale={ui_scale(client):.6f}",
            ]
        ),
        encoding="utf-8",
    )
    print(f"Da chup calibration vao: {folder}")
    return 0


def wait_for_stage_1_9(
    client: dict[str, int],
    title_template: np.ndarray,
    title_number_template: np.ndarray | None,
    threshold: float,
    timeout: float,
) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        title_image = capture_region(client, TITLE_REGION)
        match = None
        if title_number_template is not None:
            match = find_template_multiscale(title_image, title_number_template, threshold)
        if not match:
            match = find_template(title_image, scale_template(title_template, client), threshold)
        if match:
            save_debug_image(
                title_image,
                match,
                WORKSPACE / "stage_1_9_debug/verified_stage_1_9_title.png",
            )
            log(f"Verified stage 1-9 title score={match[3]:.3f}")
            return True
        human_sleep(0.25, 0.35)
    log("Stage 1-9 title verification timed out")
    return False


def selected_stage_1_9(
    client: dict[str, int],
    title_template: np.ndarray,
    title_number_template: np.ndarray | None,
    threshold: float,
) -> tuple | None:
    title_image = capture_region(client, TITLE_REGION)
    match = None
    if title_number_template is not None:
        match = find_template_multiscale(title_image, title_number_template, threshold)
    if not match:
        match = find_template(title_image, scale_template(title_template, client), threshold)
    if match:
        save_debug_image(
            title_image,
            match,
            WORKSPACE / "stage_1_9_debug/verified_stage_1_9_title.png",
        )
        log(f"Stage 1-9 already selected score={match[3]:.3f}")
    else:
        best_match = best_template_match(
            title_image,
            scale_template(title_template, client),
        )
        if best_match:
            log(
                "Stage 1-9 title not selected "
                f"best_score={best_match[3]:.3f} threshold={threshold:.3f}"
            )
    return match


def is_owner_selection_screen(
    client: dict[str, int],
    owner_template: np.ndarray,
) -> bool:
    owner_image = capture_region(client, OWNER_REGION)
    match = find_template(
        owner_image,
        scale_template(owner_template, client),
        OWNER_THRESHOLD,
    )
    if match:
        log(f"Owner's Selection title score={match[3]:.3f}")
        return True
    best_match = best_template_match(
        owner_image,
        scale_template(owner_template, client),
    )
    score = best_match[3] if best_match else -1
    log(
        "Owner's Selection title not verified "
        f"best_score={score:.3f} threshold={OWNER_THRESHOLD:.3f} client={client}"
    )
    return False


def verify_support_employees(client: dict[str, int]) -> bool:
    support_image = capture_region(client, SUPPORT_EMPLOYEE_REGION)
    required = {
        "Sakiri": SUPPORT_EMPLOYEE_ASSET_DIR / "sakiri_card.png",
        "Mint": SUPPORT_EMPLOYEE_ASSET_DIR / "mint_card.png",
    }
    missing: list[str] = []
    for name, path in required.items():
        template = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if template is None:
            log(f"Support employee template missing name={name} path={path}")
            missing.append(name)
            continue

        match = find_template_multiscale(
            support_image,
            template,
            SUPPORT_EMPLOYEE_THRESHOLD,
        )
        if match:
            log(f"Support employee verified name={name} score={match[3]:.3f}")
            save_debug_image(
                support_image,
                match,
                WORKSPACE / "stage_1_9_debug" / f"support_{name.lower()}_match.png",
            )
            continue

        best_match = find_template_multiscale(support_image, template, 0.0)
        score = best_match[3] if best_match else -1
        log(
            "Support employee not found "
            f"name={name} best_score={score:.3f} threshold={SUPPORT_EMPLOYEE_THRESHOLD:.3f}"
        )
        missing.append(name)

    if missing:
        print("Support Employee is missing: " + ", ".join(missing) + ".")
        print("Please select Sakiri and Mint before opening the shop.")
        return False

    print("Support Employee checked: Sakiri and Mint are selected.")
    return True


def support_page_visible(client: dict[str, int]) -> bool:
    title_template = cv2.imread(
        str(SUPPORT_EMPLOYEE_PAGE_ASSET_DIR / "page_title.png"),
        cv2.IMREAD_GRAYSCALE,
    )
    if title_template is None:
        log("Support employee page title template is missing")
        return False
    title_image = capture_region(client, SUPPORT_PAGE_TITLE_REGION, "center")
    match = find_template_multiscale(title_image, title_template, SUPPORT_PAGE_THRESHOLD)
    if match:
        log(f"Support employee page visible score={match[3]:.3f}")
        return True

    page_image = capture_region(client, SUPPORT_PAGE_REGION, "center")
    page_match = find_template_multiscale(page_image, title_template, SUPPORT_PAGE_THRESHOLD)
    if page_match:
        log(f"Support employee page visible in modal score={page_match[3]:.3f}")
        return True

    best_title = find_template_multiscale(title_image, title_template, 0.0)
    best_page = find_template_multiscale(page_image, title_template, 0.0)
    score = max(
        best_title[3] if best_title else -1,
        best_page[3] if best_page else -1,
    )
    log(f"Support employee page not visible best_score={score:.3f}")
    return False


def wait_for_support_page(client: dict[str, int], timeout: float = 4.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if support_page_visible(client):
            return True
        human_sleep(0.25, 0.35)
    return False


def click_base_point(
    target: dict,
    point: tuple[int, int],
    anchor: str = "center",
) -> None:
    rel_x, rel_y = scale_point(target["client"], point, anchor)
    click(target["hwnd"], target["client"]["left"] + rel_x, target["client"]["top"] + rel_y)


def support_top_slot_matches(
    client: dict[str, int],
    name: str,
    threshold: float = SUPPORT_TOP_SLOT_THRESHOLD,
) -> bool:
    template = cv2.imread(
        str(SUPPORT_EMPLOYEE_PAGE_ASSET_DIR / f"top_{name.lower()}.png"),
        cv2.IMREAD_GRAYSCALE,
    )
    if template is None:
        log(f"Support top slot template missing name={name}")
        return False
    image = capture_region(client, SUPPORT_TOP_SLOT_REGIONS[name], "center")
    match = find_template_multiscale(image, template, threshold)
    if match:
        log(f"Support top slot verified name={name} score={match[3]:.3f}")
        return True

    page_image = capture_region(client, SUPPORT_PAGE_REGION, "center")
    page_match = find_template_multiscale(page_image, template, threshold)
    if page_match:
        log(f"Support top slot verified in modal name={name} score={page_match[3]:.3f}")
        return True

    best_region = find_template_multiscale(image, template, 0.0)
    best_page = find_template_multiscale(page_image, template, 0.0)
    score = max(
        best_region[3] if best_region else -1,
        best_page[3] if best_page else -1,
    )
    log(
        "Support top slot not verified "
        f"name={name} best_score={score:.3f} threshold={threshold:.3f}"
    )
    return False


def support_employee_selection_ready(client: dict[str, int]) -> bool:
    return (
        support_top_slot_matches(client, "Sakiri")
        and support_top_slot_matches(client, "Mint")
        and support_top_slot_matches(client, "Adler")
    )


def confirm_support_employee(target: dict) -> None:
    click_base_point(target, SUPPORT_CONFIRM_POINT, "center")
    human_sleep(0.8, 0.35)


def save_support_debug(client: dict[str, int], name: str) -> None:
    image = capture_region(client, SUPPORT_PAGE_REGION, "center")
    path = WORKSPACE / "stage_1_9_debug" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(path), image)
    log(f"Saved support debug image {path}")


def prepare_support_employees_1_9(target: dict) -> bool:
    print("Checking Support Employee setup...")
    log("Prepare support: checking current page")
    refreshed = find_nte_window() or target
    target.update(refreshed)

    if support_page_visible(target["client"]):
        log("Prepare support: page already open")
    else:
        log("Prepare support: opening page")
        click_base_point(target, SWAP_EMPLOYEE_POINT, "right")
        human_sleep(0.8, 0.35)
        refreshed = find_nte_window() or target
        target.update(refreshed)
        if not wait_for_support_page(target["client"]):
            log("Prepare support: page open failed")
            print("Could not open Support Employee page.")
            return False
    save_support_debug(target["client"], "support_page_opened.png")

    if support_employee_selection_ready(target["client"]):
        log("Prepare support: already correct")
        print("Support Employee checked: Sakiri, Mint, and Adler.")
        confirm_support_employee(target)
        return True

    print("Support Employee needs update. Selecting Sakiri and Mint...")
    log("Prepare support: removing slot 1")
    # Remove the first two active slots, then re-select stage-specific employees.
    click_base_point(target, SUPPORT_TOP_SLOT_POINTS["slot_1"], "center")
    human_sleep(0.35, 0.35)
    save_support_debug(target["client"], "support_after_slot_1_click.png")
    log("Prepare support: removing slot 2")
    click_base_point(target, SUPPORT_TOP_SLOT_POINTS["slot_2"], "center")
    human_sleep(0.45, 0.35)
    save_support_debug(target["client"], "support_after_slot_2_click.png")
    log("Prepare support: selecting Sakiri")
    click_base_point(target, SUPPORT_LIST_POINTS["Sakiri"], "center")
    human_sleep(0.4, 0.35)
    save_support_debug(target["client"], "support_after_sakiri_click.png")
    log("Prepare support: selecting Mint")
    click_base_point(target, SUPPORT_LIST_POINTS["Mint"], "center")
    human_sleep(0.8, 0.35)
    save_support_debug(target["client"], "support_after_mint_click.png")

    refreshed = find_nte_window() or target
    target.update(refreshed)
    if not support_employee_selection_ready(target["client"]):
        log("Prepare support: final verification failed")
        print("Could not set Support Employee to Sakiri, Mint, and Adler.")
        return False

    log("Prepare support: final verification succeeded")
    print("Support Employee checked: Sakiri, Mint, and Adler.")
    confirm_support_employee(target)
    return True


def open_shop_and_monitor(target: dict, args: argparse.Namespace) -> int:
    if not args.skip_support_employee_check and not prepare_support_employees_1_9(target):
        return 7

    shop_rel_x, shop_rel_y = scale_point(target["client"], OPEN_SHOP_POINT, "right")
    shop_x = target["client"]["left"] + shop_rel_x
    shop_y = target["client"]["top"] + shop_rel_y
    print("Da xac minh giao dien 1-9. Dang bam Open Shop...")
    log(f"Click Open Shop point=({shop_x},{shop_y})")
    click(target["hwnd"], shop_x, shop_y)
    print("Da bam Open Shop.")
    if not args.no_exit_monitor:
        print("Dang cho revenue dat 1,500 HOAC du 3 sao...")
        human_sleep(1.5, 0.35)
        from monitor import monitor_and_exit, sample_revenue_and_exit

        if args.sample_revenue_run:
            return sample_revenue_and_exit(
                args.exit_timeout,
                args.monitor_interval,
                Path(args.revenue_sample_dir),
            )
        return monitor_and_exit(
            args.exit_timeout,
            args.monitor_interval,
            args.wait_for_3_stars,
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Scroll Owner's Selection upward until stage 1-9 is visible, then click it."
    )
    parser.add_argument(
        "--template",
        default=str(WORKSPACE / "stage_1_9_assets/stage_1_9_label.png"),
        help="Template image for the unique 1-9 label",
    )
    parser.add_argument(
        "--title-template",
        default=str(WORKSPACE / "stage_1_9_assets/stage_1_9_title.png"),
        help="Template used to verify that stage 1-9 is actually selected",
    )
    parser.add_argument(
        "--title-number-template",
        default=str(WORKSPACE / "stage_1_9_assets/stage_1_9_selected_title_strict.png"),
        help="Strict template used to verify the selected 1-9 title",
    )
    parser.add_argument(
        "--number-template",
        default=str(WORKSPACE / "stage_1_9_assets/stage_1_9_number.png"),
        help="Template for the stable 1-9 number in the stage list",
    )
    parser.add_argument("--threshold", type=float, default=0.75)
    parser.add_argument("--verify-threshold", type=float, default=0.65)
    parser.add_argument("--verify-timeout", type=float, default=8.0)
    parser.add_argument("--attempts", type=int, default=35)
    parser.add_argument("--wheel-steps", type=int, default=15)
    parser.add_argument("--wait", type=float, default=0.25)
    parser.add_argument("--no-click", action="store_true", help="Only detect, do not click")
    parser.add_argument(
        "--calibrate",
        action="store_true",
        help="Only screenshot the current NTE layout for calibration",
    )
    parser.add_argument(
        "--calibration-dir",
        default=str(WORKSPACE / "calibration_shots"),
        help="Folder where --calibrate stores screenshots",
    )
    parser.add_argument(
        "--no-exit-monitor",
        action="store_true",
        help="Do not monitor gameplay objectives after opening the shop",
    )
    parser.add_argument(
        "--exit-timeout",
        type=float,
        default=0,
        help="Seconds to monitor gameplay; 0 means wait until objectives are complete",
    )
    parser.add_argument(
        "--monitor-interval",
        type=float,
        default=1.0,
        help="Seconds between gameplay objective checks",
    )
    parser.add_argument(
        "--wait-for-3-stars",
        action="store_true",
        help="Do not exit at revenue 1,500; wait until all 3 stars are lit",
    )
    parser.add_argument(
        "--sample-revenue-run",
        action="store_true",
        help="Open shop, sample revenue crops during gameplay, then exit at 1,500",
    )
    parser.add_argument(
        "--revenue-sample-dir",
        default=str(WORKSPACE / "revenue_samples"),
        help="Folder for --sample-revenue-run crops",
    )
    parser.add_argument("--skip-support-employee-check", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--elevated-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    log(f"Main start elevated={is_elevated()} argv={sys.argv!r}")

    if args.calibrate:
        return save_calibration_shots(Path(args.calibration_dir))

    if not args.no_click and not is_elevated():
        if args.elevated_child:
            print("Tien trinh con khong nhan duoc quyen Administrator.")
            log("Elevated child guard stopped relaunch")
            return 4
        print("NTE dang chay Administrator. Dang yeu cau mo script bang Administrator...")
        if relaunch_as_admin():
            log("Elevated child requested")
            return 0
        print("Khong the mo script bang Administrator.")
        return 4

    template = cv2.imread(str(Path(args.template)), cv2.IMREAD_GRAYSCALE)
    title_template = cv2.imread(str(Path(args.title_template)), cv2.IMREAD_GRAYSCALE)
    title_number_template = cv2.imread(
        str(Path(args.title_number_template)), cv2.IMREAD_GRAYSCALE
    )
    number_template = cv2.imread(str(Path(args.number_template)), cv2.IMREAD_GRAYSCALE)
    owner_template = cv2.imread(
        str(WORKSPACE / "loop_assets/owners_selection_title.png"), cv2.IMREAD_GRAYSCALE
    )
    if template is None or title_template is None or owner_template is None:
        print("Khong doc duoc template stage 1-9.")
        return 1

    for attempt in range(1, args.attempts + 1):
        target = find_nte_window()
        if not target:
            print("Khong tim thay cua so NTE 1280x720 tren man hinh trai.")
            return 2

        focus_window(target["hwnd"], 0.5)
        target = find_nte_window()
        if not target:
            print("Khong tim thay cua so NTE sau khi dua len truoc.")
            return 2

        if not is_owner_selection_screen(target["client"], owner_template):
            print("Chua o man Owner's Selection nen khong cuon danh sach.")
            print("Hay mo Owner's Selection/list stage truoc roi chay lai.")
            return 6

        if selected_stage_1_9(
            target["client"],
            title_template,
            title_number_template,
            args.verify_threshold,
        ):
            print("Stage 1-9 dang duoc chon san, khong cuon danh sach.")
            if not args.no_click:
                return open_shop_and_monitor(target, args)
            return 0

        image = capture_list(target["client"])
        scaled_list_region = scale_region(target["client"], LIST_REGION, "left")
        scaled_template = scale_template(template, target["client"])
        match = find_stage_1_9_in_list(
            image,
            template,
            number_template,
            target["client"],
            args.threshold,
        )
        if match:
            location, width, height, score = match
            click_x = target["client"]["left"] + scaled_list_region["left"] + location[0] + width // 2
            click_y = target["client"]["top"] + scaled_list_region["top"] + location[1] + height // 2
            save_debug_image(
                image, match, WORKSPACE / "stage_1_9_debug/found_match.png"
            )
            print(
                f"Da tim thay 1-9 trong danh sach, score={score:.3f}, "
                f"toa do click=({click_x}, {click_y})."
            )
            if not args.no_click:
                log(f"Found match score={score:.3f} click=({click_x},{click_y})")
                click(target["hwnd"], click_x, click_y)
                print("Da bam stage 1-9.")
                if not wait_for_stage_1_9(
                    target["client"],
                    title_template,
                    title_number_template,
                    args.verify_threshold,
                    args.verify_timeout,
                ):
                    print("Chua xac minh duoc giao dien 1-9. KHONG bam Open Shop.")
                    return 5
                return open_shop_and_monitor(target, args)
            return 0

        best_match = best_template_match(image, scaled_template)
        if best_match:
            save_debug_image(
                image,
                best_match,
                WORKSPACE / "stage_1_9_debug/best_stage_1_9_candidate.png",
            )
            log(
                "Stage 1-9 not matched "
                f"attempt={attempt} best_score={best_match[3]:.3f} "
                f"threshold={args.threshold:.3f} client={target['client']}"
            )
            print(
                f"Lan {attempt}: chua thay 1-9 "
                f"(best={best_match[3]:.3f}), dang cuon len..."
            )
        else:
            log(
                "Stage 1-9 template larger than capture "
                f"attempt={attempt} client={target['client']}"
            )
            print(f"Lan {attempt}: chua thay 1-9, dang cuon len...")
        scroll_up(target["hwnd"], target["client"], args.wheel_steps)
        human_sleep(args.wait, 0.4)

    print("Het so lan tim kiem nhung chua thay stage 1-9.")
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
