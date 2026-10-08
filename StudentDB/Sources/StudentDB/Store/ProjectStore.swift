import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - 错误与辅助类型

enum ProjectError: LocalizedError {
    case cannotOpen(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let reason):
            return "无法打开项目：\(reason)"
        }
    }
}

struct BackupInfo: Identifiable {
    let url: URL
    let modifiedAt: Date
    let size: Int

    var id: String { url.lastPathComponent }
    var displayName: String { url.lastPathComponent }
}

/// 一个“项目”= 一个 .studentproj 文件夹包，包含 students.json、attachments/ 与 backups/。
/// 所有写入均为原子写入；保存前自动做时间节流的备份；打开时若数据损坏自动回退最近备份。
@MainActor
final class ProjectStore: ObservableObject {

    /// 平台服务（访达打开/废纸篓/面板）；默认 macOS 实现，iOS 侧注入对应实现
    let platform: PlatformServices

    init(platform: PlatformServices? = nil) {
        #if os(macOS)
        self.platform = platform ?? MacPlatformServices()
        #else
        precondition(platform != nil, "iOS 上必须注入 PlatformServices 实现")
        self.platform = platform!
        #endif
    }

    // MARK: - 状态

    @Published private(set) var data = ProjectData()
    /// 供包内 extensions（ProjectStoreTables 等）批量改写数据
    func mutateData(_ change: (inout ProjectData) -> Void) {
        change(&data)
    }
    @Published private(set) var projectURL: URL?
    @Published private(set) var lastSavedAt: Date?
    /// 打开项目时若发生过自动恢复，则给出提示文案
    @Published private(set) var recoveryNotice: String?

    private var isDirty = false
    private var saveTask: Task<Void, Never>?
    private var lastAutoBackupAt: Date?

    static let dataFileName = "students.json"
    static let backupFolderName = "backups"
    static let attachmentsFolderName = "attachments"
    static let maxBackups = 10
    /// 自动备份的最小间隔
    static let autoBackupInterval: TimeInterval = 5 * 60

