import Foundation

/// 导出内容选择
struct ExportSelection {
    /// 学生总表可选的内置列（固定顺序；recordCount/createdAt 为附加元数据列）
    static let builtinExportColumns: [(key: String, title: String)] = [
        ("name", "姓名"), ("studentNumber", "学号"), ("boarding", "是否住宿"),
        ("phone", "联系电话"), ("boardingAddress", "住宿地址"), ("policeStation", "对应派出所"),
        ("recordCount", "关爱记录数"), ("createdAt", "建档时间"),
    ]

    var includeRoster = true
    var includeGuardians = true
    var includeRecords = true
    /// 学生总表中包含的自定义字段
    var customFieldIDs: Set<UUID> = []
    /// 监护人扁平列组数（0 = 不导出监护人列；每组：监护人N姓名/关系/电话）
    var guardianSlots: Int = 1
    /// 导出的记录类别；空集合 = 不导出任何记录
    var recordTypes: Set<String> = []
    /// 导出的数据表（记录表/自定义表，每张一个工作表）；空集合 = 不导出任何表
    var tableIDs: Set<UUID> = []
    /// 学生总表包含的内置列（key 见 builtinExportColumns）；空集合 = 不导出内置列
    var builtinColumns: Set<String> = []
    /// 每张数据表包含的字段（表 id → 字段 id 集）；某张表不在字典里 = 整表全字段，空集合 = 该表不导出
    var tableFields: [UUID: Set<UUID>] = [:]

    static func all(data: ProjectData) -> ExportSelection {
        var types = Set(data.recordTypes)
        for s in data.students {
            for r in s.records { types.insert(r.type) }
        }
        return ExportSelection(customFieldIDs: Set(data.fieldDefinitions.map { $0.id }),
                               recordTypes: types,
                               tableIDs: Set(data.tables.map { $0.id }),
                               builtinColumns: Set(builtinExportColumns.map { $0.key }),
                               tableFields: Dictionary(uniqueKeysWithValues:
                                   data.tables.map { ($0.id, Set($0.fields.map { $0.id })) }))
    }

    var includesAnything: Bool {
        includeRoster || includeGuardians || includeRecords || !tableIDs.isEmpty
    }
}

/// 按选择把项目数据导出为 .xlsx（每个勾选的内容一个工作表）
enum ExcelExporter {

    /// studentsOverride：视图筛选+排序后的学生列表；nil = 全部学生
    /// 学生总表表头/行的监护人列（数据库扁平化：监护人N姓名/关系/电话）
    private static func guardianHeader(slots: Int) -> [XLSX.Cell] {
        let slotCount = max(1, min(slots, 5))
        var cells: [XLSX.Cell] = []
        for slot in 1...slotCount {
            for part in GuardianPart.allCases {
                cells.append(.text("监护人\(slot)\(part.title)"))
            }
        }
        return cells
    }

    private static func guardianRow(of student: Student, slots: Int) -> [XLSX.Cell] {
        let slotCount = max(1, min(slots, 5))
        var cells: [XLSX.Cell] = []
        for slot in 1...slotCount {
            let g = slot <= student.guardians.count ? student.guardians[slot - 1] : nil
            cells.append(.text(g?.name ?? ""))
            cells.append(.text(g?.relation ?? ""))
            cells.append(.text(g?.phone ?? ""))
        }
        return cells
    }

