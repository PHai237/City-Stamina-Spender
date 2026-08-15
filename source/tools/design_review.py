from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WEB_UI = ROOT / "source" / "shared" / "web_ui"
OUT = ROOT / "source" / "_design_review"
VIEWPORTS = {
    "desktop": (960, 640),
    "compact": (820, 560),
}


def run(command: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=check,
    )


def read_open_design_direction(label: str) -> dict[str, object] | None:
    od = od_command()
    if od is None:
        return None
    result = run([od, "tools", "directions", "--label", label, "--json"], check=False)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def od_command() -> str | None:
    for name in ("od.cmd", "od.exe", "od"):
        found = shutil.which(name)
        if found:
            return found
    npm = Path(os.environ.get("APPDATA", "")) / "npm"
    for name in ("od.cmd", "od.ps1"):
        candidate = npm / name
        if candidate.exists():
            return str(candidate)
    return None


def chrome_path() -> str | None:
    candidates = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    ]
    for candidate in candidates:
        if Path(candidate).exists():
            return candidate
    for name in ("chrome", "msedge", "chromium"):
        found = shutil.which(name)
        if found:
            return found
    return None


def file_url(path: Path, query: str = "") -> str:
    return path.resolve().as_uri() + query


def capture_previews() -> tuple[list[str], list[str]]:
    browser = chrome_path()
    if browser is None:
        return [], ["Chrome/Edge was not found; could not capture desktop UI previews."]

    OUT.mkdir(parents=True, exist_ok=True)
    index = WEB_UI / "index.html"
    surfaces = {
        "hub": file_url(index),
        "detail": file_url(index, "?preview=detail"),
    }
    errors: list[str] = []
    shots: list[str] = []
    for viewport, (width, height) in VIEWPORTS.items():
        for surface, url in surfaces.items():
            name = f"{viewport}-{surface}.png"
            shot = OUT / name
            profile = OUT / f"profile-{viewport}-{surface}"
            if profile.exists():
                shutil.rmtree(profile, ignore_errors=True)
            result = run(
                [
                    browser,
                    "--headless=new",
                    "--disable-gpu",
                    "--no-first-run",
                    f"--user-data-dir={profile}",
                    f"--window-size={width},{height}",
                    f"--screenshot={shot}",
                    url,
                ],
                check=False,
            )
            shutil.rmtree(profile, ignore_errors=True)
            if result.returncode != 0 or not shot.exists():
                errors.append(f"Could not capture {name}: {result.stdout.strip()}")
            else:
                shots.append(str(shot.relative_to(ROOT)))
    return shots, errors


def css_value(pattern: str, css: str) -> int | None:
    match = re.search(pattern, css, re.S)
    return int(match.group(1)) if match else None


def css_values(pattern: str, css: str) -> list[int]:
    return [int(value) for value in re.findall(pattern, css, re.S)]


def css_metrics(css: str) -> dict[str, object]:
    action_heights = css_values(r"\.primary-action,\s*\.danger-action\s*\{[^}]*height:\s*(\d+)px", css)
    return {
        "control_card_height": css_value(r"\.control-card\s*\{.*?height:\s*(\d+)px", css),
        "run_stop_button_height": max(action_heights) if action_heights else None,
        "rectangular_radii": sorted(
            {
                int(value)
                for value in re.findall(r"border-radius:\s*(\d+)px", css)
                if 8 < int(value) < 99
            }
        ),
        "target_placeholder": "rgba(123, 132, 147, 0.46)"
        if "target-input::placeholder" in css and "rgba(123, 132, 147, 0.46)" in css
        else "needs-review",
    }


def audit_css() -> tuple[list[str], dict[str, object]]:
    css = (WEB_UI / "styles.css").read_text(encoding="utf-8")
    failures: list[str] = []
    metrics = css_metrics(css)

    rectangular_radii = metrics["rectangular_radii"]
    if rectangular_radii:
        failures.append(
            "Rounded rectangular radius exceeds 8px: "
            + ", ".join(str(value) for value in rectangular_radii)
            + "."
        )

    control_height = metrics["control_card_height"]
    if control_height and control_height > 100:
        failures.append(f".control-card height is {control_height}px; compact desktop controls should stay <= 100px.")

    action_height = metrics["run_stop_button_height"]
    if action_height and action_height > 36:
        failures.append(f"Run/Stop buttons are {action_height}px tall; target 32-36px.")

    if re.search(r"\.run-card\s*\{[^}]*gradient", css, re.S):
        failures.append(".run-card uses a gradient; control panels should stay flat.")

    if re.search(r"\.module-row\s*\{[^}]*background:", css, re.S):
        failures.append(".module-row has its own background; metadata rows should not look like fake buttons.")

    if re.search(r"\.target-input::placeholder\s*\{\s*color:\s*var\(--muted\)", css, re.S):
        failures.append(".target-input placeholder uses --muted; it is too low-contrast for the primary amount field.")

    return failures, metrics


def main() -> int:
    directions: dict[str, str] = {}
    print("Open Design directions:")
    for label in ("tech-utility", "modern-minimal"):
        direction = read_open_design_direction(label)
        if direction is None:
            print(f"- {label}: unavailable")
            directions[label] = "unavailable"
        else:
            mood = str(direction.get("mood", ""))
            print(f"- {label}: {mood}")
            directions[label] = mood

    failures, metrics = audit_css()
    screenshots, preview_failures = capture_previews()
    failures.extend(preview_failures)
    report = {
        "directions": directions,
        "metrics": metrics,
        "screenshots": screenshots,
        "failures": failures,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "review.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"\nPreview output: {OUT}")
    if screenshots:
        print("Screenshots:")
        for screenshot in screenshots:
            print(f"- {screenshot}")
    if failures:
        print("\nDesign review failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("\nDesign review passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
