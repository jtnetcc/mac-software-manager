#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacApp"
DISPLAY_NAME="Mac软件管家"
BUNDLE_ID="com.macapp.gui"
VERSION="1.3"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
TARGET="arm64-apple-macos14.0"
OUT="dist/${DISPLAY_NAME}.app"

echo "==> 清理"
rm -rf "$OUT" build
mkdir -p build "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "==> 编译"
swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$SDK" -target "$TARGET" \
  -o "$OUT/Contents/MacOS/$APP_NAME" Sources/*.swift

echo "==> 资源"
cp Resources/rules.json "$OUT/Contents/Resources/rules.json"

echo "==> 图标"
if [ ! -f Resources/AppIcon.icns ]; then
  if swift Tools/MakeIcon.swift build/icon_1024.png >/dev/null 2>&1; then
    mkdir -p build/AppIcon.iconset
    sips -z 16 16     build/icon_1024.png --out build/AppIcon.iconset/icon_16x16.png      >/dev/null
    sips -z 32 32     build/icon_1024.png --out build/AppIcon.iconset/icon_16x16@2x.png   >/dev/null
    sips -z 32 32     build/icon_1024.png --out build/AppIcon.iconset/icon_32x32.png      >/dev/null
    sips -z 64 64     build/icon_1024.png --out build/AppIcon.iconset/icon_32x32@2x.png   >/dev/null
    sips -z 128 128   build/icon_1024.png --out build/AppIcon.iconset/icon_128x128.png    >/dev/null
    sips -z 256 256   build/icon_1024.png --out build/AppIcon.iconset/icon_128x128@2x.png >/dev/null
    sips -z 256 256   build/icon_1024.png --out build/AppIcon.iconset/icon_256x256.png    >/dev/null
    sips -z 512 512   build/icon_1024.png --out build/AppIcon.iconset/icon_256x256@2x.png >/dev/null
    sips -z 512 512   build/icon_1024.png --out build/AppIcon.iconset/icon_512x512.png    >/dev/null
    cp build/icon_1024.png build/AppIcon.iconset/icon_512x512@2x.png
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
    echo "    已生成 Resources/AppIcon.icns"
  else
    echo "    图标生成失败，跳过"
  fi
fi
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
fi

echo "==> Info.plist"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>本地工具，数据不外传</string>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc）"
codesign --force --sign - "$OUT" 2>&1 | grep -v "replacing existing signature" || true

echo "==> 完成"
du -sh "$OUT" | awk '{print "    "$0}'
