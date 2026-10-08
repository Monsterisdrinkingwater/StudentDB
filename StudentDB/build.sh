#!/bin/bash
# 构建 学生信息管理系统.app
# 用法: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="学生信息管理系统"
BUNDLE_ID="com.monsterisdrinkingwater.studentdb"
VERSION="3.0.67"
APP_DIR="build/$APP_NAME.app"

echo "==> 编译 (release)..."
swift build -c release 2>&1 | sed 's/^/    /'
BIN=".build/release/StudentDB"
if [ ! -f "$BIN" ]; then
    echo "编译产物缺失: $BIN"
    exit 1
fi

echo "==> 生成图标..."
mkdir -p Resources
if [ ! -f Resources/AppIcon.icns ]; then
    swift tools/make_icon.swift "$(pwd)/Resources/AppIcon.icns" || echo "图标生成失败（跳过，不影响功能）"
fi

echo "==> 组装 $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/StudentDB"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>StudentDB</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.education</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleName</key>
            <string>学生信息项目</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>${BUNDLE_ID}.project</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>${BUNDLE_ID}.project</string>
            <key>UTTypeDescription</key>
            <string>学生信息项目</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>com.apple.package</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>studentproj</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

cp README.md "$APP_DIR/Contents/Resources/README.md" 2>/dev/null || true

echo "==> 签名 (ad-hoc)..."
codesign --force --sign - "$APP_DIR"

echo ""
echo "构建完成: $(pwd)/$APP_DIR"
echo "双击打开，或拖到「应用程序」文件夹使用。"
