import Foundation

/// 导出学生总表 CSV（UTF-8 带 BOM，Excel 可直接打开）
enum CSVExporter {

    /// 监护人扁平列表头：监护人N姓名/关系/电话
    private static func guardianHeader(slots: Int) -> [String] {
        let slotCount = max(1, min(slots, 5))
        var cells: [String] = []
        for slot in 1...slotCount {
            for part in GuardianPart.allCases {
                cells.append("监护人\(slot)\(part.title)")
            }
        }
        return cells
    }

    private static func guardianRow(of s: Student, slots: Int) -> [String] {
        let slotCount = max(1, min(slots, 5))
        var cells: [String] = []
        for slot in 1...slotCount {
            let g = slot <= s.guardians.count ? s.guardians[slot - 1] : nil
            cells.append(g?.name ?? "")
            cells.append(g?.relation ?? "")
            cells.append(g?.phone ?? "")
        }
        return cells
    }

    /// studentsOverride：视图筛选+排序后的学生列表；nil = 全部学生。
    /// builtinColumns 为 nil 时导出全部内置列；guardianSlots 传 0 不导出监护人列。
    static func exportCSV(data: ProjectData, selectedFieldIDs: Set<UUID>? = nil,
                          students studentsOverride: [Student]? = nil,
                          guardianSlots: Int = 1,
                          builtinColumns: Set<String>? = nil) -> String {
        var rows: [[String]] = []

        let fields: [CustomField]
        if let selectedFieldIDs {
            fields = data.fieldDefinitions.filter { selectedFieldIDs.contains($0.id) }
        } else {
            fields = data.fieldDefinitions
        }
        let builtins = ExportSelection.builtinExportColumns
        let selectedBasic: [(key: String, title: String)]
        let selectedTrailing: [(key: String, title: String)]
        if let builtinColumns {
            selectedBasic = builtins.prefix(6).filter { builtinColumns.contains($0.key) }
            selectedTrailing = builtins.dropFirst(6).filter { builtinColumns.contains($0.key) }
        } else {
            selectedBasic = Array(builtins.prefix(6))
            selectedTrailing = Array(builtins.dropFirst(6))
        }
        let includeGuardianColumns = guardianSlots > 0

        func builtinText(_ column: (key: String, title: String), of s: Student) -> String {
            switch column.key {
            case "name": return s.name
            case "studentNumber": return s.studentNumber
            case "boarding": return s.isBoarding ? "住宿" : "走读"
            case "phone": return s.phone
            case "boardingAddress": return s.boardingAddress
            case "policeStation": return s.policeStation
            case "recordCount": return String(s.records.count)
            default: return Fmt.csvDateTime.string(from: s.createdAt)
            }
        }

        var header = selectedBasic.map { $0.title }
        if includeGuardianColumns {
            header += guardianHeader(slots: guardianSlots)
        }
        header += fields.map { $0.name }
        header += selectedTrailing.map { $0.title }
        rows.append(header)

        let students = studentsOverride ?? data.students.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for s in students {
            var row = selectedBasic.map { builtinText($0, of: s) }
            if includeGuardianColumns {
                row += guardianRow(of: s, slots: guardianSlots)
            }
            for field in fields {
                if let value = s.customValues[field.id.uuidString] {
                    row.append(value.displayText)
                } else {
                    row.append("")
                }
            }
            row += selectedTrailing.map { builtinText($0, of: s) }
            rows.append(row)
        }

        var text = rows
            .map { $0.map { escape($0) }.joined(separator: ",") }
            .joined(separator: "\r\n")
        text += "\r\n"
        return text
    }

    static func write(data: ProjectData, to url: URL, selectedFieldIDs: Set<UUID>? = nil,
                      students: [Student]? = nil, guardianSlots: Int = 1,
                      builtinColumns: Set<String>? = nil) throws {
        let csv = exportCSV(data: data, selectedFieldIDs: selectedFieldIDs,
                            students: students, guardianSlots: guardianSlots,
                            builtinColumns: builtinColumns)
        var body = Data([0xEF, 0xBB, 0xBF]) // BOM，保证 Excel 识别中文
        body.append(Data(csv.utf8))
        try body.write(to: url, options: [.atomic])
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}
