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


def capture_previews() -> list[str]:
    browser = chrome_path()
    if browser is None:
        return ["Chrome/Edge was not found; could not capture desktop UI previews."]

    OUT.mkdir(parents=True, exist_ok=True)
    index = WEB_UI / "index.html"
    targets = {
        "desktop-hub.png": file_url(index),
        "desktop-detail.png": file_url(index, "?preview=detail"),
    }
    errors: list[str] = []
    for name, url in targets.items():
        shot = OUT / name
        profile = OUT / f"profile-{name}"
        if profile.exists():
            shutil.rmtree(profile, ignore_errors=True)
        result = run(
            [
                browser,
                "--headless=new",
                "--disable-gpu",
                "--no-first-run",
                f"--user-data-dir={profile}",
                "--window-size=960,640",
                f"--screenshot={shot}",
                url,
            ],
            check=False,
        )
        shutil.rmtree(profile, ignore_errors=True)
        if result.returncode != 0 or not shot.exists():
            errors.append(f"Could not capture {name}: {result.stdout.strip()}")
    return errors


def css_value(pattern: str, css: str) -> int | None:
    match = re.search(pattern, css, re.S)
    return int(match.group(1)) if match else None


def audit_css() -> list[str]:
    css = (WEB_UI / "styles.css").read_text(encoding="utf-8")
    failures: list[str] = []

    rectangular_radii = [
        int(value)
        for value in re.findall(r"border-radius:\s*(\d+)px", css)
        if 8 < int(value) < 99
    ]
    if rectangular_radii:
        failures.append(
            "Rounded rectangular radius exceeds 8px: "
            + ", ".join(str(value) for value in sorted(set(rectangular_radii)))
            + "."
        )

    control_height = css_value(r"\.control-card\s*\{.*?height:\s*(\d+)px", css)
    if control_height and control_height > 100:
        failures.append(f".control-card height is {control_height}px; compact desktop controls should stay <= 100px.")

    action_height = css_value(r"\.primary-action,\s*\.danger-action\s*\{.*?height:\s*(\d+)px", css)
    if action_height and action_height > 36:
        failures.append(f"Run/Stop buttons are {action_height}px tall; target 32-36px.")

    if re.search(r"\.run-card\s*\{[^}]*gradient", css, re.S):
        failures.append(".run-card uses a gradient; control panels should stay flat.")

    if re.search(r"\.module-row\s*\{[^}]*background:", css, re.S):
        failures.append(".module-row has its own background; metadata rows should not look like fake buttons.")

    return failures


def main() -> int:
    print("Open Design directions:")
    for label in ("tech-utility", "modern-minimal"):
        direction = read_open_design_direction(label)
        if direction is None:
            print(f"- {label}: unavailable")
        else:
            print(f"- {label}: {direction.get('mood', '')}")

    failures = audit_css()
    failures.extend(capture_previews())

    print(f"\nPreview output: {OUT}")
    if failures:
        print("\nDesign review failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("\nDesign review passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
