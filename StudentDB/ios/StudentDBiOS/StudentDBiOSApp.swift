import SwiftUI

// MARK: - iOS 应用入口
//
// 与 macOS 入口（Sources/StudentDB/App/StudentDBApp.swift）平行：
// - macOS 入口使用 @NSApplicationDelegateAdaptor + AppKit，不能进 iOS 目标
// - 本文件是 iOS 目标唯一的 @main

@main
struct StudentDBiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .onOpenURL { url in
                    // 处理从「文件」App / AirDrop / 邮件以本应用打开 .studentproj 包
                    // （对应 macOS 侧 AppDelegate 的 application(_:open:)）
                    guard url.pathExtension.lowercased() == AppModel.projectFileExtension else { return }
                    Task { @MainActor in
                        appModel.openProject(at: url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS 随时可能被挂起或杀掉：退到后台立即落盘，避免丢数据
            if phase == .background {
                appModel.flushSave()
            }
        }
    }
}
