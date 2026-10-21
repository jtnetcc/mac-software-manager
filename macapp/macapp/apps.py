"""应用发现与 Info.plist 解析。"""

from __future__ import annotations

import os
import plistlib
from dataclasses import dataclass, field

from .utils import HOME, du_bytes, sh

APP_ROOTS = [
    "/Applications",
    f"{HOME}/Applications",
]

MAX_DEPTH = 3


@dataclass
class AppInfo:
    path: str
    name: str
    bundle_id: str = ""
    bundle_name: str = ""
    version: str = ""
    executable: str = ""
    size: int = 0
    pkg_id: str = ""
    extra: dict = field(default_factory=dict)

    @property
    def display(self) -> str:
        return self.name or os.path.basename(self.path).removesuffix(".app")

    @property
    def search_blob(self) -> str:
        return f"{self.display} {self.bundle_id} {self.bundle_name}".lower()


def _read_plist(app_path: str) -> dict:
    for candidate in (
        os.path.join(app_path, "Contents", "Info.plist"),
        os.path.join(app_path, "Info.plist"),
    ):
        if os.path.isfile(candidate):
            try:
                with open(candidate, "rb") as fh:
                    return plistlib.load(fh)
            except Exception:  # noqa: BLE001
                continue
    return {}


def load_app(app_path: str) -> AppInfo:
    app_path = os.path.normpath(os.path.abspath(os.path.expanduser(app_path)))
    info = _read_plist(app_path)
    name = (
        info.get("CFBundleDisplayName")
        or info.get("CFBundleName")
        or os.path.basename(app_path).removesuffix(".app")
    )
    return AppInfo(
        path=app_path,
        name=str(name),
        bundle_id=str(info.get("CFBundleIdentifier", "") or ""),
        bundle_name=str(info.get("CFBundleName", "") or ""),
        version=str(info.get("CFBundleShortVersionString", "") or ""),
        executable=str(info.get("CFBundleExecutable", "") or ""),
    )


def discover_apps(roots: list[str] | None = None) -> list[AppInfo]:
    """遍历应用目录，返回去重后的 AppInfo 列表（不含体积，按需计算）。"""
    roots = roots or APP_ROOTS
    found: dict[str, AppInfo] = {}

    for root in roots:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        base_depth = root.rstrip("/").count("/")
        for dirpath, dirnames, _files in os.walk(root, followlinks=False):
            if dirpath.rstrip("/").count("/") - base_depth >= MAX_DEPTH:
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for dirname in list(dirnames):
                if dirname.endswith(".app"):
                    full = os.path.join(dirpath, dirname)
                    if full not in found:
                        found[full] = load_app(full)
                    dirnames.remove(dirname)

    return sorted(found.values(), key=lambda a: a.display.lower())


def resolve(query: str, apps: list[AppInfo] | None = None) -> tuple[AppInfo | None, list[AppInfo]]:
    """把用户输入解析成唯一 App。返回 (命中, 候选列表)。"""
    apps = apps if apps is not None else discover_apps()
    q = query.strip()
    if not q:
        return None, []

    expanded = os.path.expanduser(q)
    if expanded.endswith(".app") and os.path.isdir(expanded):
        target = os.path.normpath(os.path.abspath(expanded))
        for app in apps:
            if os.path.normpath(app.path) == target:
                return app, []
        return load_app(target), []

    ql = q.lower()

    exact = [a for a in apps if a.bundle_id.lower() == ql]
    if len(exact) == 1:
        return exact[0], []

    exact_name = [a for a in apps if a.display.lower() == ql]
    if len(exact_name) == 1:
        return exact_name[0], []

    partial = [
        a
        for a in apps
        if ql in a.display.lower() or (a.bundle_id and ql in a.bundle_id.lower())
    ]
    if len(partial) == 1:
        return partial[0], []

    return None, exact_name or partial


def is_running(app: AppInfo) -> list[int]:
    """按可执行文件全路径匹配进程，避免误杀同名进程。"""
    if not app.executable:
        return []
    needle = os.path.join(app.path, "Contents", "MacOS", app.executable)
    rc, out, _ = sh(["pgrep", "-f", needle])
    if rc != 0 or not out:
        return []
    pids = []
    for line in out.splitlines():
        line = line.strip()
        if line.isdigit():
            pids.append(int(line))
    return pids


def pkg_id_for(path: str) -> str:
    """用 pkgutil 反查某个路径属于哪个安装包。"""
    rc, out, _ = sh(["pkgutil", "--file-info", path])
    if rc != 0:
        return ""
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("pkgid:"):
            return line.split(":", 1)[1].strip()
    return ""


def pkg_files(pkg_id: str) -> list[str]:
    rc, out, _ = sh(["pkgutil", "--files", pkg_id], timeout=60)
    if rc != 0:
        return []
    result = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line == ".":
            continue
        result.append(line if line.startswith("/") else "/" + line)
    return result
