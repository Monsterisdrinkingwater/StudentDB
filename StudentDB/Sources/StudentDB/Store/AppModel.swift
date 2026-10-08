import Foundation
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 应用级状态：当前项目、最近项目、密码锁、空闲自动锁定。
@MainActor
final class AppModel: ObservableObject {

    static let shared = AppModel()

    static let projectFileExtension = "studentproj"
    static let recentKey = "recentProjects"
    static let autoLockMinutesKey = "autoLockMinutes"
    static let projectUTI = "com.monsterisdrinkingwater.studentdb.project"

    @Published var store: ProjectStore?
    @Published var isLocked: Bool
    @Published var recentProjects: [URL] = []
    @Published var alert: AppAlert?
    /// 菜单栏触发“导入学生”时递增，主窗口监听后打开选择文件并弹出导入界面
    @Published var importRequestToken = 0
    /// 菜单栏触发“导出数据”时递增，主窗口监听后弹出导出选择界面
    @Published var exportRequestToken = 0

    private var lastActivity = Date()
    private var idleTimer: Timer?

    private init() {
        isLocked = AppLock.isEnabled
        recentProjects = Self.loadRecents()
        startIdleMonitor()
    }

    var autoLockMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: Self.autoLockMinutesKey)
        return value > 0 ? value : 15
    }

    // MARK: - 打开 / 新建 / 关闭项目

    func openProject(at url: URL) {
        if let current = store, current.projectURL == url { return }
        // iOS 必须注入平台服务实现（ProjectStore.init 里 precondition），macOS 走默认 MacPlatformServices
        #if os(iOS)
        let newStore = ProjectStore(platform: IOSPlatformServices())
        #else
        let newStore = ProjectStore()
        #endif
        do {
            try newStore.openProject(at: url)
            store = newStore
            addRecent(url)
            if let notice = newStore.recoveryNotice {
                alert = AppAlert(title: "数据已恢复", message: notice)
            }
        } catch {
            alert = AppAlert(title: "打开项目失败", message: error.localizedDescription)
        }
    }

    func createProject(at url: URL) {
        #if os(iOS)
        let newStore = ProjectStore(platform: IOSPlatformServices())
        #else
        let newStore = ProjectStore()
        #endif
        let name = url.deletingPathExtension().lastPathComponent
        do {
            try newStore.createProject(at: url, name: name)
            store = newStore
            addRecent(url)
        } catch {
            alert = AppAlert(title: "新建项目失败", message: error.localizedDescription)
        }
    }

    func closeProject() {
        store?.closeProject()
        store = nil
    }

    func flushSave() {
        store?.flushSave()
    }

    // MARK: - 导入 / 导出

    func requestImport() {
        importRequestToken += 1
    }

    func requestExport() {
        exportRequestToken += 1
    }

    /// 按选择导出 Excel（students 为视图筛选后的学生，nil = 全部）
    func runExcelExport(selection: ExportSelection, students: [Student]? = nil) {
        #if os(macOS)
        guard let store, selection.includesAnything else { return }
        let panel = NSSavePanel()
        panel.title = "导出数据（Excel）"
        panel.message = "每个勾选的内容各为一个工作表"
        panel.nameFieldStringValue = "\(store.projectName)-数据导出.xlsx"
        if let xlsx = UTType(filenameExtension: "xlsx") {
            panel.allowedContentTypes = [xlsx]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ExcelExporter.exportAll(data: store.data, to: url, selection: selection, students: students)
            store.revealInFinder(url)
        } catch {
            alert = AppAlert(title: "导出失败", message: error.localizedDescription)
        }
        #else
        // iOS：无 NSSavePanel；导出由界面层（TableViewScreen 的分享面板 / fileExporter）承担，此处不响应
        #endif
    }

    /// 按选择导出学生总表 CSV（students 为视图筛选后的学生，nil = 全部）
    func runCSVExport(selection: ExportSelection, students: [Student]? = nil) {
        #if os(macOS)
        guard let store, selection.includeRoster else { return }
        let panel = NSSavePanel()
        panel.title = "导出学生总表（CSV）"
        panel.nameFieldStringValue = "\(store.projectName)-学生总表.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CSVExporter.write(data: store.data, to: url,
                                  selectedFieldIDs: selection.customFieldIDs,
                                  students: students,
                                  guardianSlots: selection.guardianSlots,
                                  builtinColumns: selection.builtinColumns)
            store.revealInFinder(url)
        } catch {
            alert = AppAlert(title: "导出失败", message: error.localizedDescription)
        }
        #else
        // iOS：无 NSSavePanel；导出由界面层承担，此处不响应
        #endif
    }

    /// 弹出文件选择框，返回选中的 Excel/CSV 文件（面板能力由平台服务提供）
    func promptImportFile() -> URL? {
        #if os(macOS)
        return MacPlatformServices().promptImportFile()
        #else
        // iOS：文件面板由界面层 fileImporter 承担，此处返回 nil
        return nil
        #endif
    }

    // MARK: - 文件面板

    static var projectType: UTType {
        UTType(filenameExtension: Self.projectFileExtension, conformingTo: .package)
            ?? UTType(filenameExtension: Self.projectFileExtension)
            ?? .folder
    }

    func promptOpenProject() {
        // Mac: NSOpenPanel 选 .studentproj；iOS: 文件 App/文档浏览器入口替代
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "打开学生信息项目"
        panel.message = "选择一个 .studentproj 项目文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if url.pathExtension.lowercased() == Self.projectFileExtension || url.hasDirectoryPath {
                openProject(at: url)
            }
        }
        #endif
    }

    func promptNewProject() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "新建学生信息项目"
        panel.message = "选择项目保存位置（将创建一个独立的项目文件）"
        panel.nameFieldStringValue = "我的学生库"
        panel.allowedContentTypes = [Self.projectType]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createProject(at: url)
        #endif
    }

    // MARK: - 最近项目

    private static func loadRecents() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addRecent(_ url: URL) {
        var recents = recentProjects.filter { $0.standardizedFileURL != url.standardizedFileURL }
        recents.insert(url, at: 0)
        if recents.count > 8 { recents = Array(recents.prefix(8)) }
        recentProjects = recents
        UserDefaults.standard.set(recents.map { $0.path }, forKey: Self.recentKey)
    }

    /// 从最近项目列表移除一条（只移除记录，不删除磁盘上的项目文件）
    func removeRecentProject(_ url: URL) {
        let recents = recentProjects.filter { $0.standardizedFileURL != url.standardizedFileURL }
        recentProjects = recents
        UserDefaults.standard.set(recents.map { $0.path }, forKey: Self.recentKey)
    }

    // MARK: - 空闲自动锁定

    private func startIdleMonitor() {
        #if os(macOS)
        NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }
        #else
        // iOS：无本地事件流，锁屏检查定时器仍保留（lastActivity 由前台切换/交互刷新）
        #endif
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIdleLock()
            }
        }
    }

    private func checkIdleLock() {
        guard !isLocked, AppLock.isEnabled else { return }
        let minutes = autoLockMinutes
        guard minutes > 0 else { return }
        let idleMinutes = Date().timeIntervalSince(lastActivity) / 60
        if idleMinutes >= Double(minutes) {
            lockNow()
        }
    }

    func lockNow() {
        guard AppLock.isEnabled else { return }
        lastActivity = Date()
        isLocked = true
    }

    func unlock(withPassword password: String) -> Bool {
        if AppLock.verify(password: password) {
            lastActivity = Date()
            isLocked = false
            return true
        }
        return false
    }
}
