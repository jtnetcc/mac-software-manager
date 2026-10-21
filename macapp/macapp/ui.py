from __future__ import annotations

import os
import sys
import unicodedata

from .utils import human_size  # noqa: F401  (re-export 方便调用方)


def width(text: str) -> int:
    """终端显示宽度，CJK 字符按 2 列算。"""
    total = 0
    for ch in text:
        if unicodedata.combining(ch):
            continue
        total += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return total


def truncate(text: str, limit: int) -> str:
    if width(text) <= limit:
        return text
    out = ""
    for ch in text:
        if width(out + ch) > limit - 1:
            break
        out += ch
    return out + "…"


def ljust(text: str, limit: int) -> str:
    return text + " " * max(0, limit - width(text))


def rjust(text: str, limit: int) -> str:
    return " " * max(0, limit - width(text)) + text


class Theme:
    def __init__(self, enabled: bool):
        self.enabled = enabled

    def _wrap(self, code: str, text: str) -> str:
        if not self.enabled:
            return text
        return f"\033[{code}m{text}\033[0m"

    def bold(self, t: str) -> str:
        return self._wrap("1", t)

    def dim(self, t: str) -> str:
        return self._wrap("2", t)

    def red(self, t: str) -> str:
        return self._wrap("31", t)

    def green(self, t: str) -> str:
        return self._wrap("32", t)

    def yellow(self, t: str) -> str:
        return self._wrap("33", t)

    def cyan(self, t: str) -> str:
        return self._wrap("36", t)


def get_theme() -> Theme:
    if os.environ.get("NO_COLOR"):
        return Theme(False)
    return Theme(sys.stdout.isatty())


def table(headers: list[str], rows: list[list[str]], aligns: list[str] | None = None) -> str:
    cols = len(headers)
    aligns = aligns or ["left"] * cols
    widths = [width(h) for h in headers]
    for row in rows:
        for i in range(cols):
            widths[i] = max(widths[i], width(str(row[i])))
    lines = ["  ".join(ljust(h, widths[i]) for i, h in enumerate(headers))]
    lines.append("  ".join("─" * widths[i] for i in range(cols)))
    for row in rows:
        cells = []
        for i in range(cols):
            cell = str(row[i])
            cells.append(ljust(cell, widths[i]) if aligns[i] == "left" else rjust(cell, widths[i]))
        lines.append("  ".join(cells))
    return "\n".join(lines)


def rule(title: str = "", limit: int = 72) -> str:
    if not title:
        return "─" * limit
    side = max(2, (limit - width(title) - 2) // 2)
    return "─" * side + f" {title} " + "─" * side


def kv(pairs: list[tuple[str, str]], indent: str = "  ") -> str:
    if not pairs:
        return ""
    key_w = max(width(k) for k, _ in pairs)
    return "\n".join(f"{indent}{ljust(k, key_w)}  {v}" for k, v in pairs)
