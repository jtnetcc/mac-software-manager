from __future__ import annotations

import argparse
import json
import sys

from . import __version__
from . import apps as apps_mod
from . import history as hist_mod
from . import scan as scan_mod
from . import uninstall as un_mod
from .errors import MacappError
from .ui import get_theme, human_size, table, truncate
from .utils import du_bytes, short_path


def _confirm(prompt: str, assume_yes: bool) -> bool:
    if assume_yes:
        return True
    if not sys.stdin.isatty():
        raise MacappError("非交互环境必须显式加 --yes 才会执行")
    try:
        answer = input(prompt + " [y/N] ").strip().lower()
    except EOFError:
        return False
    return answer in ("y", "yes")


def _resolve(query: str, apps: list[apps_mod.AppInfo], t) -> apps_mod.AppInfo:
    app, candidates = apps_mod.resolve(query, apps)
    if app:
        return app
    if not candidates:
        raise MacappError(f"未找到已安装的应用：{query}")
    print(t.yellow(f"「{query}」匹配到多个应用，请写得更具体："))
    print()
    for cand in candidates[:12]:
        print(f"  {truncate(cand.display, 28).ljust(28)}  {cand.bundle_id}")
    print()
    raise MacappError("目标不唯一", code=2)


def cmd_list(args, t) -> int:
    apps = apps_mod.discover_apps()
    if not apps:
        print(t.dim("没有找到任何应用。"))
        return 0

    if not args.no_size:
        for app in apps:
            app.size = du_bytes(app.path)

    if args.sort == "size":
        apps.sort(key=lambda a: a.size, reverse=True)
    else:
        apps.sort(key=lambda a: a.display.lower())

    shown = apps[: args.limit] if args.limit > 0 else apps

    if args.json:
        payload = [
            {
                "name": a.display,
                "bundle_id": a.bundle_id,
                "version": a.version,
                "size": a.size,
                "path": a.path,
            }
            for a in shown
        ]
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    rows = [
        [truncate(a.display, 26), a.version or "-", human_size(a.size), a.bundle_id or "-"]
        for a in shown
    ]
    print()
    print(t.bold(f"  已安装应用 {len(apps)} 个"))
    print()
    for line in table(["应用", "版本", "大小", "Bundle ID"], rows, ["left", "left", "right", "left"]).splitlines():
        print("  " + line)
    print()
    print(t.dim(f"  合计占用 {human_size(sum(a.size for a in apps))}"))
    if len(shown) < len(apps):
        print(t.dim(f"  仅显示前 {len(shown)} 个，用 -n 0 查看全部"))
    print()
    return 0


