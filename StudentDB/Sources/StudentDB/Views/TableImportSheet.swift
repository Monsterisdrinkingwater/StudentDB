import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 通用表（记录表/自定义表）的 Excel / CSV 导入：列映射 → 查重选择 → 导入 → 报告
struct TableImportSheet: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var loadError: String?
    @State private var isLoaded = false
    @State private var grid: [[String]] = []
    @State private var hasHeader = true
    @State private var mapping: [Int: TableImportTarget] = [:]
    @State private var keyFieldID: UUID?
    @State private var updateExisting = false
    @State private var report: TableImportReport?
    @State private var conflicts: [TableImporter.DuplicateRow] = []
    @State private var duplicateChoices: [Int: DuplicatePolicy] = [:]
    @State private var finalMapping: [Int: TableImportTarget] = [:]
    @State private var finalKeyFieldID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let loadError {
                errorView(loadError)
            } else if report != nil {
                reportView
            } else if !conflicts.isEmpty {
                conflictView
            } else if isLoaded {
                mappingView
            } else {
                ProgressView("正在读取文件…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .resizableSheet(minWidth: 620, minHeight: 480, idealWidth: 680, idealHeight: 580)
        .onAppear(perform: load)
    }

    // MARK: - 读取

    private func load() {
        do {
            if fileURL.pathExtension.lowercased() == "csv" {
                grid = CSVParser.parse(data: try Data(contentsOf: fileURL))
            } else {
                grid = try XLSX.readFirstSheet(from: fileURL).rows
            }
            mapping = TableImporter.autoGuessMapping(header: headerRow, fields: table.fields)
            keyFieldID = (table.linkField ?? table.fields.first)?.id
            isLoaded = !grid.isEmpty
            if grid.isEmpty {
                loadError = "文件里没有数据。"
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var headerRow: [String] {
        guard hasHeader, let first = grid.first else { return [] }
        return first
    }

    private var dataRows: [[String]] {
        grid.dropFirst(hasHeader ? 1 : 0).map { $0 }
    }

    private func columnTitle(_ index: Int) -> String {
        if hasHeader, let first = grid.first, first.indices.contains(index), !first[index].isEmpty {
            return first[index]
        }
        return "第 \(index + 1) 列"
    }

    private func columnSample(_ index: Int) -> String {
        for row in dataRows where row.indices.contains(index) && !row[index].isEmpty {
            return row[index]
        }
        return ""
    }

    private func fieldName(_ id: UUID?) -> String {
        guard let id, let field = table.fields.first(where: { $0.id == id }) else { return "（无）" }
        return field.name
    }

    private var currentFields: [CustomField] {
        store.data.table(id: table.id)?.fields ?? table.fields
    }

    // MARK: - 列映射

    private var mappingView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("导入到「\(table.name)」 — \(fileURL.lastPathComponent)")
                    .font(.headline)
                Text("共 \(dataRows.count) 行数据。请确认每列对应的字段，不需要的列选“不导入”。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    Toggle("首行是列标题", isOn: $hasHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: hasHeader) { _ in
                            mapping = TableImporter.autoGuessMapping(
                                header: headerRow, fields: currentFields
                            )
                        }

                    ForEach(grid.first?.indices ?? 0..<0, id: \.self) { column in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(columnTitle(column))
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                let sample = columnSample(column)
                                Text(sample.isEmpty ? "（空）" : "如：\(sample)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(width: 190, alignment: .leading)

                            Picker("", selection: binding(forColumn: column)) {
                                Text("不导入").tag(TableImportTarget.ignore)
                                Divider()
                                ForEach(currentFields) { field in
                                    Text("\(field.name)（\(field.type.displayName)）")
                                        .tag(TableImportTarget.field(id: field.id))
                                }
                                Text("＋ 新建字段「\(columnTitle(column))」")
                                    .tag(TableImportTarget.newField)
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            Divider()

            HStack(spacing: 12) {
                Picker("查重字段", selection: $keyFieldID) {
                    ForEach(currentFields) { field in
                        Text(field.name).tag(Optional(field.id))
                    }
                }
                .frame(width: 240)
                .help("该字段值相同的行视为同一条记录，导入时可跳过或覆盖")
                Toggle("关键字段相同时更新已有行", isOn: $updateExisting)
                    .font(.callout)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入 \(dataRows.count) 行", action: runImport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func binding(forColumn column: Int) -> Binding<TableImportTarget> {
        Binding(
            get: { mapping[column] ?? .ignore },
            set: { mapping[column] = $0 }
        )
    }

    // MARK: - 执行导入

    private func runImport() {
        TableImporter.createFieldsIfNeeded(
            grid: grid, header: headerRow, headerRowIndex: hasHeader ? 0 : -1,
            mapping: mapping, store: store, tableID: table.id
        )
        let fields = currentFields
        finalMapping = TableImporter.resolveNewFieldMappings(
            mapping, header: hasHeader ? headerRow : [], fields: fields
        )
        finalKeyFieldID = keyFieldID
        if let keyID = keyFieldID, let keyField = fields.first(where: { $0.id == keyID }) {
            conflicts = TableImporter.detectDuplicateRows(
                grid: grid, headerRowIndex: hasHeader ? 0 : -1,
                mapping: finalMapping, keyField: keyField, store: store, tableID: table.id
            )
        } else {
            conflicts = []
        }
        if conflicts.isEmpty {
            executeImport(duplicateActions: [:])
        } else {
            let defaultPolicy: DuplicatePolicy = updateExisting ? .overwrite : .skip
            duplicateChoices = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.rowNumber, defaultPolicy) })
        }
    }

    private func executeImport(duplicateActions: [Int: DuplicatePolicy]) {
        let fields = currentFields
        let keyField = finalKeyFieldID.flatMap { keyID in fields.first(where: { $0.id == keyID }) }
        report = TableImporter.importRows(
            grid: grid, headerRowIndex: hasHeader ? 0 : -1,
            mapping: finalMapping, keyField: keyField,
            store: store, tableID: table.id, updateExisting: updateExisting,
            duplicateActions: duplicateActions
        )
    }

    // MARK: - 重复行选择

    private var conflictView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("发现 \(conflicts.count) 行与表内已有记录重复")
                    .font(.headline)
                Text("查重字段：\(fieldName(finalKeyFieldID))。请为每一行选择处理方式，然后确认导入。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack(spacing: 10) {
                Text("全部设为")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach([
                    ("跳过", DuplicatePolicy.skip),
                    ("覆盖已有", DuplicatePolicy.overwrite),
                    ("保留两条", DuplicatePolicy.keepBoth)
                ], id: \.1) { title, policy in
                    Button(title) {
                        for row in conflicts {
                            duplicateChoices[row.rowNumber] = policy
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(conflicts) { row in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(row.rowNumber) 行")
                                    .font(.callout.weight(.medium))
                                Text("关键字段值：「\(row.keyDisplay)」")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: policyBinding(forRow: row.rowNumber)) {
                                Text("跳过").tag(DuplicatePolicy.skip)
                                Text("覆盖已有").tag(DuplicatePolicy.overwrite)
                                Text("保留两条").tag(DuplicatePolicy.keepBoth)
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            Divider()

            HStack {
                Button("返回修改映射") {
                    conflicts = []
                    duplicateChoices = [:]
                }
                Spacer()
                Button("确认导入") {
                    executeImport(duplicateActions: duplicateChoices)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func policyBinding(forRow rowNumber: Int) -> Binding<DuplicatePolicy> {
        Binding(
            get: { duplicateChoices[rowNumber] ?? .skip },
            set: { duplicateChoices[rowNumber] = $0 }
        )
    }

    // MARK: - 结果与错误

    private var reportView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
                .padding(.top, 40)
            Text("导入完成")
                .font(.title3.weight(.semibold))
            Text(report?.summary ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let skipped = report?.skipped, !skipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("提示（\(skipped.count) 条）：")
                        .font(.callout.weight(.medium))
                    ForEach(skipped.prefix(30), id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if skipped.count > 30 {
                        Text("… 以及另外 \(skipped.count - 30) 条")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
            }

            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .padding(.top, 40)
            Text("无法读取文件")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
            Button("好") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 文件选择

    /// 通用表导入的文件选择面板（xlsx / csv）
    @MainActor
    static func promptFile(tableName: String) -> URL? {
        let xlsx = UTType(filenameExtension: "xlsx") ?? .data
        let panel = NSOpenPanel()
        panel.title = "导入到「\(tableName)」"
        panel.message = "支持 .xlsx（Excel 工作簿）和 .csv 文件，第一行应为列标题"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [xlsx, .commaSeparatedText]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
