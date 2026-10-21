"""卸载流程：计划 -> 确认 -> 退出进程 -> 移入废纸篓 -> 记录 manifest。"""

from __future__ import annotations

import os
import signal
import time
from dataclasses import dataclass, field

from . import apps as apps_mod
from . import history, safety, scan as scan_mod, trash
from .errors import SafetyError
from .ui import table
from .utils import du_bytes, human_size, sh, short_path

CONF_LABEL = {"high": "高", "medium": "中", "low": "低"}


@dataclass
class Plan:
    app: apps_mod.AppInfo
    app_item: scan_mod.Item
    items: list[scan_mod.Item] = field(default_factory=list)
    privileged: list[scan_mod.Item] = field(default_factory=list)
    protected: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def all_items(self) -> list[scan_mod.Item]:
        return [self.app_item] + self.items

    @property
    def total_size(self) -> int:
        return sum(i.size for i in self.all_items)


def build_plan(
    app: apps_mod.AppInfo,
    include_low: bool = False,
    keep_config: bool = False,
) -> Plan:
    result = scan_mod.scan(app, include_low=include_low)
    rules = scan_mod.load_rules()
    keep_labels = set(rules.get("keep_config_labels", []))

    app_item = scan_mod.Item(
        path=app.path,
        label="应用程序",
        confidence="high",
        kind="dir",
        size=app.size or du_bytes(app.path),
        privileged=safety.needs_admin(app.path),
    )

    plan = Plan(app=app, app_item=app_item, notes=list(result.notes))

    for item in result.items:
        if keep_config and item.label in keep_labels:
            plan.notes.append(f"按 --keep-config 保留配置：{item.path}")
            continue
        ok, reason = safety.check(item.path)
        if not ok:
            plan.protected.append(f"{item.path}（{reason}）")
            continue
        if item.privileged:
            plan.privileged.append(item)
            continue
        plan.items.append(item)

    return plan


def print_plan(plan: Plan, t) -> None:
    app = plan.app
    pairs = [
        ("目标应用", f"{app.display} {app.version}".strip()),
        ("安装位置", short_path(app.path)),
        ("Bundle ID", app.bundle_id or "未知"),
        ("占用合计", human_size(plan.total_size)),
    ]
    print()
    print(t.bold(f"  {app.display}"))
    for key, value in pairs:
        print(f"  {t.dim(key.ljust(9))}  {value}")

    rows = []
    for item in plan.all_items:
        rows.append(
            [
                item.label,
                CONF_LABEL.get(item.confidence, "?"),
                human_size(item.size),
                short_path(item.path),
            ]
        )

    print()
    print(t.bold(f"  将移入废纸篓（{len(rows)} 项，{human_size(plan.total_size)}）"))
    print()
    for line in _table(rows).splitlines():
        print("    " + line)

    if plan.privileged:
        print()
        print(t.yellow(f"  需要管理员权限，本次不处理（{len(plan.privileged)} 项）"))
        for item in plan.privileged:
            print(f"    {short_path(item.path)}")
        print(t.dim("    如需清理，可执行："))
        for item in plan.privileged:
            print(t.dim(f"      sudo rm -rf '{item.path}'"))

    if plan.protected:
        print()
        print(t.dim(f"  受保护未纳入（{len(plan.protected)} 项）"))
        for entry in plan.protected:
            print(t.dim(f"    {short_path(entry)}"))

    extra_notes = [n for n in plan.notes if "按 --keep-config 保留配置" in n]
    if extra_notes:
        print()
        for note in extra_notes:
            print(t.dim(f"  · {short_path(note.split('：', 1)[-1])} 已保留"))

    print()


def _table(rows: list[list[str]]) -> str:
    return table(["类型", "置信度", "大小", "路径"], rows, ["left", "left", "right", "left"])


def quit_app(app: apps_mod.AppInfo, timeout: int = 6, force: bool = False) -> str:
    pids = apps_mod.is_running(app)
    if not pids:
        return "未在运行"

    if app.bundle_id:
        sh(["osascript", "-e", f'tell application id "{app.bundle_id}" to quit'], timeout=10)
    else:
        sh(["osascript", "-e", f'tell application "{app.display}" to quit'], timeout=10)

    deadline = time.time() + timeout
    while time.time() < deadline:
        if not apps_mod.is_running(app):
            return "已退出"
        time.sleep(0.5)

    for pid in apps_mod.is_running(app):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    time.sleep(2)

    if apps_mod.is_running(app):
        if not force:
            return "仍在运行（可加 --force-quit 强制结束）"
        for pid in apps_mod.is_running(app):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        time.sleep(1)
        return "已强制结束" if not apps_mod.is_running(app) else "无法结束"

    return "已结束"


def execute(plan: Plan, force_quit: bool = False, do_quit: bool = True, t=None) -> dict:
    record = {
        "id": history.new_id(),
        "app": plan.app.display,
        "bundle_id": plan.app.bundle_id,
        "path": plan.app.path,
        "items": [],
        "errors": [],
    }

    writable, reason = trash.is_writable()
    if not writable:
        record["errors"].append(f"废纸篓不可写：{reason}")
        history.save(record)
        if t:
            print(t.red(f"  ✗ 废纸篓不可写（{reason}），已中止，未改动任何文件。"))
            print(t.dim("    请到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」为终端授权后重试。"))
        return record

    if do_quit:
        status = quit_app(plan.app, force=force_quit)
        if t:
            print(f"  进程状态  {status}")
        if "仍在运行" in status or status == "无法结束":
            record["errors"].append(f"进程未退出：{status}")

    moved: list[scan_mod.Item] = []

    try:
        safety.assert_safe(plan.app_item.path)
        dest = trash.move_to_trash(plan.app_item.path)
        moved.append(plan.app_item)
        record["items"].append(
            {
                "original": plan.app_item.path,
                "trashed": dest,
                "size": plan.app_item.size,
                "label": plan.app_item.label,
            }
        )
        if t:
            print(t.green(f"  ✓ 已移除应用本体 {short_path(plan.app_item.path)}"))
    except (SafetyError, OSError) as exc:
        record["errors"].append(f"应用本体删除失败：{exc}")
        history.save(record)
        if t:
            print(t.red(f"  ✗ 应用本体删除失败：{exc}"))
            print(t.dim("    已中止，未触碰任何残留文件。"))
        return record

    for item in plan.items:
        try:
            safety.assert_safe(item.path)
            dest = trash.move_to_trash(item.path)
            moved.append(item)
            record["items"].append(
                {
                    "original": item.path,
                    "trashed": dest,
                    "size": item.size,
                    "label": item.label,
                }
            )
        except (SafetyError, OSError) as exc:
            record["errors"].append(f"{item.path}：{exc}")

    record["total_size"] = sum(i.size for i in moved)
    history.save(record)
    return record
