import SwiftUI
import UniformTypeIdentifiers

// MARK: - 项目列表页（未打开项目时的首页）
//
// 项目来源：
// 1. Documents 根目录（本应用「新建项目」落点；UIFileSharingEnabled 后访达可见）
// 2. Documents/Inbox（其他 App 通过「用本应用打开/拷贝到此」投递的文件落点）
// 3. iCloud Drive 的 ubiquity 容器 Documents（配置 iCloud Documents 能力后才有）

struct ProjectListView: View {
    @EnvironmentObject private var appModel: AppModel

    /// 扫描到的项目包（已按名称排序、去重）
    @State private var projects: [URL] = []
    /// iCloud 容器是否可用（不可用时隐藏 iCloud 分组说明）
    @State private var iCloudAvailable = false

    @State private var showFileImporter = false
    @State private var showNewProjectSheet = false

    /// 通过 fileImporter 选中的外部文件需要持有安全作用域，项目打开期间不能释放
    @State private var scopedURL: URL?

    var body: some View {
        NavigationStack {
            List {
                if projects.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("还没有项目")
                            .font(.headline)
                        Text("新建一个项目，或打开已有的 .studentproj 文件")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowSeparator(.hidden)
                } else {
                    Section("项目") {
                        ForEach(projects, id: \.standardizedFileURL) { url in
                            projectRow(url)
                        }
                    }
                }

                Section {
                    Button {
                        showNewProjectSheet = true
                    } label: {
                        Label("新建项目", systemImage: "plus.square.dashed")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("浏览文件…", systemImage: "folder")
                    }
                } footer: {
                    if !iCloudAvailable {
                        Text("未配置 iCloud：只显示本机 Documents 与收件箱里的项目")
                    }
                }
            }
            .navigationTitle("学生信息管理系统")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewProjectSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建项目")
                }
            }
        }
        .onAppear(perform: refreshProjects)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [AppModel.projectType],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet { name in
                createNewProject(named: name)
            }
        }
        // 数据层也可能通过 appModel.alert 报告错误（如打开项目失败），统一弹出
        .alert(appModel.alert?.title ?? "",
               isPresented: Binding(
                   get: { appModel.alert != nil },
                   set: { if !$0 { appModel.alert = nil } }
               ),
               presenting: appModel.alert) { _ in
            Button("好", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: - 行视图

    @ViewBuilder
    private func projectRow(_ url: URL) -> some View {
        HStack {
            Image(systemName: "archivebox")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(url))
                    .font(.body.weight(.medium))
                Text(locationLabel(url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开") {
                open(url)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    private func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func locationLabel(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.contains("/com~apple~CloudDocs/") { return "iCloud Drive" }
        if path.contains("/Inbox/") { return "收件箱（其他应用传入）" }
        return "本机 Documents"
    }

    // MARK: - 动作

    private func open(_ url: URL) {
        Task { @MainActor in
            appModel.openProject(at: url)
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        // Documents/Inbox、iCloud 内的文件无需安全作用域；外部文件需要。
        // 打开项目后数据层会持续读写该包（自动保存/备份），因此作用域持有到
        // 下一次选择替换为止（view 销毁时系统自动回收）。
        if let old = scopedURL {
            old.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }
        open(url)
    }

    private func createNewProject(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // 项目包落在 Documents 根目录（与列表扫描的来源 1 一致，建完即可见）
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var target = documents.appendingPathComponent(name)
            .appendingPathExtension(AppModel.projectFileExtension)
        // 同名冲突：追加序号，避免静默覆盖已有项目
        var index = 2
        let baseName = name
        while FileManager.default.fileExists(atPath: target.path) {
            target = documents.appendingPathComponent("\(baseName) \(index)")
                .appendingPathExtension(AppModel.projectFileExtension)
            index += 1
        }
        Task { @MainActor in
            appModel.createProject(at: target)
        }
    }

    // MARK: - 扫描

    private func refreshProjects() {
        // 在 MainActor 上取好常量，供后台扫描线程使用
        let fileExtension = AppModel.projectFileExtension
        // url(forUbiquityContainerIdentifier:) 首次调用可能耗时，放到后台线程扫描
        Task.detached(priority: .userInitiated) {
            let found = Self.scanAllProjects(fileExtension: fileExtension)
            let hasICloud = Self.ubiquityContainerDocuments() != nil
            await MainActor.run {
                projects = found
                iCloudAvailable = hasICloud
            }
        }
    }

    /// iCloud Drive 容器的 Documents 目录（未配置 iCloud 能力时返回 nil）
    /// nonisolated：扫描在后台线程执行（View 类型成员默认推断为 @MainActor）
    private nonisolated static func ubiquityContainerDocuments() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    private nonisolated static func scanAllProjects(fileExtension: String) -> [URL] {
        var roots: [URL] = []
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        roots.append(documents)                                   // 1. Documents 根（新建项目落点）
        roots.append(documents.appendingPathComponent("Inbox"))   // 2. 收件箱
        if let iCloud = ubiquityContainerDocuments() {            // 3. iCloud Drive（若有）
            roots.append(iCloud)
        }

        var seen = Set<String>()
        var found: [URL] = []
        let fm = FileManager.default
        for root in roots {
            let items = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in items where item.pathExtension.lowercased() == fileExtension {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }   // .studentproj 是目录包
                let key = item.standardizedFileURL.path
                if seen.insert(key).inserted {
                    found.append(item)
                }
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - 新建项目（名称输入 sheet）

private struct NewProjectSheet: View {
    /// 返回项目名称（已由调用方负责落盘与改名冲突）
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("项目名称", text: $name)
                        .focused($focused)
                        .onSubmit(submit)
                } footer: {
                    Text("项目会以 .studentproj 文件包的形式保存在「文件」App 的本应用 Documents 目录下。")
                }
            }
            .navigationTitle("新建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建", action: submit)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName)
        dismiss()
    }
}

// 主界面（MainTabView）已由独立文件 MainTabView.swift 提供
// （学生 / 数据表 / 设置 三个页签），此处的占位实现已删除。
