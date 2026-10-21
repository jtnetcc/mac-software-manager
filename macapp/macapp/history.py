"""卸载历史：每次卸载写一份 manifest，支持按 id 还原。"""

from __future__ import annotations

import json
import os
import time

from .trash import restore_item
from .utils import HOME

BASE = os.path.join(HOME, ".macapp")
HIST_DIR = os.path.join(BASE, "history")


def new_id() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def _path(session_id: str) -> str:
    return os.path.join(HIST_DIR, f"{session_id}.json")


def save(record: dict) -> str:
    os.makedirs(HIST_DIR, exist_ok=True)
    if not record.get("id"):
        record["id"] = new_id()
    record.setdefault("created", time.strftime("%Y-%m-%d %H:%M:%S"))
    target = _path(record["id"])
    with open(target, "w", encoding="utf-8") as fh:
        json.dump(record, fh, ensure_ascii=False, indent=2)
    return target


def load_all() -> list[dict]:
    if not os.path.isdir(HIST_DIR):
        return []
    records = []
    for name in sorted(os.listdir(HIST_DIR), reverse=True):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(HIST_DIR, name), encoding="utf-8") as fh:
                records.append(json.load(fh))
        except Exception:  # noqa: BLE001
            continue
    return records


def load(session_id: str) -> dict | None:
    target = _path(session_id)
    if not os.path.isfile(target):
        return None
    with open(target, encoding="utf-8") as fh:
        return json.load(fh)


def restore(session_id: str) -> tuple[int, int, list[str]]:
    """返回 (还原数, 跳过数, 失败说明)。"""
    record = load(session_id)
    if record is None:
        raise FileNotFoundError(session_id)

    restored = 0
    skipped = 0
    errors: list[str] = []
    for entry in reversed(record.get("items", [])):
        if not entry.get("trashed"):
            continue
        try:
            restore_item(entry["trashed"], entry["original"])
            restored += 1
        except FileExistsError:
            skipped += 1
            errors.append(f"原位置已存在，跳过：{entry['original']}")
        except Exception as exc:  # noqa: BLE001
            errors.append(f"还原失败 {entry['original']}：{exc}")

    record["restored_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
    save(record)
    return restored, skipped, errors
