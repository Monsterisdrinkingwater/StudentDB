import SwiftUI
import UniformTypeIdentifiers

// MARK: - 单张数据表（SwiftUI 版）

/// 行列表 + 行详情 + 新增行 + 删除选中；
/// 右上角菜单：新建表 / 导入 CSV / 导出 CSV、Excel、SQLite。
///
/// 行操作全部走共享层 ProjectStoreTables 扩展（addRow / updateRow / deleteRows），
/// 导出走共享层 ExcelExporter / SQLiteExporter 与本文件的 CSV 生成器。
struct TableViewScreen: View {
    @ObservedObject var store: ProjectStore
    let tableID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<UUID> = []
    @State private var showAddRow = false
    @State private var showDeleteConfirm = false
    @State private var showNewTable = false
    @State private var showCSVImporter = false
    @State private var importFile: IOSImportFile?
    @State private var shareItem: IOSShareItem?
    @State private var errorMessage: String?
    /// 新建表成功后回到列表页（等 sheet 关闭动画结束再 pop）
    @State private var popToListAfterCreate = false

    private var table: DBTable? { store.data.table(id: tableID) }

    var body: some View {
        Group {
            if let table {
                content(table)
            } else {
                ContentUnavailableView("表不存在", systemImage: "questionmark.folder")
            }
        }
    }

    // MARK: 主区

