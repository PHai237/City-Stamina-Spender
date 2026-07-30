from __future__ import annotations

import shutil
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_PATH = ROOT / "avalonia_app" / "Embedded" / "app_data.zip"

EXCLUDE_DIR_NAMES = {
    "__pycache__",
    "build",
    "dist",
    "bin",
    "obj",
    "webview_publish",
    "wrapper_debug",
    "stage_1_1_debug",
    "stage_1_9_debug",
    "gameplay_exit_debug",
    "revenue_samples",
}


def should_include(path: Path) -> bool:
    parts = set(path.parts)
    if parts & EXCLUDE_DIR_NAMES:
        return False
    name = path.name.lower()
    if name.endswith((".pyc", ".pyo", ".pdb", ".log", ".spec")):
        return False
    if any(token in name for token in ("_calibration", "_capture", "_test", "_after_confirm")):
        return False
    return True


def add_tree(archive: zipfile.ZipFile, source_dir: Path, archive_root: str) -> None:
    for path in sorted(source_dir.rglob("*")):
        if not path.is_file() or not should_include(path.relative_to(ROOT)):
            continue
        archive.write(path, Path(archive_root) / path.relative_to(source_dir))


def main() -> int:
    owner_tool = ROOT / "owners_selection" / "_tool" / "OwnerSelectionTool.exe"
    if not owner_tool.exists():
        raise SystemExit("OwnerSelectionTool.exe was not found. Build it before creating app_data.zip.")

    BUNDLE_PATH.parent.mkdir(parents=True, exist_ok=True)
    if BUNDLE_PATH.exists():
        BUNDLE_PATH.unlink()

    with zipfile.ZipFile(BUNDLE_PATH, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        add_tree(archive, ROOT / "web_ui", "web_ui")
        add_tree(archive, ROOT / "owners_selection", "owners_selection")

    print(BUNDLE_PATH)
    print(f"{BUNDLE_PATH.stat().st_size / (1024 * 1024):.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
