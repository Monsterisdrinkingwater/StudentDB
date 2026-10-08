import SwiftUI
import UniformTypeIdentifiers

// MARK: - 记录标签页

struct RecordsTabView: View {
    @ObservedObject var store: ProjectStore
    let student: Student

    @State private var editingRow: LinkedRowItem?
    @State private var pendingDelete: (tableID: UUID, rowID: UUID)?
    @State private var showDeleteConfirm = false
    @State private var typeFilterID: UUID?
    /// 新增记录时选择的表（= 记录类别）
    @State private var addTableID: UUID?

    /// 该学生的全部关联记录行（每类记录一张表）
    private var linkedRows: [(table: DBTable, row: DBRow)] {
        store.rowsLinking(toStudent: student.id).compactMap { item in
            guard let table = store.data.table(id: item.tableID) else { return nil }
            return (table, item.row)
        }
    }

    /// 多表联动：凡是有"关联学生"字段的表（记录表/平时观察/自定义表）都纳入汇总
    private var recordTables: [DBTable] {
        store.data.tables.filter { $0.linkField != nil }
    }

    private var visibleItems: [(table: DBTable, row: DBRow)] {
        guard let typeFilterID else { return linkedRows }
        return linkedRows.filter { $0.table.id == typeFilterID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if recordTables.isEmpty {
                ContentUnavailableView(
                    "还没有记录表",
                    systemImage: "heart.text.square",
                    description: Text("在左侧栏「新建表」中创建记录类数据表。")
                )
            } else if linkedRows.isEmpty {
                ContentUnavailableView(
                    "还没有记录",
                    systemImage: "heart.text.square",
                    description: Text("点击右上角 + 新增一条记录。")
                )
            } else {
                typeChipBar
                Divider()
                List {
                    ForEach(visibleItems, id: \.row.id) { item in
                        genericRecordRow(item.table, row: item.row)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: Binding(
            get: { addTableID.flatMap { store.data.table(id: $0) }.map { LinkedRowItem(table: $0, rowID: rowID(of: $0)) } },
            set: { addTableID = nil; if $0 != nil { } }
        )) { item in
            RowEditorSheet(store: store, table: item.table, editingRowID: nil,
                           initialStudentIDs: [student.id]) { _ in }
                .frame(width: 560)
        }
        .sheet(item: $editingRow) { item in
            RowEditorSheet(store: store, table: item.table, editingRowID: item.rowID) { _ in }
                .resizableSheet(minWidth: 460, minHeight: 380, idealWidth: 560, idealHeight: 460)
        }
        .confirmationDialog(
            "删除这条记录？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除记录", role: .destructive) {
                if let target = pendingDelete {
                    store.deleteRows(tableID: target.tableID, ids: [target.rowID])
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("记录的附件文件也会一并移入废纸篓。")
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(recordTables) { table in
                        Button(table.name) { addTableID = table.id }
                    }
                } label: {
                    Label("添加记录", systemImage: "plus")
                }
                .help("添加记录")
            }
        }
    }

    /// 行编辑器的 item 需要 id；这里给新表行一个占位 id
    private func rowID(of table: DBTable) -> UUID {
        table.rows.first?.id ?? UUID(uuidString: "E0000000-0000-0000-0000-000000000000")!
    }

    /// 类别筛选标签（含数量）
    private var typeChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                countChip(title: "全部", count: linkedRows.count,
                          isActive: typeFilterID == nil) { typeFilterID = nil }
                ForEach(recordTables) { table in
                    let count = linkedRows.filter { $0.table.id == table.id }.count
                    countChip(title: table.name, count: count,
                              isActive: typeFilterID == table.id) { typeFilterID = table.id }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func countChip(title: String, count: Int, isActive: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .background(isActive ? Color.white.opacity(0.25) : Color(nsColor: .separatorColor).opacity(0.5),
                                in: Capsule())
            }
            .font(.caption.weight(isActive ? .semibold : .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isActive ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor),
                        in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.6)
                )
            )
            .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private func genericRecordRow(_ table: DBTable, row: DBRow) -> some View {
        let display = rowDisplay(table: table, row: row)
        let fileCount = store.nameRowFileCount(tableID: table.id, rowID: row.id)
        return HStack(spacing: 10) {
            TypeChip(text: table.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(display.summary.isEmpty ? "（无内容）" : display.summary)
                    .font(.callout)
                    .lineLimit(3)
                Text(display.dateText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if fileCount > 0 {
                Label("\(fileCount)", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            editingRow = LinkedRowItem(table: table, rowID: row.id)
        }
        .contextMenu {
            Button("编辑记录…") { editingRow = LinkedRowItem(table: table, rowID: row.id) }
            Button("删除记录…", role: .destructive) {
                pendingDelete = (table.id, row.id)
                showDeleteConfirm = true
            }
        }
    }

    /// 摘要：日期字段的日期 + 第一个文本字段的内容
    private func rowDisplay(table: DBTable, row: DBRow) -> (dateText: String, summary: String) {
        var dateText = Fmt.date.string(from: row.createdAt)
        var summary = ""
        for field in table.orderedFields {
            if case .date(let d)? = row.values[field.id.uuidString] {
                dateText = Fmt.date.string(from: d)
            }
            if summary.isEmpty, field.type == .text || field.type == .address {
                summary = row.values[field.id.uuidString]?.displayText ?? ""
            }
        }
        return (dateText, summary)
    }
}

private struct LinkedRowItem: Identifiable {
    let table: DBTable
    let rowID: UUID
    var id: UUID { rowID }
}

struct RecordRow: View {
    let record: CareRecord
    let fileCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                Text(Fmt.date.string(from: record.date))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                TypeChip(text: record.type)
            }
            .frame(width: 96, alignment: .leading)

            Text(record.content.isEmpty ? "（无内容）" : record.content)
                .font(.callout)
                .foregroundStyle(record.content.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if fileCount > 0 {
                Label("\(fileCount)", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("\(fileCount) 个附件")
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 记录编辑器（新建 / 编辑）

struct RecordEditorSheet: View {
    @ObservedObject var store: ProjectStore
    let studentID: UUID
    let record: CareRecord?   // nil = 新建
    /// 新建时的默认类别（跟随记录页当前筛选）
    var defaultType: String? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var type = ""
    @State private var content = ""
    @State private var existingFiles: [URL] = []
    @State private var pendingFiles: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            Text(record == nil ? "添加关心关爱记录" : "编辑记录")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 14) {
                    FormCard(title: "记录内容", systemImage: "square.and.pencil") {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("日期")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            DatePicker("", selection: $date, displayedComponents: .date)
                                .labelsHidden()
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("类型")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            Picker("", selection: $type) {
                                ForEach(store.data.recordTypes, id: \.self) { t in
                                    Text(t).tag(t)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            Text("内容")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                                .padding(.top, 6)
                            TextEditor(text: $content)
                                .font(.body)
                                .frame(minHeight: 110, maxHeight: 220)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color(nsColor: .separatorColor))
                                )
                        }
                        .padding(.vertical, 5)
                    }

                    FormCard(title: "附件（可拖入照片、文档等）", systemImage: "paperclip") {
                        attachmentSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear(perform: loadInitial)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - 附件区

    @ViewBuilder
    private var attachmentSection: some View {
        let files = existingFiles + pendingFiles
        if files.isEmpty {
            HStack {
                Image(systemName: "arrow.down.doc")
                    .foregroundStyle(.tertiary)
                Text("拖入文件，或点击“添加附件”。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(Color(nsColor: .separatorColor))
            )
        } else {
            VStack(spacing: 0) {
                ForEach(files, id: \.absoluteString) { url in
                    HStack(spacing: 8) {
                        FileIconView(url: url, size: 22)
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if pendingFiles.contains(url) {
                            Text("待保存")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        if record != nil && !pendingFiles.contains(url) {
                            Button {
                                store.openAttachment(url)
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .buttonStyle(.borderless)
                            .help("打开")
                        }
                        Button {
                            removeFile(url)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("移除")
                    }
                    .padding(.vertical, 5)
                    if url != files.last {
                        Divider()
                    }
                }
            }
        }

        HStack {
            Button {
                addFilesViaPanel()
            } label: {
                Label("添加附件", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("附件保存在项目包内，随项目一起备份迁移。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    // MARK: - 逻辑

    private func loadInitial() {
        if let record {
            date = record.date
            type = record.type
            content = record.content
            existingFiles = store.attachmentFileURLs(studentID: studentID, recordID: record.id)
        } else {
            if let defaultType, store.data.recordTypes.contains(defaultType) {
                type = defaultType
            } else {
                type = store.data.recordTypes.first ?? "关心关爱记录"
            }
        }
    }

    private func addFilesViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "添加附件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        pendingFiles += panel.urls.filter { !pendingFiles.contains($0) && !existingFiles.contains($0) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var added = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if !pendingFiles.contains(url) && !existingFiles.contains(url) {
                        pendingFiles.append(url)
                    }
                }
            }
            added = true
        }
        return added
    }

    private func removeFile(_ url: URL) {
        if pendingFiles.contains(url) {
            pendingFiles.removeAll { $0 == url }
        } else if let record {
            store.deleteAttachment(url)
            existingFiles = store.attachmentFileURLs(studentID: studentID, recordID: record.id)
        }
    }

    private func save() {
        let trimmedType = type.isEmpty ? "其他" : type
        let recordToSave: CareRecord
        if var existing = record {
            existing.date = date
            existing.type = trimmedType
            existing.content = content
            recordToSave = existing
            store.updateRecord(recordToSave, studentID: studentID)
        } else {
            var newRecord = CareRecord()
            newRecord.date = date
            newRecord.type = trimmedType
            newRecord.content = content
            recordToSave = newRecord
            store.addRecord(newRecord, to: studentID)
        }

        for file in pendingFiles {
            if let imported = try? store.importAttachment(at: file, studentID: studentID, recordID: recordToSave.id) {
                _ = imported
            }
        }
        dismiss()
    }
}