    static func exportAll(data: ProjectData, to url: URL, selection selectionOverride: ExportSelection? = nil,
                          students studentsOverride: [Student]? = nil) throws {
        let selection = selectionOverride ?? ExportSelection.all(data: data)
        let students = studentsOverride ?? data.students.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let selectedFields = data.fieldDefinitions.filter { selection.customFieldIDs.contains($0.id) }
        let guardianSlots = selection.guardianSlots

        var sheets: [(name: String, rows: [[XLSX.Cell]])] = []

        if selection.includeRoster {
            // 列序保持既有布局：基础内置列 → 监护人列 → 自定义字段 → 关爱记录数/建档时间
            let builtins = ExportSelection.builtinExportColumns
            let selectedBasic = builtins.prefix(6).filter { selection.builtinColumns.contains($0.key) }
            let selectedTrailing = builtins.dropFirst(6).filter { selection.builtinColumns.contains($0.key) }
            let includeGuardianColumns = guardianSlots > 0

            func builtinCell(_ column: (key: String, title: String), of student: Student) -> XLSX.Cell {
                switch column.key {
                case "name": return .text(student.name)
                case "studentNumber": return .text(student.studentNumber)
                case "boarding": return .text(student.isBoarding ? "住宿" : "走读")
                case "phone": return .text(student.phone)
                case "boardingAddress": return .text(student.boardingAddress)
                case "policeStation": return .text(student.policeStation)
                case "recordCount": return .number(Double(student.records.count))
                default: return .text(Fmt.dateTime.string(from: student.createdAt))
                }
            }

            var header: [XLSX.Cell] = selectedBasic.map { .text($0.title) }
            if includeGuardianColumns {
                header += guardianHeader(slots: guardianSlots)
            }
            header += selectedFields.map { .text($0.name) }
            header += selectedTrailing.map { .text($0.title) }

            // 一列都没勾选时跳过总表工作表；若整体没有任何内容，尾部统一报错
            if !header.isEmpty {
                var rosterRows: [[XLSX.Cell]] = [header]
                for student in students {
                    var row: [XLSX.Cell] = selectedBasic.map { builtinCell($0, of: student) }
                    if includeGuardianColumns {
                        row += guardianRow(of: student, slots: guardianSlots)
                    }
                    for field in selectedFields {
                        row.append(.text(student.customValues[field.id.uuidString]?.displayText ?? ""))
                    }
                    row += selectedTrailing.map { builtinCell($0, of: student) }
                    rosterRows.append(row)
                }
                sheets.append((name: "学生总表", rows: rosterRows))
            }
        }

        if selection.includeGuardians {
            var guardianRows: [[XLSX.Cell]] = [[
                .text("学生"), .text("学号"), .text("关系"), .text("姓名"), .text("电话")
            ]]
            for student in students {
                for guardian in student.guardians where !guardian.isEmpty {
                    guardianRows.append([
                        .text(student.name), .text(student.studentNumber),
                        .text(guardian.relation), .text(guardian.name), .text(guardian.phone)
                    ])
                }
            }
            sheets.append((name: "监护人明细", rows: guardianRows))
        }

        if selection.includeRecords, !selection.recordTypes.isEmpty {
            var recordRows: [[XLSX.Cell]] = [[
                .text("日期"), .text("学生"), .text("学号"), .text("类别"), .text("内容")
            ]]
            for student in students {
                for record in student.records.sorted(by: { $0.date > $1.date })
                where selection.recordTypes.contains(record.type) {
                    recordRows.append([
                        .text(Fmt.date.string(from: record.date)),
                        .text(student.name), .text(student.studentNumber),
                        .text(record.type), .text(record.content)
                    ])
                }
            }
            sheets.append((name: "记录明细", rows: recordRows))
        }

        // 数据表（记录表/自定义表）：每张表一个工作表，按当前字段顺序导出。
        // tableFields 指定了字段集则只导所选字段（空集 = 跳过该表）；未指定 = 全字段。
        // 关联学生列显示学生姓名（顿号分隔），附件列导出为空（文件在项目包内）。
        let studentNames = Dictionary(uniqueKeysWithValues: data.students.map { ($0.id, $0.name) })
        for table in data.tables where selection.tableIDs.contains(table.id) {
            let fields: [CustomField]
            if let selected = selection.tableFields[table.id] {
                fields = table.orderedFields.filter { selected.contains($0.id) }
            } else {
                fields = table.orderedFields
            }
            guard !fields.isEmpty else { continue }
            var rows: [[XLSX.Cell]] = [fields.map { .text($0.name) }]
            for row in table.rows {
                rows.append(fields.map { field in
                    guard let value = row.values[field.id.uuidString] else { return .text("") }
                    if case .link(let ids) = value {
                        return .text(ids.compactMap { studentNames[$0] ?? "（未知学生）" }
                            .joined(separator: "、"))
                    }
                    return .text(value.displayText)
                })
            }
            sheets.append((name: table.name, rows: rows))
        }

        guard !sheets.isEmpty else {
            throw ProjectError.cannotOpen("没有选择任何要导出的内容。")
        }
        try XLSX.write(sheets: sheets, to: url)
    }
}
