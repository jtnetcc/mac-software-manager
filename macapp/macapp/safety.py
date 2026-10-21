"""路径安全校验：所有删除动作必须经过这里。

设计原则：
1. 只允许在显式白名单目录的「子路径」上操作（父目录本身永不可删）。
2. 系统目录、用户文档目录、共享 Library 目录列为禁区。
3. 符号链接按其字面路径判断，避免 realpath 被牵引到白名单之外。
"""

from __future__ import annotations

import os

from .errors import SafetyError

HOME = os.path.expanduser("~")

# 绝对不可删除的路径（精确匹配）
PROTECTED_PATHS: set[str] = {
    "/",
    "/System",
    "/usr",
    "/bin",
    "/sbin",
    "/etc",
    "/private",
    "/var",
    "/opt",
    "/Library",
    "/Applications",
    "/Users",
    "/Volumes",
    "/cores",
    "/dev",
    HOME,
    f"{HOME}/Library",
    f"{HOME}/Library/Application Support",
    f"{HOME}/Library/Caches",
    f"{HOME}/Library/Preferences",
    f"{HOME}/Library/Logs",
    f"{HOME}/Library/Containers",
    f"{HOME}/Library/Group Containers",
    f"{HOME}/Library/Saved Application State",
    f"{HOME}/Library/HTTPStorages",
    f"{HOME}/Library/WebKit",
    f"{HOME}/Library/Cookies",
    f"{HOME}/Library/LaunchAgents",
    f"{HOME}/Library/Application Scripts",
    f"{HOME}/Library/PreferencePanes",
    f"{HOME}/Library/QuickLook",
    f"{HOME}/Library/Services",
    f"{HOME}/Library/Internet Plug-Ins",
    f"{HOME}/Library/Spotlight",
    f"{HOME}/Library/Address Book Plug-Ins",
    f"{HOME}/Applications",
    f"{HOME}/.Trash",
    f"{HOME}/.macapp",
}

# 这些目录下的一切都不许动
FORBIDDEN_SUBTREES: tuple[str, ...] = (
    "/System",
    "/usr",
    "/bin",
    "/sbin",
    "/etc",
    "/private",
    "/var",
    "/opt",
    "/Library/Apple",
    "/Library/Extensions",
    "/Library/Frameworks",
    f"{HOME}/Documents",
    f"{HOME}/Desktop",
    f"{HOME}/Downloads",
    f"{HOME}/Pictures",
    f"{HOME}/Music",
    f"{HOME}/Movies",
    f"{HOME}/Library/Keychains",
    f"{HOME}/Library/Mobile Documents",
    f"{HOME}/Library/CloudStorage",
    f"{HOME}/Library/Mail",
    f"{HOME}/Library/Messages",
    f"{HOME}/Library/Safari",
    f"{HOME}/Library/Accounts",
    f"{HOME}/.ssh",
    f"{HOME}/.gnupg",
    f"{HOME}/.config",
)

# 允许操作的白名单根（其下子项可删）
ALLOWED_ROOTS: tuple[str, ...] = (
    "/Applications",
    f"{HOME}/Applications",
    "/Library/Application Support",
    "/Library/Caches",
    "/Library/Preferences",
    "/Library/Logs",
    "/Library/LaunchAgents",
    "/Library/LaunchDaemons",
    "/Library/PrivilegedHelperTools",
    "/Library/Receipts",
    "/Library/Fonts",
    f"{HOME}/Library/Application Support",
    f"{HOME}/Library/Caches",
    f"{HOME}/Library/Preferences",
    f"{HOME}/Library/Preferences/ByHost",
    f"{HOME}/Library/Logs",
    f"{HOME}/Library/Containers",
    f"{HOME}/Library/Group Containers",
    f"{HOME}/Library/Saved Application State",
    f"{HOME}/Library/HTTPStorages",
    f"{HOME}/Library/WebKit",
    f"{HOME}/Library/Cookies",
    f"{HOME}/Library/LaunchAgents",
    f"{HOME}/Library/Application Scripts",
    f"{HOME}/Library/PreferencePanes",
    f"{HOME}/Library/QuickLook",
    f"{HOME}/Library/Services",
    f"{HOME}/Library/Internet Plug-Ins",
    f"{HOME}/Library/Spotlight",
    f"{HOME}/Library/Address Book Plug-Ins",
    f"{HOME}/Library/Fonts",
)


def normalize(path: str) -> str:
    path = os.path.expanduser(path)
    if not path.startswith("/"):
        path = os.path.abspath(path)
    return os.path.normpath(path)


def _raw_has_dotdot(path: str) -> bool:
    return ".." in os.path.expanduser(path).split(os.sep)


def check(path: str) -> tuple[bool, str]:
    """返回 (是否允许删除, 原因)。"""
    if not path or "\x00" in path or "\n" in path:
        return False, "路径非法"
    if _raw_has_dotdot(path):
        return False, "路径包含 .. 片段"
    p = normalize(path)

    if not p.startswith("/"):
        return False, "必须是绝对路径"
    if p in PROTECTED_PATHS:
        return False, "受保护的目录本身不可删除"

    for forbidden in FORBIDDEN_SUBTREES:
        if p == forbidden or p.startswith(forbidden + "/"):
            return False, f"位于禁区 {forbidden}"

    if not any(p.startswith(root + "/") for root in ALLOWED_ROOTS):
        return False, "不在允许操作的目录内"

    # 符号链接：允许删除链接本身，但如果它指向禁区则拒绝，避免误删实体
    if os.path.islink(p):
        real = os.path.realpath(p)
        if real != p:
            for forbidden in FORBIDDEN_SUBTREES:
                if real == forbidden or real.startswith(forbidden + "/"):
                    return False, f"符号链接指向禁区 {forbidden}"

    return True, ""


def assert_safe(path: str) -> None:
    ok, reason = check(path)
    if not ok:
        raise SafetyError(f"拒绝操作 {path}：{reason}", path=path)


def needs_admin(path: str) -> bool:
    """判断删除该项是否需要管理员权限（看父目录是否可写）。"""
    p = normalize(path)
    parent = os.path.dirname(p)
    if parent.startswith("/Library/"):
        return True
    return not os.access(parent, os.W_OK)
