#!/bin/bash
# iOS 端类型检查（自包含脚本）
#
# 口径见 ios/README-BUILD.md 第 2/3 节：iOS App target 不依赖 SwiftPM 包，
# 而是把共享源码作为成员文件直接编译。本脚本按同一口径，用 iOS 模拟器 SDK
# 对下列文件整体 swiftc -typecheck：
#   ios/StudentDBiOS/*.swift                        （iOS 应用全部源码）
#   ../Sources/StudentDB/Models/*.swift             （共享模型）
#   ../Sources/StudentDB/Store/*.swift              （共享存储层）
#   ../Sources/StudentDB/Views/LockScreenView.swift （唯一跨平台的共享视图）
#
# 用法: ./typecheck.sh   （脚本自行 cd 到所在目录，可从任意路径调用）
set -euo pipefail
cd "$(dirname "$0")"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# 部署目标 17.0，对齐 Package.swift 的 .iOS(.v17) 与 README-BUILD.md 第 4 节
TARGET="arm64-apple-ios17.0-simulator"

FILES=(
    StudentDBiOS/*.swift
    ../Sources/StudentDB/Models/*.swift
    ../Sources/StudentDB/Store/*.swift
    ../Sources/StudentDB/Views/LockScreenView.swift
)

echo "==> SDK: $SDK_PATH"
echo "==> target: $TARGET"
echo "==> swiftc -typecheck $(printf '%s ' "${FILES[@]}" | xargs)"
# 仅做类型检查；warning 不算失败，error 会让 swiftc 以非零退出（set -e 接住）
xcrun swiftc -typecheck \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    "${FILES[@]}"

echo "==> typecheck 通过（0 error）"
