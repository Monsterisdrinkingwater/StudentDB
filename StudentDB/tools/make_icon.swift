// 生成应用图标：蓝色渐变圆角方块 + 白色“学生名册卡片”（头像列 + 信息行）→ AppIcon.icns
// 设计：渐变底（左上亮蓝 → 右下深蓝）+ 顶部柔光；卡片为班级名册——
// 每行一个头像圆点（首行高亮蓝）+ 一条信息栏，寓意“学生信息一行一档”。
// 用法: swift tools/make_icon.swift <输出路径 AppIcon.icns>

import AppKit

let outputArg = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon.icns"

let canvas = 1024.0

func drawIcon(scale size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let k = size / canvas   // 所有几何按 1024 画布定义，按比例缩放

    // macOS 图标规范：约 82% 内容区域，大圆角
    let content = NSRect(x: 93 * k, y: 93 * k, width: 838 * k, height: 838 * k)
    let radius = content.width * 0.225

    // 1) 底色：左上亮蓝 → 右下深蓝
    let bgPath = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)
    bgPath.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.46, green: 0.65, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.97, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.80, alpha: 1),
    ])?.draw(in: content, angle: -45)

    // 2) 顶部柔光（白色低透明度，往上渐隐）
    let glow = NSGradient(colors: [
        NSColor(calibratedWhite: 1, alpha: 0.22),
        NSColor(calibratedWhite: 1, alpha: 0.0),
    ])
    let glowRect = NSRect(x: content.minX, y: content.midY, width: content.width, height: content.height / 2)
    glow?.draw(in: glowRect, angle: 90)

    // 3) 名册卡片（白色圆角矩形）
    let card = NSRect(x: 292 * k, y: 232 * k, width: 440 * k, height: 580 * k)
    let cardRadius = 64 * k
    NSColor.white.setFill()
    NSBezierPath(roundedRect: card, xRadius: cardRadius, yRadius: cardRadius).fill()

    // 4) 三行学生记录：头像圆 + 信息栏
    let lightGray = NSColor(calibratedRed: 0.83, green: 0.87, blue: 0.94, alpha: 1)
    let accent = NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.98, alpha: 1)
    let avatarCx = card.minX + 84 * k
    let barX = avatarCx + 36 * k + 30 * k
    let rowCentersY: [CGFloat] = [card.maxY - 108 * k, card.midY - 10 * k, card.minY + 106 * k]
    let barWidths: [CGFloat] = [228 * k, 186 * k, 208 * k]

    for (index, cy) in rowCentersY.enumerated() {
        // 头像
        let avatarRect = NSRect(x: avatarCx - 36 * k, y: cy - 36 * k, width: 72 * k, height: 72 * k)
        (index == 0 ? accent : lightGray).setFill()
        NSBezierPath(ovalIn: avatarRect).fill()
        // 信息栏
        let bar = NSRect(x: barX, y: cy - 17 * k, width: barWidths[index], height: 34 * k)
        lightGray.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 17 * k, yRadius: 17 * k).fill()
    }

    // 5) 首行头像内加白色“学”点睛（延续前代图标的字样）
    let markFont = NSFont.systemFont(ofSize: 46 * k, weight: .bold)
    let mark = NSAttributedString(string: "学", attributes: [
        .font: markFont,
        .foregroundColor: NSColor.white,
    ])
    let markSize = mark.size()
    mark.draw(at: NSPoint(
        x: avatarCx - markSize.width / 2,
        y: rowCentersY[0] - markSize.height / 2 - 3 * k
    ))

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, size: CGFloat, to url: URL) throws {
    let scaled = NSImage(size: NSSize(width: size, height: size))
    scaled.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    scaled.unlockFocus()

    guard let tiff = scaled.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MakeIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败 (\(size))"])
    }
    try png.write(to: url)
}

let fm = FileManager.default
let workDir = fm.temporaryDirectory.appendingPathComponent("StudentDBIcon-\(UUID().uuidString)")
let iconset = workDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let base = drawIcon(scale: canvas)
let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, px) in sizes {
    try writePNG(base, size: px, to: iconset.appendingPathComponent(name))
}

let outputURL = URL(fileURLWithPath: outputArg)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed".data(using: .utf8)!)
    exit(1)
}
try? fm.removeItem(at: workDir)
print("Icon written to \(outputURL.path)")
