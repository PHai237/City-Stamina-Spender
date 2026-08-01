from __future__ import annotations

import json
import queue
import threading
import time

import cv2
import numpy as np

from stage_1_1_orders import DEBUG_DIR, ItemMatch, save_debug


SAMPLE_DIR = DEBUG_DIR / "samples"
DEFAULT_SAMPLE_LIMIT = 40


class SampleRing:
    def __init__(self, limit: int = DEFAULT_SAMPLE_LIMIT) -> None:
        self.limit = max(5, limit)
        self.session = time.strftime("%Y%m%d_%H%M%S")
        self.dir = SAMPLE_DIR / self.session
        self.manifest_path = self.dir / "manifest.json"
        self.records: list[dict] = []
        self.queue: queue.Queue[tuple[int, np.ndarray, list[ItemMatch], int]] = queue.Queue(maxsize=3)
        self.worker = threading.Thread(target=self._run, daemon=True)
        self.worker.start()

    def save(self, scan_index: int, image: np.ndarray, matches: list[ItemMatch], handled: int) -> None:
        try:
            self.queue.put_nowait((scan_index, image.copy(), list(matches), handled))
        except queue.Full:
            pass

    def _run(self) -> None:
        while True:
            scan_index, image, matches, handled = self.queue.get()
            try:
                self._save_now(scan_index, image, matches, handled)
            finally:
                self.queue.task_done()

    def _save_now(self, scan_index: int, image: np.ndarray, matches: list[ItemMatch], handled: int) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        slot = scan_index % self.limit
        raw_path = self.dir / f"scan_{slot:02d}.png"
        marked_path = self.dir / f"scan_{slot:02d}_marked.png"
        cv2.imwrite(str(raw_path), image)
        save_debug(image, matches, marked_path)

        record = {
            "slot": slot,
            "scan": scan_index,
            "handled": handled,
            "created_at": time.strftime("%H:%M:%S"),
            "raw": raw_path.name,
            "marked": marked_path.name,
            "matches": [
                {
                    "item_id": match.item.item_id,
                    "key": match.item.key,
                    "label": match.item.label,
                    "x": match.x,
                    "y": match.y,
                    "width": match.width,
                    "height": match.height,
                    "score": round(match.score, 4),
                    "scale": round(match.scale, 4),
                }
                for match in matches
            ],
        }
        self.records = [item for item in self.records if item["slot"] != slot]
        self.records.append(record)
        self.records.sort(key=lambda item: item["scan"])
        if len(self.records) > self.limit:
            self.records = self.records[-self.limit :]

        payload = {
            "session": self.session,
            "limit": self.limit,
            "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "records": self.records,
        }
        self.manifest_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
