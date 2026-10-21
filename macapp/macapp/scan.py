"""残留扫描：给定一个 App，找出它在系统各处留下的文件。"""

from __future__ import annotations

import glob
import json
import os
from dataclasses import dataclass

from . import apps as apps_mod
from . import safety
from .utils import HOME, du_bytes

RULES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rules.json")

CONFIDENCE_ORDER = {"high": 0, "medium": 1, "low": 2}
CONFIDENCE_LABEL = {"high": "高", "medium": "中", "low": "低"}


@dataclass
class Item:
    path: str
    label: str
    confidence: str = "high"
    kind: str = "dir"
    size: int = 0
    privileged: bool = False
    source: str = "rules"

    @property
    def exists(self) -> bool:
        return os.path.lexists(self.path)


@dataclass
class ScanResult:
    app: apps_mod.AppInfo
    items: list[Item]
    notes: list[str]

    @property
    def total_size(self) -> int:
        return sum(i.size for i in self.items)


def load_rules() -> dict:
    try:
        with open(RULES_PATH, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001
        return {"templates": [], "globs": [], "keep_config_labels": []}


def _fill(pattern: str, ctx: dict[str, str]) -> str | None:
    try:
        filled = pattern.format(**ctx)
    except (KeyError, IndexError, ValueError):
        return None
    if "{" in filled or "}" in filled:
        return None
    return filled


def _make_item(path: str, label: str, confidence: str, kind: str, source: str) -> Item | None:
    path = os.path.normpath(os.path.expanduser(path))
    if not os.path.lexists(path):
        return None
    return Item(
        path=path,
        label=label,
        confidence=confidence,
        kind=kind if kind != "any" else ("dir" if os.path.isdir(path) else "file"),
        size=du_bytes(path),
        privileged=safety.needs_admin(path),
        source=source,
    )


def _group_containers(app: apps_mod.AppInfo) -> list[Item]:
    """Group Containers 只能模糊匹配，一律标为低置信度。"""
    root = f"{HOME}/Library/Group Containers"
    if not os.path.isdir(root):
        return []
    bid = (app.bundle_id or "").lower()
    token = "".join(ch for ch in app.display.lower() if ch.isalnum())
    hits: list[Item] = []
    for entry in sorted(os.listdir(root)):
        low = entry.lower()
        matched = False
        if bid and low.startswith(bid + "."):
            matched = True
        elif bid and "." in bid and low.startswith(bid.rsplit(".", 1)[0] + ".") and token and token in low.replace(".", ""):
            matched = True
        elif token and len(token) >= 4 and token in low.replace(".", "").replace(" ", ""):
            matched = True
        if not matched:
            continue
        item = _make_item(os.path.join(root, entry), "共享容器", "low", "dir", "group-container")
        if item:
            hits.append(item)
    return hits


def _fuzzy_name_dirs(app: apps_mod.AppInfo) -> list[Item]:
    """数据目录名常与显示名不完全一致（Lark 实际写的是 LarkShell），
    对顶层目录做前缀模糊匹配，一律标低置信度，默认不纳入。"""
    token = "".join(ch for ch in app.display.lower() if ch.isalnum())
    if len(token) < 4:
        return []
    roots = [f"{HOME}/Library/Application Support", f"{HOME}/Library/Caches"]
    hits: list[Item] = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        try:
            entries = os.listdir(root)
        except OSError:
            continue
        for entry in entries:
            norm = "".join(ch for ch in entry.lower() if ch.isalnum())
            if len(norm) < 4:
                continue
            if norm.startswith(token) or token.startswith(norm):
                item = _make_item(os.path.join(root, entry), "疑似数据目录", "low", "any", "fuzzy")
                if item:
                    hits.append(item)
    return hits


def _pkg_items(app: apps_mod.AppInfo) -> tuple[list[Item], list[str]]:
    """通过 pkgutil 收据反查安装包写入的文件。"""
    notes: list[str] = []
    items: list[Item] = []
    pkg_id = app.pkg_id or apps_mod.pkg_id_for(app.path)
    if not pkg_id:
        return items, notes
    app.pkg_id = pkg_id

    for rel in apps_mod.pkg_files(pkg_id):
        full = os.path.normpath(rel)
        if not os.path.lexists(full):
            continue
        if full == app.path or full.startswith(app.path + "/"):
            continue
        ok, reason = safety.check(full)
        if not ok:
            notes.append(f"安装包文件不在可操作范围（{reason}）：{full}")
            continue
        item = _make_item(full, "安装包文件", "high", "file", "pkg")
        if item:
            items.append(item)
    return items, notes


def scan(app: apps_mod.AppInfo, include_low: bool = False) -> ScanResult:
    rules = load_rules()
    ctx = {
        "name": app.display,
        "bundle_name": app.bundle_name or app.display,
        "bundle_id": app.bundle_id or "",
    }

    buckets: dict[str, Item] = {}

    def add(item: Item | None) -> None:
        if item is None:
            return
        if item.path == app.path or item.path.startswith(app.path + "/"):
            return
        key = os.path.realpath(item.path)
        if key in buckets:
            existing = buckets[key]
            if CONFIDENCE_ORDER[item.confidence] < CONFIDENCE_ORDER[existing.confidence]:
                existing.confidence = item.confidence
            return
        buckets[key] = item

    for tpl in rules.get("templates", []):
        raw = tpl.get("path", "")
        if "{bundle_id}" in raw and not app.bundle_id:
            continue
        filled = _fill(raw, ctx)
        if not filled:
            continue
        add(
            _make_item(
                filled,
                tpl.get("label", "残留"),
                tpl.get("confidence", "medium"),
                tpl.get("kind", "dir"),
                "rules",
            )
        )

    for g in rules.get("globs", []):
        raw = g.get("pattern", "")
        if "{bundle_id}" in raw and not app.bundle_id:
            continue
        filled = _fill(raw, ctx)
        if not filled:
            continue
        for hit in glob.glob(os.path.expanduser(filled)):
            add(
                _make_item(
                    hit,
                    g.get("label", "残留"),
                    g.get("confidence", "medium"),
                    g.get("kind", "any"),
                    "glob",
                )
            )

    for item in _group_containers(app):
        if include_low:
            add(item)

    if include_low:
        for item in _fuzzy_name_dirs(app):
            add(item)

    pkg_items, pkg_notes = _pkg_items(app)
    for item in pkg_items:
        add(item)

    items = sorted(buckets.values(), key=lambda i: (-i.size, i.path))

    notes: list[str] = list(pkg_notes)
    for item in items:
        ok, reason = safety.check(item.path)
        if not ok:
            notes.append(f"受保护，不会删除（{reason}）：{item.path}")

    if app.pkg_id:
        notes.append(f"安装包收据：{app.pkg_id}（卸载后可执行 pkgutil --forget {app.pkg_id} 清理）")

    return ScanResult(app=app, items=items, notes=notes)