    @ViewBuilder
    private func content(_ table: DBTable) -> some View {
        Group {
            if table.rows.isEmpty {
                ContentUnavailableView(
                    "\(table.name) 还是空的",
                    systemImage: table.systemImage,
                    description: Text("点击下方「新增行」开始填写数据。")
                )
            } else {
                List(selection: $selection) {
                    ForEach(table.rows) { row in
                        NavigationLink(value: TableRowTarget(id: row.id)) {
                            rowCell(row, table: table)
                        }
                    }
                    .onDelete(perform: { deleteRows(at: $0, table: table) })
                }
                .navigationDestination(for: TableRowTarget.self) { target in
                    IOSRowDetailScreen(store: store, table: table, rowID: target.id)
                }
            }
        }
        .navigationTitle(table.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 进入数据表 = 切换当前表（与 macOS 侧栏同一条共享层路径）：
            // switchTable 会清空全部会话内筛选（含学生页的搜索 / 快捷筛选），
            // 切回学生页时显示全部学生。同一张表反复进出不重复清空。
            if store.data.currentTableID != table.id {
                store.switchTable(id: table.id)
            }
        }
        .toolbar {
            // 右上角菜单
            ToolbarItem(placement: .navigationBarTrailing) {
                tableMenu(table)
            }
            // 底部工具栏：多选编辑 / 新增行 / 删除选中
            ToolbarItemGroup(placement: .bottomBar) {
                EditButton()
                Spacer()
                Button {
                    showAddRow = true
                } label: {
                    Label("新增行", systemImage: "plus")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除选中", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
        .sheet(isPresented: $showAddRow) {
            IOSAddRowSheet(store: store, table: table)
        }
        .sheet(isPresented: $showNewTable) {
            IOSNewTableSheet(store: store) {
                popToListAfterCreate = true
            }
        }
        .onChange(of: showNewTable) { _, stillShown in
            // sheet 已关闭且刚创建过表 → 回到表列表（新表立即可见）
            if !stillShown, popToListAfterCreate {
                popToListAfterCreate = false
                dismiss()
            }
        }
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: [.commaSeparatedText]
        ) { result in
            switch result {
            case .success(let url):
                importFile = IOSImportFile(url: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $importFile) { file in
            IOSTableImportSheet(store: store, table: table, fileURL: file.url)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog(
            "删除选中的 \(selection.count) 行？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除 \(selection.count) 行", role: .destructive) {
                store.deleteRows(tableID: table.id, ids: selection)
                selection.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("行内的附件会一并从项目中删除，此操作不可撤销。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 右上角菜单

    private func tableMenu(_ table: DBTable) -> some View {
        Menu {
            Button {
                showNewTable = true
            } label: {
                Label("新建表…", systemImage: "table.badge.more")
            }

            Button {
                showCSVImporter = true
            } label: {
                Label("导入 CSV…", systemImage: "square.and.arrow.down")
            }

            Divider()

            Button {
                exportTable(.csv, table: table)
            } label: {
                Label("导出 CSV", systemImage: "doc.plaintext")
            }
            Button {
                exportTable(.excel, table: table)
            } label: {
                Label("导出 Excel (.xlsx)", systemImage: "tablecells")
            }
            Button {
                exportTable(.sqlite, table: table)
            } label: {
                Label("导出 SQLite（整个项目）", systemImage: "cylinder")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: 行

    /// 行摘要：前 3 个字段的显示文本（关联学生→姓名；附件→📎N）
    private func rowCell(_ row: DBRow, table: DBTable) -> some View {
        let texts = previewTexts(of: row, table: table)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(texts.enumerated()), id: \.offset) { pair in
                if pair.element.isEmpty {
                    Text(pair.offset == 0 ? "（未填写）" : "—")
                        .font(pair.offset == 0 ? .callout : .caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text(pair.element)
                        .font(pair.offset == 0 ? .callout.weight(.medium) : .caption)
                        .foregroundStyle(pair.offset == 0 ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func previewTexts(of row: DBRow, table: DBTable) -> [String] {
        let nameMap = Dictionary(uniqueKeysWithValues: store.data.students.map { ($0.id, $0.name) })
        let studentName = { (id: UUID) -> String in nameMap[id] ?? "（未知学生）" }
        return table.orderedFields.prefix(3).map { field -> String in
            if field.type == .attachment {
                let count = store.attachmentFileURLs(tableID: table.id,
                                                     rowID: row.id,
                                                     fieldID: field.id).count
                return count > 0 ? "📎 \(count)" : ""
            }
            return TableQuery.displayText(of: row, field: field, studentName: studentName)
        }
    }

    /// 左滑删除单行
    private func deleteRows(at offsets: IndexSet, table: DBTable) {
        let ids = Set(offsets.compactMap { index -> UUID? in
            table.rows.indices.contains(index) ? table.rows[index].id : nil
        })
        guard !ids.isEmpty else { return }
        store.deleteRows(tableID: table.id, ids: ids)
        selection.subtract(ids)
    }

    // MARK: 导出

    private func exportTable(_ format: IOSTableExport.Format, table: DBTable) {
        do {
            let url = try IOSTableExport.export(table: table, store: store, format: format)
            shareItem = IOSShareItem(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 行导航目标包装（与表的 TableViewTarget 区分）
struct TableRowTarget: Hashable {
    let id: UUID
}

/// sheet(item:) 用的导入文件包装
struct IOSImportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// sheet(item:) 用的分享文件包装
struct IOSShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - 单表导出

/// CSV 在本文件生成（UTF-8 带 BOM）；Excel 复用 ExcelExporter（只导当前表一张工作表）；
/// SQLite 复用 SQLiteExporter（导出整个项目：学生总表 + 全部数据表）。
@MainActor
enum IOSTableExport {

    enum Format: String, CaseIterable, Identifiable {
        case csv
        case excel
        case sqlite

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .excel: return "xlsx"
            case .sqlite: return "sqlite"
            }
        }
    }

    /// 导出到临时目录，返回文件 URL（交给分享面板「存储到文件 / 发送」）
    static func export(table: DBTable, store: ProjectStore, format: Format) throws -> URL {
        let safeName = table.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-\(Fmt.fileStamp.string(from: Date())).\(format.fileExtension)")
        switch format {
        case .csv:
            try exportCSV(table: table, store: store, to: url)
        case .excel:
            try exportExcel(table: table, store: store, to: url)
        case .sqlite:
            try SQLiteExporter.export(data: store.data, to: url)
        }
        return url
    }

    /// 当前表 → CSV（关联学生解析姓名；附件列写文件名）
    private static func exportCSV(table: DBTable, store: ProjectStore, to url: URL) throws {
        let fields = table.orderedFields
        let nameMap = Dictionary(uniqueKeysWithValues: store.data.students.map { ($0.id, $0.name) })
        let studentName = { (id: UUID) -> String in nameMap[id] ?? "（未知学生）" }

        var rows: [[String]] = [fields.map { $0.name }]
        for row in table.rows {
            var cells: [String] = []
            for field in fields {
                if field.type == .attachment {
                    let names = store.attachmentFileURLs(tableID: table.id, rowID: row.id, fieldID: field.id)
                        .map { $0.lastPathComponent }
                    cells.append(names.joined(separator: "、"))
                } else {
                    cells.append(TableQuery.displayText(of: row, field: field, studentName: studentName))
                }
            }
            rows.append(cells)
        }
        let text = rows.map { $0.map(escape).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        var data = Data([0xEF, 0xBB, 0xBF]) // BOM：保证 Excel 识别中文
        data.append(Data(text.utf8))
        try data.write(to: url, options: [.atomic])
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    /// 当前表 → Excel（ExportSelection 只勾选这一张表）
    private static func exportExcel(table: DBTable, store: ProjectStore, to url: URL) throws {
        guard !table.fields.isEmpty else {
            throw ProjectError.cannotOpen("这张表还没有字段，无法导出。")
        }
        var selection = ExportSelection()
        selection.includeRoster = false
        selection.includeGuardians = false
        selection.includeRecords = false
        selection.tableIDs = [table.id]
        selection.tableFields = [table.id: Set(table.fields.map { $0.id })]
        try ExcelExporter.exportAll(data: store.data, to: url, selection: selection)
    }
}

// MARK: - 行详情

/// 字段名 + 值列表：文本类值就地编辑（即时写回 store.updateRow），
/// 布尔/日期/选择直接交互，关联学生勾选，附件区可添加/预览/分享/删除。
struct IOSRowDetailScreen: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let rowID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var textDrafts: [String: String] = [:]
    @State private var loadedKeys: Set<String> = []
    @State private var showDeleteConfirm = false

    private var row: DBRow? { table.row(id: rowID) }

    var body: some View {
        Group {
            if let row {
                detail(row)
            } else {
                ContentUnavailableView(
                    "该行已被删除",
                    systemImage: "trash",
                    description: Text("返回上一页查看其他行。")
                )
            }
        }
        .navigationTitle(table.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            "删除这一行？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除行", role: .destructive) {
                store.deleteRows(tableID: table.id, ids: Set([rowID]))
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("行内的附件会一并从项目中删除，此操作不可撤销。")
        }
    }

    @ViewBuilder
    private func detail(_ row: DBRow) -> some View {
        Form {
            Section {
                Text("创建于 \(Fmt.dateTime.string(from: row.createdAt)) · 修改于 \(Fmt.dateTime.string(from: row.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(table.orderedFields) { field in
                Section(field.name) {
                    fieldEditor(field, row: row)
                }
            }
        }
        .onAppear { syncDrafts(row) }
    }

    // MARK: 字段编辑器

    @ViewBuilder
    private func fieldEditor(_ field: CustomField, row: DBRow) -> some View {
        let key = field.id.uuidString
        switch field.type {
        case .text:
            TextField("未填写", text: textBinding(field))
                .autocorrectionDisabled()
        case .address:
            TextField("未填写", text: textBinding(field), axis: .vertical)
                .lineLimit(2...6)
        case .phone:
            TextField("未填写", text: textBinding(field))
                .keyboardType(.phonePad)
        case .idCard:
            TextField("未填写", text: textBinding(field))
        case .number:
            TextField("未填写", text: textBinding(field))
                .keyboardType(.decimalPad)
        case .boolean:
            Toggle("是 / 否", isOn: Binding(
                get: { row.values[key]?.displayText == "是" },
                set: { write(key: key, value: .boolean($0)) }
            ))
        case .date:
            DatePicker("日期", selection: dateBinding(field, row: row),
                       displayedComponents: [.date])
                .labelsHidden()
        case .dateTime:
            DatePicker("时间", selection: dateBinding(field, row: row))
                .labelsHidden()
        case .choice(let options):
            Picker("选择", selection: choiceBinding(field, row: row)) {
                Text("（空）").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .multiChoice(let options):
            IOSMultiChoiceMenu(options: options,
                               current: row.values[key]?.displayText ?? "") { text in
                write(key: key, value: text.isEmpty ? nil : .text(text))
            }
        case .linkStudents:
            IOSLinkFieldEditor(store: store, table: table, field: field, row: row)
        case .attachment:
            IOSAttachmentSection(store: store, table: table, rowID: rowID, fieldID: field.id)
        }
    }

    // MARK: 草稿与写回

    /// 首次进入把存量文本铺进草稿（之后输入不再被 store 刷新打断）
    private func syncDrafts(_ row: DBRow) {
        for field in table.fields {
            let key = field.id.uuidString
            guard !loadedKeys.contains(key) else { continue }
            switch field.type {
            case .text, .address, .number, .phone, .idCard, .choice, .multiChoice:
                textDrafts[key] = row.values[key]?.displayText ?? ""
            case .boolean, .date, .dateTime, .linkStudents, .attachment:
                break
            }
            loadedKeys.insert(key)
        }
    }

    private func textBinding(_ field: CustomField) -> Binding<String> {
        let key = field.id.uuidString
        return Binding(
            get: { textDrafts[key] ?? "" },
            set: { newValue in
                textDrafts[key] = newValue
                commitText(field: field, raw: newValue)
            }
        )
    }

    private func commitText(field: CustomField, raw: String) {
        let key = field.id.uuidString
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.type {
        case .number:
            if trimmed.isEmpty {
                write(key: key, value: nil)
            } else if let n = Double(trimmed) {
                write(key: key, value: .number(n))
            }
            // 还不是合法数字：先不写回，等输入完成
        case .text, .address, .phone, .idCard, .choice, .multiChoice:
            write(key: key, value: trimmed.isEmpty ? nil : .text(trimmed))
        case .boolean, .date, .dateTime, .linkStudents, .attachment:
            break
        }
    }

    private func choiceBinding(_ field: CustomField, row: DBRow) -> Binding<String> {
        let key = field.id.uuidString
        return Binding(
            get: { row.values[key]?.displayText ?? "" },
            set: { write(key: key, value: $0.isEmpty ? nil : .text($0)) }
        )
    }

    private func dateBinding(_ field: CustomField, row: DBRow) -> Binding<Date> {
        let key = field.id.uuidString
        return Binding(
            get: {
                if case .date(let d)? = row.values[key] { return d }
                return Date()
            },
            set: { write(key: key, value: .date($0)) }
        )
    }

    private func write(key: String, value: CustomValue?) {
        guard var updated = table.row(id: rowID) else { return }
        if let value {
            updated.values[key] = value
        } else {
            updated.values.removeValue(forKey: key)
        }
        store.updateRow(tableID: table.id, row: updated)
    }
}

/// 关联学生格（行详情）：chips 展示 + 点击进入选择页
struct IOSLinkFieldEditor: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let field: CustomField
    let row: DBRow

    var body: some View {
        let key = field.id.uuidString
        let ids = row.values[key]?.linkedStudentIDs ?? []
        let students = ids.compactMap { id in store.data.students.first { $0.id == id } }
        return NavigationLink {
            IOSStudentPickSheet(store: store, selected: Binding(
                get: { table.row(id: row.id)?.values[key]?.linkedStudentIDs ?? [] },
                set: { write($0) }
            ))
        } label: {
            if students.isEmpty {
                Text("选择学生")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(students) { student in
                        HStack(spacing: 8) {
                            iOSAvatarView(name: student.name, size: 22)
                            Text(student.name)
                        }
                    }
                }
            }
        }
    }

    private func write(_ ids: [UUID]) {
        guard var updated = table.row(id: row.id) else { return }
        if ids.isEmpty {
            updated.values.removeValue(forKey: field.id.uuidString)
        } else {
            updated.values[field.id.uuidString] = .link(ids)
        }
        store.updateRow(tableID: table.id, row: updated)
    }
}

// MARK: - 多选菜单（iOS 版，替代 Mac 版 MultiChoiceMenu 的 borderlessButton 样式）

/// 多选菜单（顿号拼接值）
struct IOSMultiChoiceMenu: View {
    let options: [String]
    let current: String
    let onChange: (String) -> Void

    private var selected: Set<String> {
        Set(current.components(separatedBy: "、").filter { !$0.isEmpty })
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    var next = selected
                    if next.contains(option) {
                        next.remove(option)
                    } else {
                        next.insert(option)
                    }
                    onChange(options.filter { next.contains($0) }.joined(separator: "、"))
                } label: {
                    if selected.contains(option) {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack {
                Text(current.isEmpty ? "（空）" : current)
                    .foregroundStyle(current.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 关联学生选择页（新增行表单与行详情共用）

struct IOSStudentPickSheet: View {
    @ObservedObject var store: ProjectStore
    @Binding var selected: [UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""

    private var students: [Student] {
        let base = store.data.students.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(kw)
                || $0.studentNumber.localizedCaseInsensitiveContains(kw)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("搜索姓名 / 学号", text: $keyword)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(students) { student in
                        Button {
                            toggle(student.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(student.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(student.id)
                                                     ? Color.accentColor : Color.secondary)
                                iOSAvatarView(name: student.name, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(student.name)
                                    if !student.studentNumber.isEmpty {
                                        Text(student.studentNumber)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("选择学生（可多选）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else {
            selected.append(id)
        }
    }
}

// MARK: - 新增行（简易表单）

/// 按字段循环渲染 TextField / DatePicker / Toggle / Picker → store.addRow
struct IOSAddRowSheet: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    @Environment(\.dismiss) private var dismiss

    @State private var textDrafts: [String: String] = [:]
    @State private var dateDrafts: [String: Date] = [:]
    @State private var boolDrafts: [String: Bool] = [:]
    @State private var linkDrafts: [String: [UUID]] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(table.orderedFields) { field in
                    fieldSection(field)
                }
            }
            .navigationTitle("新增行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldSection(_ field: CustomField) -> some View {
        let key = field.id.uuidString
        Section(field.name) {
            switch field.type {
            case .text:
                TextField("未填写", text: textDraft(key))
                    .autocorrectionDisabled()
            case .address:
                TextField("未填写", text: textDraft(key), axis: .vertical)
                    .lineLimit(2...5)
            case .phone:
                TextField("未填写", text: textDraft(key))
                    .keyboardType(.phonePad)
            case .idCard:
                TextField("未填写", text: textDraft(key))
            case .number:
                TextField("未填写", text: textDraft(key))
                    .keyboardType(.decimalPad)
            case .boolean:
                Toggle("是 / 否", isOn: boolDraft(key))
            case .date:
                DatePicker("日期", selection: dateDraft(key), displayedComponents: [.date])
            case .dateTime:
                DatePicker("时间", selection: dateDraft(key))
            case .choice(let options):
                Picker("选择", selection: textDraft(key)) {
                    Text("（空）").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            case .multiChoice(let options):
                IOSMultiChoiceMenu(options: options,
                                   current: textDrafts[key] ?? "") { textDrafts[key] = $0 }
            case .linkStudents:
                NavigationLink {
                    IOSStudentPickSheet(store: store, selected: linkDraft(key))
                } label: {
                    HStack {
                        Text("关联学生")
                        Spacer()
                        linkedSummary(key)
                    }
                }
            case .attachment:
                Text("保存后可在行详情中添加附件")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func textDraft(_ key: String) -> Binding<String> {
        Binding(get: { textDrafts[key] ?? "" }, set: { textDrafts[key] = $0 })
    }

    private func boolDraft(_ key: String) -> Binding<Bool> {
        Binding(get: { boolDrafts[key] ?? false }, set: { boolDrafts[key] = $0 })
    }

    private func dateDraft(_ key: String) -> Binding<Date> {
        Binding(get: { dateDrafts[key] ?? Date() }, set: { dateDrafts[key] = $0 })
    }

    private func linkDraft(_ key: String) -> Binding<[UUID]> {
        Binding(get: { linkDrafts[key] ?? [] }, set: { linkDrafts[key] = $0 })
    }

    private func linkedSummary(_ key: String) -> some View {
        let ids = linkDrafts[key] ?? []
        let map = Dictionary(uniqueKeysWithValues: store.data.students.map { ($0.id, $0.name) })
        return Text(ids.isEmpty ? "选择学生" : ids.map { map[$0] ?? "未知" }.joined(separator: "、"))
            .font(.callout)
            .foregroundStyle(ids.isEmpty ? Color.secondary : Color.primary)
            .lineLimit(1)
    }

    private func save() {
        var values: [String: CustomValue] = [:]
        for field in table.fields {
            let key = field.id.uuidString
            switch field.type {
            case .text, .address, .phone, .idCard:
                let t = (textDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { values[key] = .text(t) }
            case .number:
                let t = (textDrafts[key] ?? "").trimmingCharacters(in: .whitespaces)
                if let n = Double(t) { values[key] = .number(n) }
            case .choice, .multiChoice:
                let t = (textDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { values[key] = .text(t) }
            case .boolean:
                if let b = boolDrafts[key] { values[key] = .boolean(b) }
            case .date, .dateTime:
                if let d = dateDrafts[key] { values[key] = .date(d) }
            case .linkStudents:
                if let ids = linkDrafts[key], !ids.isEmpty { values[key] = .link(ids) }
            case .attachment:
                break
            }
        }
        _ = store.addRow(tableID: table.id, values: values)
        dismiss()
    }
}

// MARK: - 导入 CSV（简化版：自动映射 + 确认页）

/// 选取 CSV 后按列标题自动匹配字段（TableImporter.autoGuessMapping），
/// 确认页可逐列调整映射；可选「为未映射的列新建同名字段」，
/// 最终交给共享层 TableImporter 转换与写入（不含查重，全部追加为新行）。
struct IOSTableImportSheet: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var loadError: String?
    @State private var grid: [[String]] = []
    @State private var mapping: [Int: TableImportTarget] = [:]
    @State private var createMissingFields = true
    @State private var report: TableImportReport?

    private var header: [String] { grid.first ?? [] }
    private var dataRowCount: Int { max(grid.count - 1, 0) }

    var body: some View {
        NavigationStack {
            Group {
                if let report {
                    reportView(report)
                } else if let loadError {
                    ContentUnavailableView(
                        "无法读取文件",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else {
                    mappingView
                }
            }
            .navigationTitle("导入 CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if report == nil {
                        Button("导入") { runImport() }
                            .fontWeight(.semibold)
                            .disabled(loadError != nil)
                    } else {
                        Button("完成") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: 读取与映射

    private func load() {
        guard !loaded else { return }
        loaded = true
        // fileImporter 给出的 URL 需要临时访问授权
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: fileURL)
            grid = CSVParser.parse(data: data)
            guard grid.count > 1 else {
                loadError = "文件里没有数据行（首行作为列标题）。"
                return
            }
            mapping = TableImporter.autoGuessMapping(header: header, fields: table.fields)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var mappingView: some View {
        Form {
            Section {
                LabeledContent("文件", value: fileURL.lastPathComponent)
                LabeledContent("数据行数", value: "\(dataRowCount) 行")
            } footer: {
                Text("首行作为列标题。")
            }

            Section {
                ForEach(header.indices, id: \.self) { column in
                    mappingRow(column)
                }
            } header: {
                Text("列映射（已按字段名自动匹配）")
            } footer: {
                Text("未映射的列在开启下方开关时会创建为同名字段；关联学生列按姓名/学号匹配。")
            }

            Section {
                Toggle("为未映射的列新建同名字段", isOn: $createMissingFields)
            }
        }
    }

    private func mappingRow(_ column: Int) -> some View {
        let title = header[column]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Picker(title.isEmpty ? "第 \(column + 1) 列" : title,
                      selection: Binding(
                        get: { mapping[column] ?? .ignore },
                        set: { mapping[column] = $0 }
                      )) {
            Text("不导入").tag(TableImportTarget.ignore)
            ForEach(table.fields) { field in
                Text(field.name).tag(TableImportTarget.field(id: field.id))
            }
        }
    }

    private func isUnmapped(_ column: Int) -> Bool {
        switch mapping[column] {
        case .field: return false
        case .ignore, .newField, nil: return true
        }
    }

    // MARK: 执行导入

    private func runImport() {
        var finalMapping = mapping
        if createMissingFields {
            for column in header.indices where isUnmapped(column) {
                let title = header[column].trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { finalMapping[column] = .newField }
            }
        }
        // 「新建字段」列先按整列内容建字段（数字列建数字字段）
        TableImporter.createFieldsIfNeeded(
            grid: grid, header: header, headerRowIndex: 0,
            mapping: finalMapping, store: store, tableID: table.id
        )
        // 再把 .newField 解析成真实字段 id
        let currentFields = store.data.table(id: table.id)?.fields ?? table.fields
        finalMapping = TableImporter.resolveNewFieldMappings(
            finalMapping, header: header, fields: currentFields
        )
        // 简化版不查重：全部追加为新行（keyField 传 nil）
        report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: finalMapping,
            keyField: nil, store: store, tableID: table.id, updateExisting: false
        )
    }

    private func reportView(_ report: TableImportReport) -> some View {
        Form {
            Section {
                LabeledContent("新增", value: "\(report.imported) 行")
                LabeledContent("更新", value: "\(report.updated) 行")
            }
            if !report.skipped.isEmpty {
                Section("提示") {
                    ForEach(report.skipped.prefix(30), id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                    }
                    if report.skipped.count > 30 {
                        Text("… 共 \(report.skipped.count) 条提示")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
