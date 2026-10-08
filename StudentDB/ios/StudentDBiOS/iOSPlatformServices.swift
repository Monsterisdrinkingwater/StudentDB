import UIKit
import SwiftUI
import QuickLook

// MARK: - iOS 平台服务实现
//
// 数据层（ProjectStore / AppModel）只面向 PlatformServices 协议
// （Sources/StudentDB/Store/PlatformServices.swift:12），
// macOS 由 MacPlatformServices 提供，iOS 由本结构体注入。
// 注入点：ProjectStore.init(platform:)（ProjectStore.swift:34）。

@MainActor
struct IOSPlatformServices: PlatformServices {

    // MARK: 系统能力

    /// 用系统默认方式打开文件：iOS 上用 QuickLook 预览。
    /// （macOS 侧对应 NSWorkspace.shared.open，见 PlatformServices.swift:38）
    func openFile(_ url: URL) {
        // QuickLook 预览器需要视图层级呈现；这里从当前场景栈找到最上层控制器直接 present，
        // 不依赖调用方传入呈现上下文。SwiftUI 场景里也可用下方的 QuickLookPreview 包装。
        guard let topViewController = Self.topMostViewController() else { return }
        let preview = UIHostingController(rootView: QuickLookPreview(urls: [url]))
        topViewController.present(UINavigationController(rootViewController: preview), animated: true)
    }

    /// 在访达/文件 App 中显示文件：iOS 无「定位到文件」的系统能力，no-op。
    func revealFile(_ url: URL) {
        // iOS 不支持（macOS: activateFileViewerSelecting）
    }

    /// 删除文件：iOS 无废纸篓，直接删除。
    /// （macOS 侧是 trashItem 移入废纸篓，见 PlatformServices.swift:46）
    func deleteFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 轻量提示：数据层在校验失败时调用（如 ProjectStore.swift:223）。
    /// macOS 蜂鸣，iOS 用警告触感反馈。
    func alertBeep() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: 文件面板类能力

    // iOS 由界面层 fileImporter 承担，界面层直接用 fileImporter 不走协议
    func promptOpenProject() -> URL? { nil }

    // iOS 由界面层 fileImporter 承担，界面层直接用 fileImporter 不走协议
    func promptImportFile() -> URL? { nil }

    // iOS 由界面层 fileImporter 承担，界面层直接用 fileImporter 不走协议
    func promptSaveFile(defaultName: String, pathExtension: String) -> URL? { nil }

    // iOS 由界面层 fileImporter 承担，界面层直接用 fileImporter 不走协议
    func promptAddAttachments() -> [URL] { [] }

    // MARK: - 辅助

    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              var top = scene.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - QuickLook 预览（SwiftUI 包装）

/// 用 SwiftUI 呈现 QuickLook 预览：
/// `QuickLookPreview(urls: [...])` 放进 sheet / fullScreenCover 即可。
struct QuickLookPreview: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.urls = urls
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var urls: [URL]
        init(urls: [URL]) { self.urls = urls }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            urls.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            // NSURL 桥接 conforms to QLPreviewItem
            urls[index] as NSURL
        }
    }
}
