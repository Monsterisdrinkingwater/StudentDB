import Foundation
import CoreFoundation

// MARK: - 导入映射定义

enum ImportTarget: Hashable {
    case ignore
    case name
    case studentNumber
    case isBoarding
    case phone
    case boardingAddress
    case policeStation
    case guardian(slot: Int, part: GuardianPart)
    case customField(id: UUID)
    case newField

    enum GuardianPart: String, CaseIterable, Hashable {
        case name
        case relation
        case phone

        var displayName: String {
            switch self {
            case .name: return "姓名"
            case .relation: return "关系"
            case .phone: return "电话"
            }
        }
    }

    var displayName: String {
        switch self {
        case .ignore: return "不导入"
        case .name: return "姓名"
        case .studentNumber: return "学号"
        case .isBoarding: return "是否住宿"
        case .phone: return "联系电话"
        case .boardingAddress: return "住宿地址"
        case .policeStation: return "对应派出所"
        case .guardian(let slot, let part):
            return "监护人\(slot + 1)\(part.displayName)"
        case .customField(let id):
            return "字段"
        case .newField:
            return "新建字段"
        }
    }
}

struct ImportReport {
    var imported = 0
    var updated = 0
    var skipped: [String] = []

    var summary: String {
        var lines: [String] = []
        if imported > 0 { lines.append("新增 \(imported) 名学生") }
        if updated > 0 { lines.append("更新 \(updated) 名学生") }
        if imported == 0 && updated == 0 { lines.append("没有导入任何学生") }
        return lines.joined(separator: "，")
    }
}

/// 与已有学生重复时的处理策略
enum DuplicatePolicy: Hashable {
    case skip        // 跳过该行
    case overwrite   // 覆盖已有学生的数据
    case keepBoth    // 同时保留（照常新增一条）
}

// MARK: - 导入逻辑

@MainActor
enum StudentImporter {

    /// 根据列标题自动猜测映射
    static func autoGuessMapping(header: [String], fields: [CustomField]) -> [Int: ImportTarget] {
        var mapping: [Int: ImportTarget] = [:]
        for (index, raw) in header.enumerated() {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let lower = title.lowercased()

            func has(_ keywords: [String]) -> Bool {
                keywords.contains { lower.contains($0) }
            }

            let target: ImportTarget?
            if title == "姓名" || title == "学生姓名" || lower == "name" {
                target = .name
            } else if has(["学号", "学籍号"]) || lower == "no" || lower == "id" {
                target = .studentNumber
            } else if has(["住宿", "寄宿"]) && !has(["地址"]) {
                target = .isBoarding
            } else if has(["电话", "手机", "联系方式"]) && !has(["家长", "监护"]) {
                target = .phone
            } else if has(["地址"]) {
                target = .boardingAddress
            } else if has(["派出所"]) {
                target = .policeStation
            } else if has(["家长", "监护"]) {
                let slot = has(["2", "二"]) ? 1 : 0
                if has(["电话", "手机", "联系"]) {
                    target = .guardian(slot: slot, part: .phone)
                } else if has(["关系", "称谓"]) {
                    target = .guardian(slot: slot, part: .relation)
                } else {
                    target = .guardian(slot: slot, part: .name)
                }
            } else if let field = fields.first(where: { $0.name == title }) {
                target = .customField(id: field.id)
            } else {
                target = nil
            }
            if let target {
                mapping[index] = target
            }
        }
        return mapping
    }

    /// “新建字段”列在字段创建后，把映射指向新字段，使数据得以写入。
    /// 找不到对应字段（如重名被跳过）时退回“不导入”。
    static func resolveNewFieldMappings(_ mapping: [Int: ImportTarget],
                                        header: [String], fields: [CustomField]) -> [Int: ImportTarget] {
        var resolved = mapping
        for (column, target) in mapping {
            guard case .newField = target, header.indices.contains(column) else { continue }
            let title = header[column].trimmingCharacters(in: .whitespacesAndNewlines)
            if let field = fields.first(where: { $0.name == title }) {
                resolved[column] = .customField(id: field.id)
            } else {
                resolved[column] = .ignore
            }
        }
        return resolved
    }

