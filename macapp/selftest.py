"""自检脚本：不依赖 pytest，直接 python3 selftest.py 运行。

覆盖两块最容易出错的地方：路径安全校验、废纸篓移入/还原。
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from macapp import safety  # noqa: E402
from macapp.trash import move_to_trash, restore_item  # noqa: E402
from macapp.utils import HOME  # noqa: E402

PASS = 0
FAIL = 0


def expect(name: str, got, want) -> None:
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}  期望 {want}，实际 {got}")


def test_safety() -> None:
    print("路径安全校验")
    cases = [
        ("/System/Library/CoreServices/Finder.app", False),
        ("/usr/bin/python3", False),
        ("/bin/sh", False),
        ("/etc/hosts", False),
        (f"{HOME}/Documents/foo", False),
        (f"{HOME}/Downloads/bar", False),
        (f"{HOME}/Library", False),
        (f"{HOME}/Library/Caches", False),
        (f"{HOME}/Library/Application Support", False),
        ("/Applications", False),
        (HOME, False),
        ("/tmp/whatever", False),
        (f"{HOME}/Library/../Documents/x", False),
        (f"{HOME}/.ssh/id_rsa", False),
        (f"{HOME}/Library/Caches/com.example.app", True),
        (f"{HOME}/Library/Application Support/Example", True),
        (f"{HOME}/Library/Containers/com.example.app", True),
        ("/Applications/Example.app", True),
        ("/Library/LaunchDaemons/com.example.plist", True),
    ]
    for path, want in cases:
        ok, _reason = safety.check(path)
        expect(path.replace(HOME, "~"), ok, want)


def test_trash() -> None:
    print("废纸篓移入与还原")
    sandbox = os.path.join(HOME, "Library", "Caches", "macapp_selftest")
    shutil.rmtree(sandbox, ignore_errors=True)
    os.makedirs(sandbox, exist_ok=True)
    target = os.path.join(sandbox, "payload.txt")
    with open(target, "w", encoding="utf-8") as fh:
        fh.write("hello")

    trashed = move_to_trash(target)
    expect("原路径已消失", os.path.exists(target), False)
    expect("废纸篓中存在", os.path.exists(trashed), True)

    restore_item(trashed, target)
    expect("已还原回原路径", os.path.exists(target), True)
    with open(target, encoding="utf-8") as fh:
        expect("内容未损坏", fh.read(), "hello")

    shutil.rmtree(sandbox, ignore_errors=True)


def test_scan_smoke() -> None:
    print("扫描冒烟测试")
    from macapp import apps as apps_mod
    from macapp import scan as scan_mod

    found = apps_mod.discover_apps()
    expect("至少发现一个应用", len(found) > 0, True)
    if not found:
        return
    result = scan_mod.scan(found[0])
    expect("扫描不抛异常", isinstance(result.items, list), True)
    bad = [i.path for i in result.items if not safety.check(i.path)[0]]
    expect("扫描结果全部通过安全校验", bad, [])


def main() -> int:
    test_safety()
    test_trash()
    test_scan_smoke()
    print()
    print(f"通过 {PASS} 项，失败 {FAIL} 项")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