def cmd_inspect(args, t) -> int:
    apps = apps_mod.discover_apps()
    app = _resolve(args.target, apps, t)
    plan = un_mod.build_plan(app, include_low=args.include_low)

    if args.json:
        payload = {
            "app": {
                "name": app.display,
                "bundle_id": app.bundle_id,
                "version": app.version,
                "path": app.path,
            },
            "total_size": plan.total_size,
            "items": [
                {
                    "path": i.path,
                    "label": i.label,
                    "confidence": i.confidence,
                    "size": i.size,
                }
                for i in plan.all_items
            ],
            "privileged": [i.path for i in plan.privileged],
            "protected": plan.protected,
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    un_mod.print_plan(plan, t)
    print(t.dim("  这是只读扫描，没有改动任何文件。执行卸载请用 uninstall。"))
    print()
    return 0


def cmd_uninstall(args, t) -> int:
    apps = apps_mod.discover_apps()
    exit_code = 0

    for index, target in enumerate(args.targets):
        if index:
            print()
            print("─" * 60)
        try:
            app = _resolve(target, apps, t)
        except MacappError as exc:
            print(t.red(f"  {exc.message}"))
            exit_code = exc.code
            continue

        plan = un_mod.build_plan(
            app,
            include_low=args.include_low,
            keep_config=args.keep_config,
        )
        un_mod.print_plan(plan, t)

        if not plan.items and plan.app_item.privileged:
            print(t.red("  应用本体需要管理员权限，无法处理。"))
            exit_code = 3
            continue

        try:
            if not _confirm(t.bold("  确认卸载？"), args.yes):
                print(t.dim("  已跳过。"))
                continue
        except MacappError as exc:
            print(t.red(f"  {exc.message}"))
            return exc.code

        print()
        record = un_mod.execute(
            plan,
            force_quit=args.force_quit,
            do_quit=not args.no_quit,
            t=t,
        )

        print()
        moved = len(record["items"])
        total = record.get("total_size", 0)
        print(t.green(f"  ✓ 已移入废纸篓 {moved} 项，共 {human_size(total)}"))
        print(t.dim(f"    还原命令：macapp restore {record['id']}"))
        if record["errors"]:
            print(t.yellow(f"    {len(record['errors'])} 项未完成："))
            for err in record["errors"][:8]:
                print(t.dim(f"      {short_path(err)}"))
            exit_code = 4
        print()

    return exit_code


def cmd_history(args, t) -> int:
    records = hist_mod.load_all()
    if not records:
        print(t.dim("暂无卸载记录。"))
        return 0

    rows = []
    for rec in records[: args.limit]:
        rows.append(
            [
                rec.get("id", "-"),
                rec.get("created", "-"),
                truncate(rec.get("app", "-"), 20),
                human_size(rec.get("total_size", 0)),
                str(len(rec.get("items", []))),
            ]
        )
    print()
    for line in table(["会话 ID", "时间", "应用", "已清理", "项数"], rows, ["left", "left", "left", "right", "right"]).splitlines():
        print("  " + line)
    print()
    print(t.dim("  还原：macapp restore <会话 ID>"))
    print()
    return 0


def cmd_restore(args, t) -> int:
    record = hist_mod.load(args.session_id)
    if record is None:
        raise MacappError(f"找不到会话：{args.session_id}")

    print()
    print(f"  会话 {record['id']}  {record.get('app', '')}  {record.get('created', '')}")
    print(t.dim(f"  将还原 {len(record.get('items', []))} 项到原位置"))
    if not _confirm(t.bold("  确认还原？"), args.yes):
        print(t.dim("  已取消。"))
        return 0

    restored, skipped, errors = hist_mod.restore(args.session_id)
    print()
    print(t.green(f"  ✓ 已还原 {restored} 项"))
    if skipped:
        print(t.yellow(f"  {skipped} 项因原位置已存在而跳过"))
    for err in errors[:8]:
        print(t.dim(f"    {err}"))
    print()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="macapp",
        description="macOS 软件卸载工具：把应用和它的残留一起清掉，且可还原。",
    )
    parser.add_argument("-V", "--version", action="version", version=f"macapp {__version__}")
    sub = parser.add_subparsers(dest="cmd", metavar="<命令>")

    p = sub.add_parser("list", aliases=["ls"], help="列出已安装应用及占用")
    p.add_argument("-n", "--limit", type=int, default=30, help="显示条数，0 表示全部")
    p.add_argument("--sort", choices=["size", "name"], default="size", help="排序方式")
    p.add_argument("--no-size", action="store_true", help="跳过体积统计（更快）")
    p.add_argument("--json", action="store_true", help="输出 JSON")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("inspect", aliases=["scan"], help="只扫描不改动，查看会清理哪些文件")
    p.add_argument("target", help="应用名、Bundle ID 或 .app 路径")
    p.add_argument("--include-low", action="store_true", help="包含低置信度项（共享容器等）")
    p.add_argument("--json", action="store_true", help="输出 JSON")
    p.set_defaults(func=cmd_inspect)

    p = sub.add_parser("uninstall", aliases=["rm"], help="卸载应用并清理残留")
    p.add_argument("targets", nargs="+", help="应用名、Bundle ID 或 .app 路径")
    p.add_argument("-y", "--yes", action="store_true", help="跳过确认")
    p.add_argument("--include-low", action="store_true", help="包含低置信度项")
    p.add_argument("--keep-config", action="store_true", help="保留偏好与用户数据")
    p.add_argument("--force-quit", action="store_true", help="进程不退则强制结束")
    p.add_argument("--no-quit", action="store_true", help="不尝试退出应用")
    p.set_defaults(func=cmd_uninstall)

    p = sub.add_parser("history", help="查看卸载历史")
    p.add_argument("-n", "--limit", type=int, default=10, help="显示条数")
    p.set_defaults(func=cmd_history)

    p = sub.add_parser("restore", help="按会话 ID 从废纸篓还原")
    p.add_argument("session_id", help="history 里列出的会话 ID")
    p.add_argument("-y", "--yes", action="store_true", help="跳过确认")
    p.set_defaults(func=cmd_restore)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "cmd", None):
        parser.print_help()
        return 0

    t = get_theme()
    try:
        return args.func(args, t)
    except MacappError as exc:
        print(t.red(f"错误：{exc.message}"))
        return exc.code
    except KeyboardInterrupt:
        print()
        print("已取消。")
        return 130
