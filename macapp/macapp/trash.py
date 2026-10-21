"""移入废纸篓，而不是直接删除。

所有删除动作都走这里，保证「可后悔」：
1. 目标移动到 ~/.Trash，同名自动加时间戳。
2. 每次操作写一份 manifest，restore 时按原路径还原。
"""

from __future__ import annotations

import os
import shutil
import time

from .utils import HOME

TRASH = os.path.join(HOME, ".Trash")


def _unique_dest(name: str) -> str:
    os.makedirs(TRASH, exist_ok=True)
    candidate = os.path.join(TRASH, name)
    if not os.path.lexists(candidate):
        return candidate
    stem, ext = os.path.splitext(name)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    candidate = os.path.join(TRASH, f"{stem} {stamp}{ext}")
    index = 2
    while os.path.lexists(candidate):
        candidate = os.path.join(TRASH, f"{stem} {stamp}-{index}{ext}")
        index += 1
    return candidate


def is_writable() -> tuple[bool, str]:
    """预检废纸篓可写性。写不进去就绝不动任何文件，避免不可恢复的删除。"""
    probe = os.path.join(TRASH, f".macapp-probe-{os.getpid()}")
    try:
        os.makedirs(TRASH, exist_ok=True)
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write("")
        os.unlink(probe)
        return True, ""
    except OSError as exc:
        return False, str(exc)


def move_to_trash(path: str) -> str:
    """把 path 移入废纸篓，返回实际落点。失败抛 OSError。"""
    if not os.path.lexists(path):
        raise FileNotFoundError(path)
    dest = _unique_dest(os.path.basename(path))
    shutil.move(path, dest)
    return dest


def restore_item(trashed: str, original: str) -> None:
    """从废纸篓还原到原路径。原路径已存在则抛 FileExistsError。"""
    if not os.path.lexists(trashed):
        raise FileNotFoundError(trashed)
    if os.path.lexists(original):
        raise FileExistsError(original)
    parent = os.path.dirname(original)
    if parent:
        os.makedirs(parent, exist_ok=True)
    shutil.move(trashed, original)
