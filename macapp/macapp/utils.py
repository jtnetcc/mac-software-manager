from __future__ import annotations

import os
import subprocess

HOME = os.path.expanduser("~")


def sh(cmd: list[str], timeout: int = 30) -> tuple[int, str, str]:
    """执行命令，返回 (returncode, stdout, stderr)，永不抛异常。"""
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            errors="replace",
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except FileNotFoundError:
        return 127, "", "command not found"
    except Exception as exc:  # noqa: BLE001
        return 1, "", str(exc)


def human_size(num: int) -> str:
    if num <= 0:
        return "-"
    value = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit == "B":
                return f"{value:.0f} B"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def du_bytes(path: str) -> int:
    """用 du 统计占用（比 os.walk 快，且遵循稀疏文件语义）。"""
    if not os.path.exists(path) and not os.path.islink(path):
        return 0
    if os.path.islink(path):
        return 0
    rc, out, _ = sh(["du", "-sk", path], timeout=120)
    if rc == 0 and out:
        try:
            return int(out.split()[0]) * 1024
        except (ValueError, IndexError):
            return 0
    return 0


def short_path(path: str) -> str:
    """把 /Users/xxx 缩成 ~，方便终端展示。"""
    if path == HOME:
        return "~"
    if path.startswith(HOME + os.sep):
        return "~" + path[len(HOME):]
    return path


def expand(path: str) -> str:
    return os.path.normpath(os.path.expanduser(path))
