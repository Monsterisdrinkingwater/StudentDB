import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 应用入口

@main
struct StudentDBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared

    var body: some Scene {
        WindowGroup("学生信息管理系统") {
            MainWindow()
                .environmentObject(appModel)
                .frame(minWidth: 940, minHeight: 600)
        }
        .defaultSize(width: 1150, height: 740)
        .commands {
            AppCommands(appModel: appModel)
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .frame(width: 460)
        }
    }
}

// MARK: - 委托：处理双击 .studentproj 打开、退出前保存

final class AppDelegate: NSObject, NSApplicationDelegate {

    func application(_ application: NSApplication, open urls: [URL]) {
        let projectURLs = urls.filter {
            $0.pathExtension.lowercased() == AppModel.projectFileExtension
        }
        guard !projectURLs.isEmpty else { return }
        Task { @MainActor in
            for url in projectURLs {
                AppModel.shared.openProject(at: url)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            AppModel.shared.flushSave()
            return .terminateNow
        }
    }
}

// MARK: - 菜单命令

struct AppCommands: Commands {
    @ObservedObject var appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建项目…") {
                appModel.promptNewProject()
            }
            .keyboardShortcut("n")

            Button("打开项目…") {
                appModel.promptOpenProject()
            }
            .keyboardShortcut("o")

            Divider()

            Menu("打开最近项目") {
                if appModel.recentProjects.isEmpty {
                    Text("暂无最近项目").foregroundStyle(.secondary)
                }
                ForEach(appModel.recentProjects, id: \.absoluteString) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        appModel.openProject(at: url)
                    }
                }
                if !appModel.recentProjects.isEmpty {
                    Divider()
                    Button("清除最近项目") {
                        appModel.recentProjects = []
                        UserDefaults.standard.removeObject(forKey: AppModel.recentKey)
                    }
                }
            }
            .disabled(appModel.recentProjects.isEmpty)

            if appModel.store != nil {
                Divider()
                Button("关闭项目") {
                    appModel.closeProject()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("立即保存") {
                appModel.flushSave()
            }
            .keyboardShortcut("s")

            Button("立即备份") {
                do {
                    try appModel.store?.backupNow()
                } catch {
                    appModel.alert = AppAlert(title: "备份失败", message: error.localizedDescription)
                }
            }
            .disabled(appModel.store == nil)

            Button("导出学生总表 CSV…") {
                exportCSV()
            }
            .keyboardShortcut("e")
            .disabled(appModel.store == nil || appModel.store?.data.students.isEmpty != false)

            Button("导出数据（选择内容）…") {
                appModel.requestExport()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(appModel.store == nil || appModel.store?.data.students.isEmpty != false)

            Button("导出数据库（SQLite）…") {
                exportSQLite()
            }
            .disabled(appModel.store == nil)

            Button("从 Excel / CSV 导入学生…") {
                appModel.requestImport()
            }
            .keyboardShortcut("i")
            .disabled(appModel.store == nil)
        }

        CommandGroup(replacing: .help) {
            Button("使用说明") {
                openReadme()
            }
        }
    }

    private func exportCSV() {
        guard let store = appModel.store else { return }
        let panel = NSSavePanel()
        panel.title = "导出学生总表"
        panel.nameFieldStringValue = "\(store.projectName)-学生总表.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CSVExporter.write(data: store.data, to: url)
            store.revealInFinder(url)
        } catch {
            appModel.alert = AppAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    /// 导出为单个 SQLite 数据库文件（学生总表 + 全部数据表，可用任何数据库工具打开）
    private func exportSQLite() {
        guard let store = appModel.store else { return }
        let panel = NSSavePanel()
        panel.title = "导出数据库（SQLite）"
        panel.nameFieldStringValue = "\(store.projectName).sqlite"
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SQLiteExporter.export(data: store.data, to: url)
            store.revealInFinder(url)
        } catch {
            appModel.alert = AppAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func openReadme() {
        let readme = Bundle.main.resourceURL?
            .appendingPathComponent("README.md")
        if let readme, FileManager.default.fileExists(atPath: readme.path) {
            NSWorkspace.shared.open(readme)
        }
    }
}
