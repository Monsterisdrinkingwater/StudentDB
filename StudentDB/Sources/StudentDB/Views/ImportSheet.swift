import SwiftUI

struct ImportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Excel / CSV 导入：解析 → 列映射 → 导入 → 报告
struct ImportSheet: View {
    @ObservedObject var store: ProjectStore
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var loadError: String?
    @State private var isLoaded = false
    @State private var grid: [[String]] = []
    @State private var hasHeader = true
    @State private var mapping: [Int: ImportTarget] = [:]
    @State private var updateExisting = false
    @State private var report: ImportReport?
    /// 与已有学生重复的行（导入前预检），让用户逐行选择覆盖或保留
    @State private var conflicts: [StudentImporter.DuplicateRow] = []
    @State private var duplicateChoices: [Int: DuplicatePolicy] = [:]
    @State private var finalMapping: [Int: ImportTarget] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if let loadError {
                errorView(loadError)
            } else if let report {
                reportView(report)
            } else if !conflicts.isEmpty {
                conflictView
            } else if isLoaded {
                mappingView
            } else {
                ProgressView("正在读取文件…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .resizableSheet(minWidth: 560, minHeight: 460, idealWidth: 620, idealHeight: 560)
        .onAppear(perform: load)
    }

    // MARK: - 读取

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            if fileURL.pathExtension.lowercased() == "csv" {
                grid = CSVParser.parse(data: data)
            } else {
                grid = try XLSX.readFirstSheet(from: fileURL).rows
            }
            mapping = StudentImporter.autoGuessMapping(header: headerRow, fields: store.data.fieldDefinitions)
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

    // MARK: - 列映射

    private var mappingView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("导入学生 — \(fileURL.lastPathComponent)")
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
                            mapping = StudentImporter.autoGuessMapping(
                                header: headerRow, fields: store.data.fieldDefinitions
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
                                Text("不导入").tag(ImportTarget.ignore)
                                Divider()
                                if !store.data.deletedBuiltinFields.contains("name") {
                                    Text("姓名").tag(ImportTarget.name)
                                }
                                if !store.data.deletedBuiltinFields.contains("studentNumber") {
                                    Text("学号").tag(ImportTarget.studentNumber)
                                }
                                if !store.data.deletedBuiltinFields.contains("boarding") {
                                    Text("是否住宿").tag(ImportTarget.isBoarding)
                                }
                                if !store.data.deletedBuiltinFields.contains("phone") {
                                    Text("联系电话").tag(ImportTarget.phone)
                                }
                                if !store.data.deletedBuiltinFields.contains("boardingAddress") {
                                    Text("住宿地址").tag(ImportTarget.boardingAddress)
                                }
                                if !store.data.deletedBuiltinFields.contains("policeStation") {
                                    Text("对应派出所").tag(ImportTarget.policeStation)
                                }
                                Divider()
                                ForEach(0..<2, id: \.self) { slot in
                                    ForEach(ImportTarget.GuardianPart.allCases, id: \.self) { part in
                                        Text("监护人\(slot + 1)\(part.displayName)")
                                            .tag(ImportTarget.guardian(slot: slot, part: part))
                                    }
                                }
                                Divider()
                                ForEach(store.data.fieldDefinitions) { field in
                                    Text("字段：\(field.name)").tag(ImportTarget.customField(id: field.id))
                                }
                                Text("＋ 新建字段「\(columnTitle(column))」")
                                    .tag(ImportTarget.newField)
                            }
                            .labelsHidden()
                            .frame(width: 230)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            Divider()

            HStack {
                Toggle("学号相同时更新已有学生", isOn: $updateExisting)
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

    private func binding(forColumn column: Int) -> Binding<ImportTarget> {
        Binding(
            get: { mapping[column] ?? .ignore },
            set: { mapping[column] = $0 }
        )
    }

    // MARK: - 执行导入

    private func runImport() {
        StudentImporter.createFieldsIfNeeded(
            grid: grid, header: headerRow, headerRowIndex: hasHeader ? 0 : -1,
            mapping: mapping, store: store
        )
        // 字段创建后把「新建字段」映射指向新字段，保证列数据写入学生
        let resolved = StudentImporter.resolveNewFieldMappings(
            mapping, header: hasHeader ? headerRow : [], fields: store.data.fieldDefinitions
        )
        finalMapping = resolved

        // 预检与已有学生重复的行，让用户选择覆盖或保留
        conflicts = StudentImporter.detectDuplicateRows(
            grid: grid, headerRowIndex: hasHeader ? 0 : -1, mapping: resolved, store: store
        )
        if conflicts.isEmpty {
            executeImport(duplicateActions: [:])
        } else {
            let defaultPolicy: DuplicatePolicy = updateExisting ? .overwrite : .skip
            duplicateChoices = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.rowNumber, defaultPolicy) })
        }
    }

    private func executeImport(duplicateActions: [Int: DuplicatePolicy]) {
        report = StudentImporter.importRows(
            grid: grid, headerRowIndex: hasHeader ? 0 : -1,
            mapping: finalMapping, store: store, updateExisting: updateExisting,
            duplicateActions: duplicateActions
        )
    }

    // MARK: - 重复行选择

    private var conflictView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("发现 \(conflicts.count) 行与已有学生重复")
                    .font(.headline)
                Text("请为每一行选择处理方式，然后确认导入。")
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
                                Text("第 \(row.rowNumber) 行 · \(row.name)")
                                    .font(.callout.weight(.medium))
                                Text("与已有的「\(row.keyDescription)」重复")
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

    private func reportView(_ report: ImportReport) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
                .padding(.top, 40)
            Text("导入完成")
                .font(.title3.weight(.semibold))
            Text(report.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            if !report.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已跳过 \(report.skipped.count) 行：")
                        .font(.callout.weight(.medium))
                    ForEach(report.skipped, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
}