    /// 把映射为“新建字段”的列创建为自定义字段（整列都是数字时建为数字字段）
    static func createFieldsIfNeeded(grid: [[String]], header: [String], headerRowIndex: Int,
                                     mapping: [Int: ImportTarget], store: ProjectStore) {
        let existingNames = Set(store.data.fieldDefinitions.map { $0.name })
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
            store.addField(name: name, type: sawValue && allNumeric ? .number : .text)
        }
    }

    /// 执行导入，返回报告。
    /// duplicateActions：按行号指定与已有学生重复时的处理策略；未指定的行走 updateExisting 默认值。
    static func importRows(grid: [[String]], headerRowIndex: Int, mapping: [Int: ImportTarget],
                           store: ProjectStore, updateExisting: Bool,
                           duplicateActions: [Int: DuplicatePolicy] = [:]) -> ImportReport {
        var report = ImportReport()
        let fields = store.data.fieldDefinitions
        var seenNumbers = Set<String>()
        var seenNames = Set<String>()
        var rowNumber = headerRowIndex + 1

        for row in grid.dropFirst(headerRowIndex + 1) {
            rowNumber += 1

            var values: [Int: String] = [:]
            for (column, target) in mapping where target != .ignore {
                var text = ""
                if row.indices.contains(column) { text = row[column] }
                values[column] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            func mappedValue(_ target: ImportTarget) -> String {
                values.first(where: { mapping[$0.key] == target })?.value ?? ""
            }

            let name = mappedValue(.name)
            let number = mappedValue(.studentNumber)

            if name.isEmpty && number.isEmpty { continue }
            if name.isEmpty {
                report.skipped.append("第 \(rowNumber) 行：缺少姓名")
                continue
            }
            let importedPhone = mappedValue(.phone)
            if !importedPhone.isEmpty && !FieldFormat.isValidPhone(importedPhone) {
                report.skipped.append("第 \(rowNumber) 行：电话「\(importedPhone)」格式不正确")
                continue
            }
            // 文件内查重：有学号按学号，无学号按姓名（姓名是唯一必填项）
            let nameKey = name.lowercased()
            if !number.isEmpty {
                let numberKey = number.lowercased()
                if seenNumbers.contains(numberKey) {
                    report.skipped.append("第 \(rowNumber) 行：学号 \(number) 在文件中重复")
                    continue
                }
                seenNumbers.insert(numberKey)
            } else if seenNames.contains(nameKey) {
                report.skipped.append("第 \(rowNumber) 行：姓名 \(name) 在文件中重复")
                continue
            }
            seenNames.insert(nameKey)

            var student = Student()
            student.name = name
            student.studentNumber = number
            let boardingText = mappedValue(.isBoarding)
            student.isBoarding = boardingText.isEmpty ? false : parseBoarding(boardingText)
            student.phone = mappedValue(.phone)
            student.boardingAddress = mappedValue(.boardingAddress)
            student.policeStation = mappedValue(.policeStation)

            var slots = (0..<2).map { _ in Guardian() }
            for (column, text) in values {
                if case .guardian(let slot, let part) = mapping[column], slots.indices.contains(slot) {
                    switch part {
                    case .name: slots[slot].name = text
                    case .relation: slots[slot].relation = text
                    case .phone: slots[slot].phone = text
                    }
                }
            }
            student.guardians = slots.filter { !$0.isEmpty }

            for (column, text) in values {
                guard case .customField(let fieldID) = mapping[column],
                      let field = fields.first(where: { $0.id == fieldID }) else { continue }
                guard !text.isEmpty else { continue }
                switch field.type {
                case .text:
                    student.customValues[fieldID.uuidString] = .text(text)
                case .phone:
                    if FieldFormat.isValidPhone(text) {
                        student.customValues[fieldID.uuidString] = .text(text)
                    }
                case .idCard:
                    if FieldFormat.isValidIDCard(text) {
                        student.customValues[fieldID.uuidString] = .text(text)
                    }
                case .number:
                    if let n = Double(text) { student.customValues[fieldID.uuidString] = .number(n) }
                case .date:
                    if let date = parseExcelDate(text) {
                        student.customValues[fieldID.uuidString] = .date(date)
                    } else if let date = Fmt.date.date(from: text) {
                        student.customValues[fieldID.uuidString] = .date(date)
                    }
                case .boolean:
                    student.customValues[fieldID.uuidString] = .boolean(parseBoarding(text))
                case .choice(let options):
                    if options.contains(text) {
                        student.customValues[fieldID.uuidString] = .text(text)
                    } else if !text.isEmpty {
                        // 导入目前不存在的选项：自动补充到字段选项里
                        store.appendChoiceOptions(fieldID: fieldID, options: [text])
                        student.customValues[fieldID.uuidString] = .text(text)
                    }
                case .multiChoice(let options):
                    // 值为选项子集（顿号分隔）；缺失的选项自动补充
                    let parts = text.components(separatedBy: CharacterSet(charactersIn: "、,，"))
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if parts.isEmpty { continue }
                    let missing = parts.filter { !options.contains($0) }
                    if !missing.isEmpty {
                        store.appendChoiceOptions(fieldID: fieldID, options: missing)
                    }
                    student.customValues[fieldID.uuidString] = .text(parts.joined(separator: "、"))
                case .address:
                    student.customValues[fieldID.uuidString] = .text(text)
                case .dateTime:
                    // 日期时间字段由选择器维护，导入时尝试按文本解析为日期
                    if let d = parseExcelDate(text) {
                        student.customValues[fieldID.uuidString] = .date(d)
                    }
                case .linkStudents, .attachment:
                    break
                }
            }

            // 已存在匹配：有学号按学号；无学号按姓名。覆盖时无学号不覆盖已有学号
            let existing = store.data.students.first(where: { student in
                if !number.isEmpty {
                    return student.studentNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == number.lowercased()
                }
                return student.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == name.lowercased()
            })
            if let existing {
                // 逐行策略优先；未指定的行走默认（勾选“更新已有学生”=覆盖，否则跳过）
                switch duplicateActions[rowNumber] ?? (updateExisting ? .overwrite : .skip) {
                case .overwrite:
                    var updated = existing
                    updated.name = name
                    if !number.isEmpty { updated.studentNumber = number }
                    if mapping.values.contains(.isBoarding) { updated.isBoarding = student.isBoarding }
                    if mapping.values.contains(.phone) { updated.phone = student.phone }
                    if mapping.values.contains(.boardingAddress) { updated.boardingAddress = student.boardingAddress }
                    if mapping.values.contains(.policeStation) { updated.policeStation = student.policeStation }
                    if !student.guardians.isEmpty { updated.guardians = student.guardians }
                    for (key, newValue) in student.customValues {
                        updated.customValues[key] = newValue
                    }
                    store.updateStudent(updated)
                    report.updated += 1
                case .keepBoth:
                    store.addStudent(student)
                    report.imported += 1
                case .skip:
                    let key = number.isEmpty ? "姓名 \(name)" : "学号 \(number)"
                    report.skipped.append("第 \(rowNumber) 行：\(key) 已存在")
                }
                continue
            }

            store.addStudent(student)
            report.imported += 1
        }
        return report
    }

    /// 重复行信息（导入前预检，供用户逐行选择处理方式）
    struct DuplicateRow: Identifiable, Equatable {
        /// 行号（从 1 起，含标题行，与 Excel 行号一致）
        let rowNumber: Int
        let name: String
        let number: String
        var id: Int { rowNumber }
        /// 与已有学生重复的依据描述
        var keyDescription: String {
            number.isEmpty ? "姓名「\(name)」" : "学号 \(number)"
        }
    }

    /// 预检：找出与已有学生（学号优先，无学号按姓名）重复的行。
    /// 行号必须与 importRows 的编号一致（headerRowIndex + 1 起步、先自增）。
    static func detectDuplicateRows(grid: [[String]], headerRowIndex: Int,
                                    mapping: [Int: ImportTarget], store: ProjectStore) -> [DuplicateRow] {
        var conflicts: [DuplicateRow] = []
        var seenNumbers = Set<String>()
        var seenNames = Set<String>()
        var rowNumber = headerRowIndex + 1
        for row in grid.dropFirst(headerRowIndex + 1) {
            rowNumber += 1
            var name = ""
            var number = ""
            for (column, target) in mapping {
                guard row.indices.contains(column) else { continue }
                let text = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
                switch target {
                case .name: name = text
                case .studentNumber: number = text
                default: break
                }
            }
            guard !name.isEmpty else { continue }
            if !number.isEmpty {
                let key = number.lowercased()
                guard !seenNumbers.contains(key),
                      !store.data.students.contains(where: {
                          $0.studentNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
                      }) else {
                    // 文件内重复的行不会被导入，不进入冲突列表
                    if !seenNumbers.contains(key) { conflicts.append(DuplicateRow(rowNumber: rowNumber, name: name, number: number)) }
                    continue
                }
                seenNumbers.insert(key)
            } else {
                let key = name.lowercased()
                guard !seenNames.contains(key),
                      !store.data.students.contains(where: {
                          $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
                      }) else {
                    if !seenNames.contains(key) { conflicts.append(DuplicateRow(rowNumber: rowNumber, name: name, number: number)) }
                    continue
                }
                seenNames.insert(key)
            }
        }
        return conflicts
    }

    nonisolated static func parseBoarding(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["住宿", "寄宿", "是", "y", "yes", "true", "1", "✓", "√"].contains(lower)
    }

    /// Excel 日期序列号（基准 1899-12-30）转日期
    nonisolated static func parseExcelDate(_ text: String) -> Date? {
        guard let serial = Double(text), serial > 60, serial < 200_000 else { return nil }
        return Date(timeIntervalSince1970: -2_209_161_600 + serial * 86_400)
    }
}

// MARK: - CSV 解析

enum CSVParser {

    /// 解析 CSV（支持引号转义、多行字段）；自动识别 UTF-8 / GB18030 编码
    static func parse(data: Data) -> [[String]] {
        let text = decode(data)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while true {
            let char: Character?
            if let p = pending {
                char = p
                pending = nil
            } else {
                char = iterator.next()
            }
            guard let char else { break }

            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"":
                    inQuotes = true
                case ",":
                    endField()
                case "\r\n": // Swift 把 CRLF 视为一个字素
                    endRow()
                case "\r":
                    if let next = iterator.next(), next != "\n" { pending = next }
                    endRow()
                case "\n":
                    endRow()
                default:
                    field.append(char)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    private static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.hasPrefix("﻿") ? String(utf8.dropFirst()) : utf8
        }
        // GB18030 = CFStringEncoding 0x0631
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0631))
        if let decoded = String(data: data, encoding: gb18030) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }
}
