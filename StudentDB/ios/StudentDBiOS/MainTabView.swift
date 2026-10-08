import SwiftUI

// MARK: - iOS 应用主界面

/// 底部标签页：学生 / 数据表 / 设置。
///
/// 使用前提：应用根视图需注入 `AppModel` 环境对象
/// （`.environmentObject(AppModel.shared)`），数据表与设置页从其中读取当前项目。
///
/// 「学生」页为 2 号模块的 StudentListView 占位引用——该模块集成进同一 target
/// 后此页生效；本文件不提供学生列表的任何实现。
struct MainTabView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView {
            // 学生（2 号模块占位引用）
            StudentListView()
                .tabItem {
                    Label("学生", systemImage: "person.3.fill")
                }

            // 数据表（本模块）：TableViewList 自带 NavigationStack
            TableViewList()
                .tabItem {
                    Label("数据表", systemImage: "tablecells.fill")
                }

            // 设置（本模块）
            NavigationStack {
                IOSSettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
        }
    }
}
