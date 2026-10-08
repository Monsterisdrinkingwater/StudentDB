import SwiftUI

/// 导出选择页：勾选要导出的内容，再选择导出为 Excel 或 CSV
struct ExportSelectionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var store: ProjectStore

    @Environment(\.dismiss) private var dismiss

    @State private var includeRoster = true
    @State private var includeGuardians = true
    @State private var includeRecords = true
    @State private var selectedFieldIDs: Set<UUID> = []
    @State private var selectedRecordTypes: Set<String> = []
    @State private var selectedTableIDs: Set<UUID> = []
    @State private var selectedTableFields: [UUID: Set<UUID>] = [:]
    @State private var selectedBuiltinColumns: Set<String> = []
    @State private var guardianSlots = 1
    /// true = 按当前列表（会话内筛选）导出；false = 全部学生
    @State private var useCurrentView = true

    private var allStudents: [Student] { store.data.students }
    private var currentView: ListView { store.currentView }
    private var viewStudents: [Student] {
        StudentQuery.apply(view: currentView, students: allStudents, fields: store.data.fieldDefinitions,
                           builtinOrder: store.data.builtinOrder,
                           deletedBuiltin: store.data.deletedBuiltinFields)
    }
    private var scopedStudents: [Student] {
        useCurrentView ? viewStudents : allStudents
    }
    private var studentCount: Int { scopedStudents.count }
    private var guardianCount: Int {
        scopedStudents.reduce(0) { $0 + $1.guardians.filter { !$0.isEmpty }.count }
    }
    private var recordCount: Int {
        scopedStudents.reduce(0) { $0 + $1.records.count }
    }

    /// 记录类别（项目类型 + 记录中出现过的其他类别）及数量
    private var recordTypeRows: [(type: String, count: Int)] {
        let counts = Dictionary(grouping: scopedStudents.flatMap { $0.records }, by: \.type)
            .mapValues(\.count)
        var seen = Set<String>()
        var rows: [(String, Int)] = []
        for type in store.data.recordTypes {
            seen.insert(type)
            rows.append((type, counts[type] ?? 0))
        }
        for (type, count) in counts.sorted(by: { $0.value > $1.value }) where !seen.contains(type) {
            rows.append((type, count))
        }
        return rows
    }
    private var hasCustomFields: Bool { !store.data.fieldDefinitions.isEmpty }
    private var viewIsFiltered: Bool {
        currentView.condition != .all || !currentView.keyword.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("导出数据")
                    .font(.headline)
                Text("勾选要导出的内容，各自导出为一个独立工作表。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            Form {
                Section {
                    Picker("导出范围", selection: $useCurrentView) {
                        Text("当前筛选结果（\(viewStudents.count) 名学生）").tag(true)
                        Text("全部学生（\(allStudents.count) 名）").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if useCurrentView && !viewIsFiltered {
                        Text("当前未设筛选，导出内容与“全部学生”相同。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("导出范围")
                }

                Section {
                    Toggle(isOn: $includeRoster) {
                        sectionLabel(title: "学生总表",
                                     detail: "共 \(studentCount) 名学生（基本信息 + 监护人汇总 + 记录数）")
                    }
                    if includeRoster {
                        ForEach(ExportSelection.builtinExportColumns, id: \.key) { column in
                            Toggle(column.title, isOn: builtinBinding(column.key))
                                .padding(.leading, 22)
                        }
                        if hasCustomFields {
                            ForEach(store.data.fieldDefinitions) { field in
                                Toggle("字段：\(field.name)", isOn: fieldBinding(field))
                                    .padding(.leading, 22)
                            }
                        } else {
                            Text("暂无自定义字段")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 22)
                        }
                    }
                    Picker("监护人列数", selection: $guardianSlots) {
                        Text("不导出监护人列").tag(0)
                        ForEach(1...4, id: \.self) { n in
                            Text("\(n) 组（监护人\(n)姓名/关系/电话）").tag(n)
                        }
                    }
                    .disabled(!includeRoster)
                    .padding(.leading, 22)
                } header: {
                    Text("学生信息")
                }

                Section {
                    Toggle(isOn: $includeGuardians) {
                        sectionLabel(title: "监护人明细", detail: "共 \(guardianCount) 位监护人，每位一行")
                    }
                } header: {
                    Text("监护人")
                }

                Section {
                    ForEach(store.data.tables) { table in
                        Toggle(isOn: tableBinding(table)) {
                            sectionLabel(title: table.name,
                                         detail: "共 \(table.rows.count) 行 · 勾选要导出的字段")
                        }
                        if selectedTableIDs.contains(table.id) {
                            ForEach(table.orderedFields) { field in
                                Toggle(field.name, isOn: tableFieldBinding(table: table, field: field))
                                    .padding(.leading, 22)
                            }
                            if table.fields.isEmpty {
                                Text("这张表还没有字段")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 22)
                            }
                        }
                    }
                    if store.data.tables.isEmpty {
                        Text("暂无数据表")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("数据表（每张一个工作表）")
                }

                if recordCount > 0 {
                    Section {
                        Toggle(isOn: $includeRecords) {
                            sectionLabel(title: "学生记录明细", detail: "共 \(recordCount) 条（含类别列）")
                        }
                        if includeRecords {
                            ForEach(recordTypeRows, id: \.type) { row in
                                Toggle("\(row.type)（\(row.count) 条）", isOn: recordTypeBinding(row.type))
                                    .padding(.leading, 22)
                            }
                            if recordTypeRows.isEmpty {
                                Text("暂无记录")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 22)
                            }
                        }
                    } header: {
                        Text("记录（按类别勾选）")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text("CSV 仅导出学生总表；Excel 包含全部勾选项。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导出 CSV…") {
                    let students = scopedStudents
                    let selection = currentSelection
                    dismiss()
                    appModel.runCSVExport(selection: selection, students: students)
                }
                .disabled(!includeRoster)
                .help(includeRoster ? "" : "请先勾选“学生总表”")
                Button("导出 Excel…") {
                    let students = scopedStudents
                    let selection = currentSelection
                    dismiss()
                    appModel.runExcelExport(selection: selection, students: students)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!currentSelection.includesAnything)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(width: 470, height: 540)
        .onAppear {
            selectedFieldIDs = Set(store.data.fieldDefinitions.map { $0.id })
            selectedRecordTypes = Set(store.data.recordTypes)
            selectedTableIDs = Set(store.data.tables.map { $0.id })
            selectedTableFields = Dictionary(uniqueKeysWithValues:
                store.data.tables.map { ($0.id, Set($0.fields.map { $0.id })) })
            selectedBuiltinColumns = Set(ExportSelection.builtinExportColumns.map { $0.key })
            guardianSlots = max(0, min(4, store.currentView.guardianColumnCount))
        }
    }

    private func sectionLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var currentSelection: ExportSelection {
        ExportSelection(
            includeRoster: includeRoster,
            includeGuardians: includeGuardians,
            includeRecords: includeRecords,
            customFieldIDs: selectedFieldIDs,
            guardianSlots: guardianSlots,
            recordTypes: selectedRecordTypes,
            tableIDs: selectedTableIDs,
            builtinColumns: selectedBuiltinColumns,
            tableFields: selectedTableFields
        )
    }

    private func builtinBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { selectedBuiltinColumns.contains(key) },
            set: {
                if $0 {
                    selectedBuiltinColumns.insert(key)
                } else {
                    selectedBuiltinColumns.remove(key)
                }
            }
        )
    }

    private func tableFieldBinding(table: DBTable, field: CustomField) -> Binding<Bool> {
        Binding(
            get: { selectedTableFields[table.id]?.contains(field.id) ?? false },
            set: { include in
                var set = selectedTableFields[table.id] ?? []
                if include {
                    set.insert(field.id)
                } else {
                    set.remove(field.id)
                }
                selectedTableFields[table.id] = set
            }
        )
    }

    private func tableBinding(_ table: DBTable) -> Binding<Bool> {
        Binding(
            get: { selectedTableIDs.contains(table.id) },
            set: {
                if $0 {
                    selectedTableIDs.insert(table.id)
                } else {
                    selectedTableIDs.remove(table.id)
                }
            }
        )
    }

    private func fieldBinding(_ field: CustomField) -> Binding<Bool> {
        Binding(
            get: { selectedFieldIDs.contains(field.id) },
            set: {
                if $0 {
                    selectedFieldIDs.insert(field.id)
                } else {
                    selectedFieldIDs.remove(field.id)
                }
            }
        )
    }

    private func recordTypeBinding(_ type: String) -> Binding<Bool> {
        Binding(
            get: { selectedRecordTypes.contains(type) },
            set: {
                if $0 {
                    selectedRecordTypes.insert(type)
                } else {
                    selectedRecordTypes.remove(type)
                }
            }
        )
    }
}
