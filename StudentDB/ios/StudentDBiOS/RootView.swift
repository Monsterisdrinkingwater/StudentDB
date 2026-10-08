import SwiftUI

// MARK: - iOS 根视图：按 appModel 状态分流

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Group {
            if appModel.isLocked {
                // 共享锁屏视图。注意：LockScreenView 的签名是通过 @EnvironmentObject
                // 取 AppModel（Sources/StudentDB/Views/LockScreenView.swift:5），
                // 不接受构造参数，因此这里只负责把 appModel 注入环境。
                LockScreenView()
            } else if appModel.store == nil {
                // 未打开任何项目：项目列表（选择 / 新建 / 浏览文件）
                ProjectListView()
            } else {
                // 已打开项目：主界面（占位实现见 ProjectListView.swift 底部，
                // 由主界面模块后续替换为正式实现）
                MainTabView()
            }
        }
        // appModel 已在 StudentDBiOSApp 顶层注入环境，此处无需重复
    }
}
