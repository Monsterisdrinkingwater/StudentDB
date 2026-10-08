import Foundation

// MARK: - 通用表导入（记录表 / 自定义表）
//
// 与 StudentImporter（学生表）平行的导入引擎：
// 列映射（含“新建字段”）→ 类型转换（关联学生按姓名/学号匹配）→ 按关键字段查重
// → 跳过 / 覆盖已有行 / 保留两条。

/// 通用表导入的列映射目标
enum TableImportTarget: Hashable {
    case ignore
    case field(id: UUID)
    case newField
}

struct TableImportReport {
    var imported = 0
    var updated = 0
    var skipped: [String] = []

    var summary: String {
        var lines: [String] = []
        if imported > 0 { lines.append("新增 \(imported) 行") }
        if updated > 0 { lines.append("更新 \(updated) 行") }
        if imported == 0 && updated == 0 { lines.append("没有导入任何行") }
        return lines.joined(separator: "，")
    }
}

@MainActor
enum TableImporter {

    // MARK: 列映射

    /// 按列标题自动猜测映射：与字段名完全一致（忽略首尾空白、英文大小写）才命中
    static func autoGuessMapping(header: [String], fields: [CustomField]) -> [Int: TableImportTarget] {
        var mapping: [Int: TableImportTarget] = [:]
        let lowered = fields.map { ($0.id, $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        for (index, raw) in header.enumerated() {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            if let hit = lowered.first(where: { $0.1 == title.lowercased() }) {
                mapping[index] = .field(id: hit.0)
            }
        }
        return mapping
    }

    /// “新建字段”列在字段创建后，把映射指向新字段；找不到（如重名被跳过）退回“不导入”
    static func resolveNewFieldMappings(_ mapping: [Int: TableImportTarget],
                                        header: [String], fields: [CustomField]) -> [Int: TableImportTarget] {
        var resolved = mapping
        for (column, target) in mapping {
            guard case .newField = target, header.indices.contains(column) else { continue }
            let title = header[column].trimmingCharacters(in: .whitespacesAndNewlines)
            if let field = fields.first(where: { $0.name == title }) {
                resolved[column] = .field(id: field.id)
            } else {
                resolved[column] = .ignore
            }
        }
        return resolved
    }

    /// 把映射为“新建字段”的列创建为表内字段（整列都是数字时建为数字字段）
    static func createFieldsIfNeeded(grid: [[String]], header: [String], headerRowIndex: Int,
                                     mapping: [Int: TableImportTarget],
                                     store: ProjectStore, tableID: UUID) {
        guard let table = store.data.table(id: tableID) else { return }
        let existingNames = Set(table.fields.map { $0.name })
        for (column, target) in mapping {
            guard case .newField = target else { continue }
            guard header.indices.contains(column) else { continue }
            let name = header[column].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !existingNames.contains(name) else { continue }

            var sawValue = false
            var allNumeric = true
            for row in grid.dropFirst(headerRowIndex + 1) {
                guard row.indices.contains(column) else { continue }
                let value = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                sawValue = true
                if Double(value) == nil { allNumeric = false }
            }
            _ = store.addTableField(tableID: tableID, name: name,
                                    type: sawValue && allNumeric ? .number : .text)
        }
    }

    // MARK: 值转换

    /// 单元格文本 → 字段值。返回值说明：value 为 nil 表示该列此行不写入；
    /// note 非空时为提示信息（如学生不存在、数字解析失败），行照常导入。
    static func convert(text raw: String, field: CustomField,
                        store: ProjectStore, tableID: UUID) -> (value: CustomValue?, note: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, nil) }
        switch field.type {
        case .text, .address:
            return (.text(text), nil)
        case .phone:
            if FieldFormat.isValidPhone(text) { return (.text(text), nil) }
            return (nil, "值「\(text)」不是有效的电话号码，已跳过该值")
        case .idCard:
            if FieldFormat.isValidIDCard(text) { return (.text(text), nil) }
            return (nil, "值「\(text)」不是有效的身份证号（需 18 位含校验码），已跳过该值")
        case .number:
            if let n = Double(text.replacingOccurrences(of: ",", with: "")) {
                return (.number(n), nil)
            }
            return (nil, "值「\(text)」不是数字，已跳过该值")
        case .date, .dateTime:
            if let d = parseDateText(text) {
                return (.date(d), nil)
            }
            return (nil, "值「\(text)」无法识别为日期，已跳过该值")
        case .boolean:
            if let b = parseBoolText(text) {
                return (.boolean(b), nil)
            }
            return (nil, "值「\(text)」无法识别为是/否，已跳过该值")
        case .choice(let options):
            if !options.contains(text) {
                store.appendTableChoiceOptions(tableID: tableID, fieldID: field.id, options: [text])
            }
            return (.text(text), nil)
        case .multiChoice(let options):
            let parts = splitMulti(text)
            guard !parts.isEmpty else { return (nil, nil) }
            let missing = parts.filter { !options.contains($0) }
            if !missing.isEmpty {
                store.appendTableChoiceOptions(tableID: tableID, fieldID: field.id, options: missing)
            }
            return (.text(parts.joined(separator: "、")), nil)
        case .linkStudents:
            let matched = matchStudents(text, store: store)
            if matched.ids.isEmpty {
                return (nil, "「\(text)」未匹配到学生，已跳过该值")
            }
            if !matched.missing.isEmpty {
                return (.link(matched.ids), "「\(matched.missing.joined(separator: "、"))」未匹配到学生，已跳过")
            }
            return (.link(matched.ids), nil)
        case .attachment:
            return (nil, "附件列不能通过导入填写，已跳过该值")
        }
    }

