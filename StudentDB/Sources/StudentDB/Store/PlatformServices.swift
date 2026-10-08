import Foundation

// MARK: - 平台服务抽象（数据层跨平台共用）
//
// ProjectStore 及导入导出需要的"系统能力"集中在此协议：
// - macOS 实现走 AppKit（访达打开/废纸篓/蜂鸣），行为与既有版本完全一致
// - iOS 实现走 QuickLook/直接删除/触感反馈
// 数据层代码只面向协议，保证 Mac 与 iOS 用同一份存储逻辑。

/// 平台系统能力注入点
@MainActor
protocol PlatformServices {
    /// 用系统默认方式打开文件（macOS: NSWorkspace.open；iOS: QuickLook 预览）
    func openFile(_ url: URL)
    /// 在访达/Fiiles 中显示文件（macOS: activateFileViewerSelecting；iOS: 无对应，no-op）
    func revealFile(_ url: URL)
    /// 删除文件（macOS: 移入废纸篓；iOS: 直接删除）
    func deleteFile(_ url: URL)
    /// 轻量提示音/触感（macOS: NSSound.beep；iOS: 触感反馈）
    func alertBeep()
    /// 打开项目选择面板，返回选中的 .studentproj 目录（取消返回 nil）
    func promptOpenProject() -> URL?
    /// 打开导入文件选择面板（xlsx/csv），返回选中文件（取消返回 nil）
    func promptImportFile() -> URL?
    /// 导出文件保存面板（给定默认文件名），返回保存目标（取消返回 nil）
    func promptSaveFile(defaultName: String, pathExtension: String) -> URL?
    /// 添加附件面板（允许多选），返回选中文件（取消返回空数组）
    func promptAddAttachments() -> [URL]
}

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// macOS 实现：复用既有 AppKit 行为
@MainActor
struct MacPlatformServices: PlatformServices {
    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealFile(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deleteFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func alertBeep() {
        NSSound.beep()
    }

    func promptOpenProject() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "打开项目"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func promptImportFile() -> URL? {
        let xlsx = UTType(filenameExtension: "xlsx") ?? .data
        let panel = NSOpenPanel()
        panel.title = "选择要导入的名单文件"
        panel.message = "支持 .xlsx（Excel 工作簿）和 .csv 文件，第一行应为列标题"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [xlsx, .commaSeparatedText]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func promptSaveFile(defaultName: String, pathExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出"
        panel.nameFieldStringValue = defaultName
        if let type = UTType(filenameExtension: pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func promptAddAttachments() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选中的文件会复制进项目包，随项目一起保存"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
#endif
