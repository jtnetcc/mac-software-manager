#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacApp"
DISPLAY_NAME="Mac软件管家"
VERSION="1.4"
APP="dist/${DISPLAY_NAME}.app"
DMG="dist/${DISPLAY_NAME}-${VERSION}.dmg"
STAGE="build/dmg-stage"

if [ ! -d "$APP" ]; then
  echo "==> 未找到 $APP，先构建"
  ./build.sh
fi

echo "==> 准备安装盘内容"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'TXT'
安装方式
========
把左边的「Mac软件管家」拖到右边的 Applications 文件夹即可。

首次打开
========
如果提示「无法验证开发者」，请右键点击图标，选择「打开」，再确认一次。
（本应用为本地 ad-hoc 签名，没有经过苹果公证。）

它能做什么
==========
· 卸载：列出应用本体与散落在 ~/Library 各处的残留文件，勾选后一次性清理
· 彻底删除：直接删除、不进废纸篓，用于清理不需要保留数据的软件
· 残留扫描：应用早就删了、数据还在的目录，一次扫出来清掉
· 推荐卸载：按「多久没用」和「缓存大小」打分，告诉你哪些可以清
· 占用分析：系统软件 / 自装软件分组，每个应用占硬盘多少一目了然
· 安装：支持 dmg / pkg / zip / app，也可以直接拖进窗口
· 还原：走「移入废纸篓」的卸载，记录里可一键搬回原位置

关于「最后使用时间」
==================
macOS 没有公开的「应用上次启动时间」接口，本应用拼了三个来源：
Spotlight 系统记录（精确，但只覆盖约 8% 的应用）、
应用数据目录的修改时间（覆盖约一半）、
应用本体的修改时间（只说明安装时间）。
界面上每一项都标了来源，不冒充精确数据。

数据只在本机，不联网。
TXT

echo "==> 生成 DMG"
ERRLOG=$(mktemp)
if ! hdiutil create \
  -volname "$DISPLAY_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null 2>"$ERRLOG"; then
  cat "$ERRLOG" >&2; exit 1
fi

echo "==> 校验"
if hdiutil verify "$DMG" >/dev/null 2>&1; then
  echo "    镜像完整性 OK"
else
  echo "    镜像校验失败" >&2
  exit 1
fi

MOUNT_POINT="/Volumes/${DISPLAY_NAME}"
hdiutil attach "$DMG" -nobrowse -readonly >/dev/null 2>&1
trap 'hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true' EXIT
if [ -d "$MOUNT_POINT/${DISPLAY_NAME}.app" ]; then
  echo "    挂载校验 OK：$(ls "$MOUNT_POINT" | tr '\n' ' ')"
else
  echo "    挂载校验失败" >&2
  exit 1
fi
hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
trap - EXIT
rm -f "$ERRLOG"

echo "==> 完成"
ls -lh "$DMG" | awk '{print "    "$9"  "$5}'
shasum -a 256 "$DMG" | awk '{print "    SHA256 "$1}'