    /// 日期统一存为“自 1970 起的毫秒整数”：JSON 中可读，且跨版本稳定
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let millis = try container.decode(Int64.self)
            return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        }
        return d
    }()

    var projectName: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    // MARK: - 路径

    var dataURL: URL? {
        projectURL?.appendingPathComponent(Self.dataFileName)
    }

    var backupsDirectory: URL? {
        projectURL?.appendingPathComponent(Self.backupFolderName, isDirectory: true)
    }

    var attachmentsRoot: URL? {
        projectURL?.appendingPathComponent(Self.attachmentsFolderName, isDirectory: true)
    }

    func studentFilesDirectory(_ studentID: UUID) -> URL? {
        guard let root = attachmentsRoot else { return nil }
        return root.appendingPathComponent(studentID.uuidString, isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
    }

    func recordFilesDirectory(studentID: UUID, recordID: UUID) -> URL? {
        guard let root = attachmentsRoot else { return nil }
        return root.appendingPathComponent(studentID.uuidString, isDirectory: true)
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent(recordID.uuidString, isDirectory: true)
    }

    // MARK: - 新建 / 打开 / 关闭

    func createProject(at url: URL, name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        data = ProjectData()
        data.tables = DBTable.defaultRecordTables()
        data.recordMigrationDone = true
        projectURL = url
        isDirty = false
        lastAutoBackupAt = nil
        recoveryNotice = nil
        try writeProjectInfo(name: name)
        try saveNow()
    }

    func openProject(at url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectError.cannotOpen("找不到项目文件夹。")
        }

        projectURL = url

        let dataURL = url.appendingPathComponent(Self.dataFileName)
        var loaded: ProjectData?
        var notice: String?

        if let raw = try? Data(contentsOf: dataURL) {
            loaded = try? Self.decoder.decode(ProjectData.self, from: raw)
        }

        if loaded == nil {
            for backup in listBackups() {
                if let raw = try? Data(contentsOf: backup.url),
                   let decoded = try? Self.decoder.decode(ProjectData.self, from: raw) {
                    loaded = decoded
                    notice = "数据文件损坏或丢失，已自动恢复到最近备份「\(backup.displayName)」。"
                    break
                }
            }
        }

        guard let loaded else {
            projectURL = nil
            throw ProjectError.cannotOpen("students.json 损坏，且没有可用的备份。")
        }

        data = loaded
        isDirty = false
        lastAutoBackupAt = nil
        recoveryNotice = notice
        if notice != nil {
            try? saveNow() // 把修复后的数据立即写回
        }
        migrateRecordsIfNeeded()
        collapseToSingleViewsIfNeeded()
        mergeMissingDefaultCreditRules()
    }

    /// 单视图语义（多视图功能移除后的一次性收敛，参照 migrateRecordsIfNeeded 的写法）：
    /// 学生表与每张通用表的视图列表收敛为一个——保留 currentViewID 指向的（没有则第一个，
    /// 其排序 / 布局 / 列显隐等个性化设置随视图保留），其余视图丢弃；
    /// 筛选三项（keyword / condition / columnFilters）不持久化，加载后一律为空。
    private func collapseToSingleViewsIfNeeded() {
        func collapsed(_ views: inout [ListView], keeping currentID: UUID?) -> ListView? {
            guard !views.isEmpty else { return nil }
            var kept = views.first { $0.id == currentID } ?? views[0]
            kept.keyword = ""
            kept.condition = .all
            kept.columnFilters = [:]
            views = [kept]
            return kept
        }

        var changed = false
        mutateData { data in
            let viewsBefore = data.views
            if let kept = collapsed(&data.views, keeping: data.currentViewID) {
                if data.currentViewID != kept.id {
                    data.currentViewID = kept.id
                    changed = true
                }
                if viewsBefore.count > 1 { changed = true }
            }
            for tIdx in data.tables.indices {
                let before = data.tables[tIdx].views
                if let kept = collapsed(&data.tables[tIdx].views, keeping: data.tables[tIdx].currentViewID) {
                    if data.tables[tIdx].currentViewID != kept.id {
                        data.tables[tIdx].currentViewID = kept.id
                        changed = true
                    }
                    if before.count > 1 { changed = true }
                }
            }
        }
        if changed { try? saveNow() }
    }

    func closeProject() {
        flushSave()
        projectURL = nil
        data = ProjectData()
        lastSavedAt = nil
        recoveryNotice = nil
    }

    private func writeProjectInfo(name: String) throws {
        struct Info: Codable {
            var name: String
            var createdAt: Date
            var formatVersion: Int
        }
        guard let url = projectURL else { return }
        let info = Info(name: name, createdAt: Date(), formatVersion: 1)
        let raw = try PropertyListEncoder().encode(info)
        try raw.write(to: url.appendingPathComponent("ProjectInfo.plist"), options: .atomic)
    }

    // MARK: - 保存与备份

    /// 修改数据后调用：1 秒防抖自动保存
    func scheduleSave() {
        guard projectURL != nil else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNowForAutosave()
        }
    }

    /// 退出前同步保存
    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, projectURL != nil else { return }
        saveNowForAutosave()
    }

    private func saveNowForAutosave() {
        do {
            try saveNow()
        } catch {
            platform.alertBeep()
        }
    }

    /// 同步保存（自动备份按时间节流）
    func saveNow() throws {
        try saveNow(makeBackup: false)
    }

    func saveNow(makeBackup: Bool) throws {
        guard let url = projectURL, let dataURL else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        // 覆盖前对磁盘上的旧文件做快照
        if fm.fileExists(atPath: dataURL.path), shouldAutoBackup() {
            try backupExistingFile()
        }

        data.updatedAt = Date()
        let raw = try Self.encoder.encode(data)
        try raw.write(to: dataURL, options: [.atomic])
        isDirty = false
        lastSavedAt = Date()
    }

    private func shouldAutoBackup() -> Bool {
        guard let last = lastAutoBackupAt else { return true }
        return Date().timeIntervalSince(last) >= Self.autoBackupInterval
    }

    private func backupExistingFile() throws {
        guard let dataURL, let dir = backupsDirectory else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "students-\(Fmt.fileStamp.string(from: Date()))"
        var name = "\(base).json"
        var counter = 1
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base)-\(counter).json"
            counter += 1
        }
        try fm.copyItem(at: dataURL, to: dir.appendingPathComponent(name))
        lastAutoBackupAt = Date()
        pruneBackups()
    }

    /// 手动“立即备份”：先把当前数据写盘，再强制做一份快照
    func backupNow() throws {
        try saveNow()
        guard let dataURL else { return }
        try backupExistingFile()
    }

    func listBackups() -> [BackupInfo] {
        guard let dir = backupsDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { name -> BackupInfo? in
                let url = dir.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let date = values?.contentModificationDate else { return nil }
                return BackupInfo(url: url, modifiedAt: date, size: values?.fileSize ?? 0)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func pruneBackups() {
        let backups = listBackups()
        guard backups.count > Self.maxBackups else { return }
        for old in backups.suffix(backups.count - Self.maxBackups) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    /// 从备份恢复：恢复前先给当前数据强制做一次备份
    func restore(from backup: BackupInfo) throws {
        guard projectURL != nil else { return }
        // 先保住当前状态
        try saveNow()
        try backupExistingFile()

        let raw = try Data(contentsOf: backup.url)
        let decoded = try Self.decoder.decode(ProjectData.self, from: raw)
        data = decoded
        // 备份可能来自多视图旧版本：与 openProject 一致地收敛为单视图后再写回
        collapseToSingleViewsIfNeeded()
        try saveNow()
        recoveryNotice = "已恢复到备份「\(backup.displayName)」。"
    }

    // MARK: - 学生增删改

    func addStudent(_ student: Student) {
        var s = student
        s.createdAt = Date()
        s.updatedAt = Date()
        data.students.append(s)
        scheduleSave()
    }

    func updateStudent(_ student: Student) {
        guard let idx = data.students.firstIndex(where: { $0.id == student.id }) else { return }
        var s = student
        s.updatedAt = Date()
        data.students[idx] = s
        scheduleSave()
    }

    func deleteStudent(id: UUID) {
        guard let idx = data.students.firstIndex(where: { $0.id == id }) else { return }
        data.students.remove(at: idx)
        removeStudentLinks(studentID: id)
        scheduleSave()
        // 附件目录移入废纸篓（可在 Finder 恢复）
        if let dir = attachmentsRoot?.appendingPathComponent(id.uuidString, isDirectory: true) {
            trashItem(at: dir)
        }
    }

    func student(id: UUID) -> Student? {
        data.students.first { $0.id == id }
    }

    /// 批量删除学生（表内关联一并清理，附件移入废纸篓）
    func deleteStudents(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        data.students.removeAll { ids.contains($0.id) }
        for id in ids {
            removeStudentLinks(studentID: id)
        }
        scheduleSave()
        try? saveNow()
        for id in ids {
            if let dir = attachmentsRoot?.appendingPathComponent(id.uuidString, isDirectory: true) {
                trashItem(at: dir)
            }
        }
    }

    func isStudentNumberTaken(_ number: String, excluding: UUID? = nil) -> Bool {
        // 学号字段被软删除时不做唯一性校验
        guard !data.deletedBuiltinFields.contains(StudentTableField.studentNumber.rawValue) else { return false }
        let key = number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        return data.students.contains {
            $0.id != excluding
                && $0.studentNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
    }

    // MARK: - 关心关爱记录

    func addRecord(_ record: CareRecord, to studentID: UUID) {
        guard let idx = data.students.firstIndex(where: { $0.id == studentID }) else { return }
        data.students[idx].records.append(record)
        data.students[idx].updatedAt = Date()
        scheduleSave()
    }

    func updateRecord(_ record: CareRecord, studentID: UUID) {
        guard let sIdx = data.students.firstIndex(where: { $0.id == studentID }),
              let rIdx = data.students[sIdx].records.firstIndex(where: { $0.id == record.id }) else { return }
        data.students[sIdx].records[rIdx] = record
        data.students[sIdx].updatedAt = Date()
        scheduleSave()
    }

    func deleteRecord(id: UUID, studentID: UUID) {
        guard let sIdx = data.students.firstIndex(where: { $0.id == studentID }) else { return }
        data.students[sIdx].records.removeAll { $0.id == id }
        data.students[sIdx].updatedAt = Date()
        scheduleSave()
        if let dir = recordFilesDirectory(studentID: studentID, recordID: id) {
            trashItem(at: dir)
        }
    }

    // MARK: - 视图（隐式单视图：无切换/新建/删除）

    var currentView: ListView {
        data.views.first ?? ListView(name: "全部学生")
    }

    func updateView(_ view: ListView) {
        guard let idx = data.views.firstIndex(where: { $0.id == view.id }) else { return }
        data.views[idx] = view
        scheduleSave()
    }

    /// 清空所有视图的会话内筛选（关键字 / 快捷筛选条件 / 列筛选）。
    /// 筛选只在内存会话中生效：切换表后回来一律显示全部学生。
    func resetViewFilters() {
        mutateData { data in
            for vIdx in data.views.indices {
                data.views[vIdx].keyword = ""
                data.views[vIdx].condition = .all
                data.views[vIdx].columnFilters = [:]
            }
            for tIdx in data.tables.indices {
                for vIdx in data.tables[tIdx].views.indices {
                    data.tables[tIdx].views[vIdx].keyword = ""
                    data.tables[tIdx].views[vIdx].condition = .all
                    data.tables[tIdx].views[vIdx].columnFilters = [:]
                }
            }
        }
    }

    // MARK: - Excel 式列筛选

    /// 把内置列（电话/住宿/地址/派出所）转换成自定义字段并改类型：
    /// 值按新类型转换后迁入 customValues，内置列软删除（可在字段管理恢复，原值保留）。
    /// 姓名、学号为必备身份列，不支持转换。
    func convertBuiltinField(key: String, to newType: FieldType) {
        guard let field = StudentTableField(rawValue: key),
              !Self.protectedBuiltinFields.contains(key),
              field != .recordCount else { return }
        mutateData { data in
            // 原值快照（按 CustomValue 形态）
            var oldValues: [CustomValue] = []
            for s in data.students {
                switch field {
                case .boarding: oldValues.append(.boolean(s.isBoarding))
                case .phone: oldValues.append(.text(s.phone))
                case .boardingAddress: oldValues.append(.text(s.boardingAddress))
                case .policeStation: oldValues.append(.text(s.policeStation))
                default: return
                }
            }

            // 同名避让
            var name = field.title
            var suffix = 2
            while data.fieldDefinitions.contains(where: { $0.name == name }) {
                name = "\(field.title)(\(suffix))"; suffix += 1
            }
            var custom = CustomField(name: name, type: newType)
            custom.createdAt = Date()

            var distinctTexts: [String] = []
            for (idx, old) in oldValues.enumerated() {
                if let converted = convertCustomValue(old, to: newType,
                                                      nameOf: { _ in nil }, matchIDs: { _ in [] }) {
                    data.students[idx].customValues[custom.id.uuidString] = converted
                    if case .text(let t) = converted, !t.isEmpty { distinctTexts.append(t) }
                }
                data.students[idx].updatedAt = Date()
            }
            // 单选/多选：现有取值并入选项（多选拆顿号）
            switch newType {
            case .choice(let options):
                var merged = options
                for t in distinctTexts where !merged.contains(t) { merged.append(t) }
                custom.type = .choice(options: merged)
            case .multiChoice(let options):
                var merged = options
                for t in distinctTexts {
                    for part in TableImporter.splitMulti(t) where !merged.contains(part) { merged.append(part) }
                }
                custom.type = .multiChoice(options: merged)
            default:
                break
            }

            data.fieldDefinitions.append(custom)
            data.fieldOrder.append(custom.id)
            data.deletedBuiltinFields.insert(key)
            // 视图配置里旧列的痕迹清理（筛选/隐藏/布局）
            for vIdx in data.views.indices {
                data.views[vIdx].columnFilters.removeValue(forKey: key)
                data.views[vIdx].hiddenColumnIDs.remove(key)
            }
            data.columnLayout.removeAll { $0 == key }
        }
        scheduleSave()
    }

    /// 变更学生自定义字段类型：所有学生的该字段值同步转换（学生表不含关联学生/附件类型）
    func changeFieldType(fieldID: UUID, to newType: FieldType) {
        mutateData { data in
            guard let fIdx = data.fieldDefinitions.firstIndex(where: { $0.id == fieldID }),
                  !data.fieldDefinitions[fIdx].type.sameKind(as: newType) else { return }
            data.fieldDefinitions[fIdx].type = newType

            let key = fieldID.uuidString
            var distinctTexts: [String] = []
            for sIdx in data.students.indices {
                guard let old = data.students[sIdx].customValues.removeValue(forKey: key) else { continue }
                let converted = convertCustomValue(old, to: newType,
                                                   nameOf: { _ in nil },
                                                   matchIDs: { _ in [] })
                if let converted {
                    data.students[sIdx].customValues[key] = converted
                    if case .text(let t) = converted, !t.isEmpty { distinctTexts.append(t) }
                }
                data.students[sIdx].updatedAt = Date()
            }

            switch newType {
            case .choice(let options):
                var merged = options
                for t in distinctTexts where !t.isEmpty && !merged.contains(t) { merged.append(t) }
                data.fieldDefinitions[fIdx].type = .choice(options: merged)
            case .multiChoice(let options):
                var merged = options
                for t in distinctTexts {
                    for part in TableImporter.splitMulti(t) where !merged.contains(part) { merged.append(part) }
                }
                data.fieldDefinitions[fIdx].type = .multiChoice(options: merged)
            default:
                break
            }
        }
        scheduleSave()
    }

    /// 向下拉/多选字段追加选项（导入遇到新值时自动补充词条）
    func appendChoiceOptions(fieldID: UUID, options: [String]) {
        guard let idx = data.fieldDefinitions.firstIndex(where: { $0.id == fieldID }) else { return }
        var field = data.fieldDefinitions[idx]
        var current: [String]
        switch field.type {
        case .choice(let list): current = list
        case .multiChoice(let list): current = list
        default: return
        }
        var added = false
        for option in options where !option.isEmpty && !current.contains(option) {
            current.append(option)
            added = true
        }
        guard added else { return }
        switch field.type {
        case .choice: field.type = .choice(options: current)
        case .multiChoice: field.type = .multiChoice(options: current)
        default: break
        }
        data.fieldDefinitions[idx] = field
        scheduleSave()
    }

    /// 设置/清除某列的筛选（nil 或不活跃 = 清除）
    func setColumnFilter(columnID: String, filter: ColumnFilter?) {
        var v = currentView
        if let filter, filter.isActive {
            v.columnFilters[columnID] = filter
        } else {
            v.columnFilters.removeValue(forKey: columnID)
        }
        updateView(v)
    }

    /// 清除当前视图的全部列筛选（会话内状态）
    func clearColumnFilters() {
        var v = currentView
        guard !v.columnFilters.isEmpty else { return }
        v.columnFilters.removeAll()
        updateView(v)
    }

    // MARK: - 字段顺序与内置字段软删除

    /// 统一列布局（表格列拖拽 / 详情行拖拽 / 调序按钮共用）
    /// 返回当前全部可见列的默认顺序（内置→监护人→自定义），作为布局基准
    func currentColumnLayout() -> [String] {
        StudentColumnSpec.allColumns(
            fields: data.orderedFields,
            guardianSlots: currentView.guardianColumnCount,
            builtinOrder: data.builtinOrder,
            deletedBuiltin: data.deletedBuiltinFields
        ).map { $0.id }
    }

    /// 整体替换统一布局（表格列拖拽结束后一次性写回）
    func setColumnLayout(_ ids: [String]) {
        data.columnLayout = ids
        scheduleSave()
    }

    /// 上移/下移一列（调序按钮）；自定义字段与内置字段统一处理
    func moveColumn(id: String, offset: Int) {
        let layout = data.columnLayout.isEmpty ? currentColumnLayout() : data.columnLayout
        guard let idx = layout.firstIndex(of: id) else { return }
        let target = idx + offset
        guard layout.indices.contains(target) else { return }
        var newLayout = layout
        newLayout.swapAt(idx, target)
        setColumnLayout(newLayout)
    }

    /// 兼容旧入口：自定义字段调序（写入统一布局）
    func moveField(id: UUID, offset: Int) {
        moveColumn(id: id.uuidString, offset: offset)
    }

    /// 兼容旧入口：内置字段调序（写入统一布局）
    func moveBuiltinField(key: String, offset: Int) {
        moveColumn(id: key, offset: offset)
    }

    /// 必备内置字段：不可删除（姓名、学号）
    static let protectedBuiltinFields: Set<String> = ["name", "studentNumber"]

    /// 软删除内置字段（界面隐藏，数据保留，可恢复）——仅用于姓名/学号以外的场景已废弃，保留兼容
    func softDeleteBuiltinField(key: String) {
        // 至少保留一列可见
        let visibleCount = StudentColumnSpec.columns(
            fields: data.orderedFields,
            hidden: currentView.hiddenColumnIDs,
            guardianSlots: currentView.guardianColumnCount,
            builtinOrder: data.builtinOrder,
            deletedBuiltin: data.deletedBuiltinFields
        ).count
        guard visibleCount > 1 else {
            platform.alertBeep()
            return
        }
        data.deletedBuiltinFields.insert(key)
        data.columnLayout.removeAll { $0 == key }
        scheduleSave()
    }

    /// 真删除内置字段（姓名、学号不可删）：从界面移除并清空所有学生的该字段数据
    func hardDeleteBuiltinField(key: String) {
        guard !Self.protectedBuiltinFields.contains(key) else { return }
        guard data.deletedBuiltinFields.contains(key) == false else { return }
        softDeleteBuiltinField(key: key)
        // 清空数据
        for index in data.students.indices {
            switch key {
            case "boarding": data.students[index].isBoarding = false
            case "phone": data.students[index].phone = ""
            case "boardingAddress": data.students[index].boardingAddress = ""
            case "policeStation": data.students[index].policeStation = ""
            default: break // recordCount 为派生列，无数据
            }
        }
        scheduleSave()
    }

    func restoreBuiltinField(key: String) {
        data.deletedBuiltinFields.remove(key)
        scheduleSave()
    }

    // MARK: - 快捷筛选标签

    func addQuickFilter(_ filter: QuickFilter) {
        guard !data.quickFilters.contains(where: { $0.name == filter.name }) else { return }
        data.quickFilters.append(filter)
        scheduleSave()
    }

    func deleteQuickFilter(id: UUID) {
        data.quickFilters.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - 自定义字段

    func addField(name: String, type: FieldType) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var field = CustomField(name: trimmed, type: type)
        field.createdAt = Date()
        data.fieldDefinitions.append(field)
        data.fieldOrder.append(field.id)
        scheduleSave()
    }

    func updateField(_ field: CustomField) {
        guard let idx = data.fieldDefinitions.firstIndex(where: { $0.id == field.id }) else { return }
        data.fieldDefinitions[idx] = field
        scheduleSave()
    }

    /// 删除字段并清除所有学生身上该字段的值，同时清理引用它的快捷筛选标签
    func deleteField(id: UUID) {
        data.fieldDefinitions.removeAll { $0.id == id }
        data.fieldOrder.removeAll { $0 == id }
        data.columnLayout.removeAll { $0 == id.uuidString }
        for sIdx in data.students.indices {
            data.students[sIdx].customValues.removeValue(forKey: id.uuidString)
        }
        data.quickFilters.removeAll {
            if case .customField(let fieldID, _) = $0.condition { return fieldID == id }
            return false
        }
        scheduleSave()
    }

    // MARK: - 记录类型

    /// 整体替换记录类型（“恢复默认分类”用）
    func setRecordTypes(_ types: [String]) {
        data.recordTypes = types
        scheduleSave()
    }

    func addRecordType(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !data.recordTypes.contains(trimmed) else { return }
        data.recordTypes.append(trimmed)
        scheduleSave()
    }

    func updateRecordType(at index: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard data.recordTypes.indices.contains(index), !trimmed.isEmpty else { return }
        data.recordTypes[index] = trimmed
        scheduleSave()
    }

    func deleteRecordType(at index: Int) {
        guard data.recordTypes.indices.contains(index) else { return }
        data.recordTypes.remove(at: index)
        scheduleSave()
    }

    // MARK: - 附件

    /// 把外部文件复制进项目包；记录附件存到 记录目录，学生附件存到 files 目录
    @discardableResult
    func importAttachment(at sourceURL: URL, studentID: UUID, recordID: UUID?) throws -> URL {
        let destDir: URL
        if let recordID {
            guard let dir = recordFilesDirectory(studentID: studentID, recordID: recordID) else {
                throw ProjectError.cannotOpen("项目未打开。")
            }
            destDir = dir
        } else {
            guard let dir = studentFilesDirectory(studentID) else {
                throw ProjectError.cannotOpen("项目未打开。")
            }
            destDir = dir
        }
        return try copyFileToDirectory(at: sourceURL, directory: destDir)
    }

    func attachmentFileURLs(studentID: UUID, recordID: UUID? = nil) -> [URL] {
        let dir: URL?
        if let recordID {
            dir = recordFilesDirectory(studentID: studentID, recordID: recordID)
        } else {
            dir = studentFilesDirectory(studentID)
        }
        return filesIn(directory: dir)
    }

    func openAttachment(_ url: URL) {
        platform.openFile(url)
    }

    func revealInFinder(_ url: URL) {
        platform.revealFile(url)
    }

    func deleteAttachment(_ url: URL) {
        platform.deleteFile(url)
    }

    /// 复制文件到目录（重名自动 -1/-2 后缀）
    func copyFileToDirectory(at sourceURL: URL, directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var dest = directory.appendingPathComponent(sourceURL.lastPathComponent)
        var counter = 1
        while fm.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            dest = directory.appendingPathComponent(name)
            counter += 1
        }
        try fm.copyItem(at: sourceURL, to: dest)
        return dest
    }

    /// 枚举目录内文件（按修改时间倒序）
    func filesIn(directory: URL?) -> [URL] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { !$0.hasPrefix(".") }
            .map { directory.appendingPathComponent($0) }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
    }

    func trashItem(at url: URL) {
        platform.deleteFile(url)
    }
}