    /// 关联学生列按姓名或学号匹配（顿号/逗号/分号分隔多个）
    static func matchStudents(_ text: String, store: ProjectStore) -> (ids: [UUID], missing: [String]) {
        var ids: [UUID] = []
        var missing: [String] = []
        for part in splitMulti(text) {
            let lower = part.lowercased()
            if let student = store.data.students.first(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower
                    || $0.studentNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower
            }) {
                if !ids.contains(student.id) { ids.append(student.id) }
            } else {
                missing.append(part)
            }
        }
        return (ids, missing)
    }

    /// 多选值分隔：顿号 / 中英文逗号 / 中英文分号
    nonisolated static func splitMulti(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "、,，;；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 布尔值解析：识别不了的返回 nil（不写入），避免把任意文本硬翻成“否”
    nonisolated static func parseBoolText(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if ["是", "有", "住宿", "寄宿", "y", "yes", "true", "1", "✓", "√"].contains(lower) { return true }
        if ["否", "不", "无", "n", "no", "false", "0", "×", "✗"].contains(lower) { return false }
        return nil
    }

    /// 日期解析：Excel 序列号 → 2026年3月14日 → 2026-3-14 / 2026/3/14 / 2026.3.14（可带 10:30 时间）
    nonisolated static func parseDateText(_ text: String) -> Date? {
        if let d = StudentImporter.parseExcelDate(text) { return d }
        if let d = Fmt.date.date(from: text) { return d }
        if let d = Fmt.dateTime.date(from: text) { return d }
        var body = text
        var time = (0, 0)
        if let spaceIndex = body.firstIndex(where: { $0 == " " || $0 == "T" }) {
            let timePart = String(body[body.index(after: spaceIndex)...])
            body = String(body[..<spaceIndex])
            let hm = timePart.split(separator: ":").compactMap { Int($0) }
            if hm.count == 2 { time = (hm[0], hm[1]) }
        }
        let parts = body.split(whereSeparator: { "-/.".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.hour = time.0; comps.minute = time.1
        return Calendar.current.date(from: comps)
    }

    // MARK: 查重键

    /// 行的查重键（nil = 该行没有有效键，永不判重）。
    /// 文件行侧：由单元格文本解析；已有行侧：由存储值归一。两侧算法一致才能对上。
    static func keyText(cellText: String, field: CustomField, store: ProjectStore) -> String? {
        let text = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch field.type {
        case .linkStudents:
            let ids = matchStudents(text, store: store).ids
            guard !ids.isEmpty else { return nil }
            return ids.sorted().map { $0.uuidString }.joined(separator: "|")
        case .number:
            return Double(text.replacingOccurrences(of: ",", with: "")).map { String($0) }
                ?? text.lowercased()
        case .date, .dateTime:
            return parseDateText(text).map { String($0.timeIntervalSince1970) } ?? text.lowercased()
        case .boolean:
            return parseBoolText(text).map { $0 ? "1" : "0" } ?? text.lowercased()
        default:
            return text.lowercased()
        }
    }

    /// 已有行的查重键（与 keyText(cellText:) 归一格式一致）
    nonisolated static func existingKey(value: CustomValue, field: CustomField) -> String? {
        switch (field.type, value) {
        case (.linkStudents, .link(let ids)):
            return ids.sorted().map { $0.uuidString }.joined(separator: "|")
        case (.number, .number(let n)):
            return String(n)
        case (.date, .date(let d)), (.dateTime, .date(let d)):
            return String(d.timeIntervalSince1970)
        case (.boolean, .boolean(let b)):
            return b ? "1" : "0"
        case (_, .text(let s)):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t.lowercased()
        default:
            return nil
        }
    }

    // MARK: 预检与导入

    struct DuplicateRow: Identifiable, Equatable {
        /// 行号（从 1 起、含标题行，与 Excel 行号一致），与 importRows 的编号保持一致
        let rowNumber: Int
        /// 该行关键值展示（如学生姓名或文本值）
        let keyDisplay: String
        var id: Int { rowNumber }
    }

    /// 预检：找出与表中已有行关键字段重复的行（文件内部重复的行不进冲突列表）
    static func detectDuplicateRows(grid: [[String]], headerRowIndex: Int,
                                    mapping: [Int: TableImportTarget], keyField: CustomField,
                                    store: ProjectStore, tableID: UUID) -> [DuplicateRow] {
        guard let table = store.data.table(id: tableID) else { return [] }
        let keyColumn = mapping.first(where: {
            if case .field(let id) = $0.value { return id == keyField.id } else { return false }
        })?.key
        guard let keyColumn else { return [] }
        let existingKeys = Set(table.rows.compactMap {
            $0.values[keyField.id.uuidString].flatMap { existingKey(value: $0, field: keyField) }
        })

        var conflicts: [DuplicateRow] = []
        var seen = Set<String>()
        var rowNumber = headerRowIndex + 1
        for row in grid.dropFirst(headerRowIndex + 1) {
            rowNumber += 1
            let raw = row.indices.contains(keyColumn) ? row[keyColumn] : ""
            guard let key = keyText(cellText: raw, field: keyField, store: store) else { continue }
            if seen.contains(key) { continue }
            seen.insert(key)
            if existingKeys.contains(key) {
                conflicts.append(DuplicateRow(rowNumber: rowNumber,
                                              keyDisplay: raw.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return conflicts
    }

    /// 执行导入。duplicateActions 按行号指定冲突策略；未指定的行走 updateExisting 默认值。
    static func importRows(grid: [[String]], headerRowIndex: Int,
                           mapping: [Int: TableImportTarget], keyField: CustomField?,
                           store: ProjectStore, tableID: UUID, updateExisting: Bool,
                           duplicateActions: [Int: DuplicatePolicy] = [:]) -> TableImportReport {
        var report = TableImportReport()
        guard let table = store.data.table(id: tableID) else { return report }
        let fieldsByID = Dictionary(uniqueKeysWithValues: table.fields.map { ($0.id, $0) })

        // 关键字段对应的列（没有映射关键字的行不会被查重，全部视为新行）
        let keyColumn: Int?
        if let keyField, let column = mapping.first(where: {
            if case .field(let id) = $0.value { return id == keyField.id } else { return false }
        })?.key {
            keyColumn = column
        } else {
            keyColumn = nil
        }
        let existingByKey: [String: DBRow]
        if let keyField {
            existingByKey = Dictionary(
                table.rows.compactMap { row in
                    guard let key = row.values[keyField.id.uuidString]
                        .flatMap({ existingKey(value: $0, field: keyField) }) else { return nil }
                    return (key, row)
                }, uniquingKeysWith: { first, _ in first })
        } else {
            existingByKey = [:]
        }

        var seenFileKeys = Set<String>()
        var rowNumber = headerRowIndex + 1

        for row in grid.dropFirst(headerRowIndex + 1) {
            rowNumber += 1
            var values: [UUID: CustomValue] = [:]
            var notes: [String] = []
            var anyText = false

            for (column, target) in mapping {
                guard case .field(let fieldID) = target, let field = fieldsByID[fieldID] else { continue }
                let raw = row.indices.contains(column) ? row[column] : ""
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { anyText = true }
                let result = convert(text: raw, field: field, store: store, tableID: tableID)
                if let note = result.note {
                    notes.append("「\(field.name)」\(note)")
                }
                if let value = result.value {
                    values[fieldID] = value
                }
            }
            guard anyText else { continue }
            for note in notes {
                report.skipped.append("第 \(rowNumber) 行：\(note)")
            }

            // 关键字查重：文件内重复直接跳过；与已有行重复按策略处理
            if let keyField, let keyColumn {
                let raw = row.indices.contains(keyColumn) ? row[keyColumn] : ""
                if let key = keyText(cellText: raw, field: keyField, store: store) {
                    if seenFileKeys.contains(key) {
                        report.skipped.append("第 \(rowNumber) 行：关键字「\(raw.trimmingCharacters(in: .whitespacesAndNewlines))」在文件中重复")
                        continue
                    }
                    seenFileKeys.insert(key)
                    if let existing = existingByKey[key] {
                        let keyDisplay = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        switch duplicateActions[rowNumber] ?? (updateExisting ? .overwrite : .skip) {
                        case .overwrite:
                            var updated = existing
                            for (fieldID, value) in values {
                                updated.values[fieldID.uuidString] = value
                            }
                            store.updateRow(tableID: tableID, row: updated)
                            report.updated += 1
                        case .keepBoth:
                            _ = store.addRow(tableID: tableID,
                                             values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value) }))
                            report.imported += 1
                        case .skip:
                            report.skipped.append("第 \(rowNumber) 行：关键字「\(keyDisplay)」已存在")
                        }
                        continue
                    }
                }
            }

            _ = store.addRow(tableID: tableID,
                             values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value) }))
            report.imported += 1
        }
        return report
    }
}
