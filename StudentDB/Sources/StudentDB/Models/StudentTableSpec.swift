import Foundation

// MARK: - 字段格式标准（参考 SQL 约束 / Excel 数据验证）

/// 字段格式校验：表格、表单、导入共用，保证入库数据格式标准
enum FieldFormat {

    /// 电话：去分隔符后为 7-15 位数字，可带国际区号前缀（+86）
    static func isValidPhone(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true } // 电话为选填
        var normalized = trimmed
        for separator in [" ", "-", "－", "(", ")", "（", "）"] {
            normalized = normalized.replacingOccurrences(of: separator, with: "")
        }
        guard normalized.count >= 7, normalized.count <= 15 else { return false }
        if normalized.hasPrefix("+") { normalized.removeFirst() }
        return normalized.allSatisfy { $0.isNumber }
    }

    /// 身份证号：18 位（含 GB 11643 校验码，末位可为 X）或 15 位旧证
    static func isValidIDCard(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let chars = Array(trimmed)
        guard chars.count == 18 || chars.count == 15 else { return false }
        guard chars.prefix(chars.count - 1).allSatisfy({ $0.isNumber }) else { return false }
        if chars.count == 15 { return true }   // 旧证无校验码
        // 18 位：末位 0-9 或 X，校验前 17 位加权和
        guard chars.last == "X" || chars.last!.isNumber else { return false }
        let weights: [Int] = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checkMap = Array("10X98765432")
        let sum = zip(weights, chars.prefix(17)).reduce(0) { $0 + $1.0 * Int(String($1.1))! }
        return checkMap[sum % 11] == chars.last
    }

    /// 学号：非空（唯一性由存储层校验）
    static func isValidStudentNumber(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 表格视图列规格（显示、编辑、隐藏均基于此）

/// 监护人列的组成（数据库扁平化：监护人N姓名 / 监护人N关系 / 监护人N电话）
enum GuardianPart: String, Codable, CaseIterable {
    case name
    case relation
    case phone

    var title: String {
        switch self {
        case .name: return "姓名"
        case .relation: return "关系"
        case .phone: return "电话"
        }
    }
}

/// 内置列字段
enum StudentTableField: String, Codable, CaseIterable {
    case name
    case studentNumber
    case boarding
    case phone
    case boardingAddress
    case policeStation
    case recordCount

    var title: String {
        switch self {
        case .name: return "姓名"
        case .studentNumber: return "学号"
        case .boarding: return "住宿"
        case .phone: return "联系电话"
        case .boardingAddress: return "住宿地址"
        case .policeStation: return "派出所"
        case .recordCount: return "记录"
        }
    }

    var isEditable: Bool { true }

    var sortKey: ListSortKey? {
        switch self {
        case .name: return .name
        case .studentNumber: return .studentNumber
        case .boarding: return .isBoarding
        case .policeStation: return .policeStation
        case .phone, .boardingAddress, .recordCount: return nil
        }
    }
}

/// 单元格编辑值
enum CellEdit {
    case text(String)
    case boolean(Bool)
    case date(Date)
}

/// 一列的定义：内置字段、监护人槽位列或自定义字段
struct StudentColumnSpec: Identifiable, Equatable {
    /// 内置字段用 StudentTableField.rawValue，监护人列如 "guardian1-phone"，自定义字段用 UUID 字符串
    let id: String
    let title: String
    let field: StudentTableField?
    let customField: CustomField?
    /// 监护人槽位（1 起）；nil = 非监护人列
    let guardianSlot: Int?
    /// 监护人列的组成（姓名/关系/电话）
    let guardianPart: GuardianPart?

    init(id: String, title: String, field: StudentTableField?, customField: CustomField?,
         guardianSlot: Int? = nil, guardianPart: GuardianPart? = nil) {
        self.id = id
        self.title = title
        self.field = field
        self.customField = customField
        self.guardianSlot = guardianSlot
        self.guardianPart = guardianPart
    }

    var isEditable: Bool { field?.isEditable ?? true }
    var sortKey: ListSortKey? { field?.sortKey }

    /// 单元格控件类型（参考 Notion：文本双击编辑、勾选单击切换、日期内嵌选择器、下拉即选）
    enum CellKind: Equatable {
        case text(editable: Bool)
        case checkbox
        case datePicker
        /// 日期时间（精确到分）
        case dateTimePicker
        case choice(options: [String])
        /// 多选（弹菜单勾选，值以顿号拼接）
        case multiChoice(options: [String])
        case readonly
    }

    var cellKind: CellKind {
        if guardianSlot != nil { return .text(editable: true) }
        if let field {
            switch field {
            case .name, .studentNumber, .phone, .boardingAddress, .policeStation:
                return .text(editable: true)
            case .boarding:
                return .checkbox
            case .recordCount:
                return .readonly
            }
        }
        switch customField?.type {
        case .boolean: return .checkbox
        case .date: return .datePicker
        case .dateTime: return .dateTimePicker
        case .choice(let options): return .choice(options: options)
        case .multiChoice(let options): return .multiChoice(options: options)
        default: return .text(editable: true) // text / number / address 均为文本编辑
        }
    }

    /// 内置列（按项目保存顺序、过滤被删除的内置字段；不含监护人列）。
    /// layout 非空时按统一布局中内置列的相对顺序输出。
    static func builtins(order: [String], deleted: Set<String>, layout: [String] = []) -> [StudentColumnSpec] {
        var keys = order.filter { StudentTableField(rawValue: $0) != nil }
        for field in StudentTableField.allCases where !keys.contains(field.rawValue) {
            keys.append(field.rawValue)
        }
        if !layout.isEmpty {
            let layoutSet = Set(layout)
            keys.sort { a, b in
                let ia = layout.firstIndex(of: a) ?? Int.max
                let ib = layout.firstIndex(of: b) ?? Int.max
                return ia < ib
            }
            _ = layoutSet
        }
        return keys.compactMap { key in
            guard let field = StudentTableField(rawValue: key), !deleted.contains(key) else { return nil }
            return StudentColumnSpec(id: field.rawValue, title: field.title, field: field, customField: nil)
        }
    }

    /// 第 slot 组监护人列（姓名 / 关系 / 电话）
    static func guardianColumns(slot: Int) -> [StudentColumnSpec] {
        GuardianPart.allCases.map { part in
            StudentColumnSpec(id: "guardian\(slot)-\(part.rawValue)",
                              title: "监护人\(slot)\(part.title)",
                              field: nil, customField: nil,
                              guardianSlot: slot, guardianPart: part)
        }
    }

    /// 全部列（内置按保存顺序 + 监护人槽位 + 自定义按保存顺序）
    static func allColumns(fields: [CustomField], guardianSlots: Int,
                           builtinOrder: [String] = [], deletedBuiltin: Set<String> = []) -> [StudentColumnSpec] {
        var order = builtinOrder
        for key in ["name", "studentNumber", "boarding", "phone",
                    "boardingAddress", "policeStation", "recordCount"] where !order.contains(key) {
            order.append(key)
        }
        let slots = max(1, min(guardianSlots, 5))
        let guardian = (1...slots).flatMap { guardianColumns(slot: $0) }
        return builtins(order: order, deleted: deletedBuiltin) + guardian + fields.map {
            StudentColumnSpec(id: $0.id.uuidString, title: $0.name, field: nil, customField: $0,
                              guardianSlot: nil, guardianPart: nil)
        }
    }

    static func columns(fields: [CustomField], hidden: Set<String>, guardianSlots: Int = 1,
                        builtinOrder: [String] = [], deletedBuiltin: Set<String> = [],
                        layout: [String] = []) -> [StudentColumnSpec] {
        let visible = allColumns(fields: fields, guardianSlots: guardianSlots,
                                 builtinOrder: builtinOrder, deletedBuiltin: deletedBuiltin)
            .filter { !hidden.contains($0.id) }
        guard !layout.isEmpty else { return visible }
        // 按统一布局重排（布局里被隐藏/删除的项跳过，新出现的列追加尾部）
        var pool = visible
        var result: [StudentColumnSpec] = []
        for id in layout {
            if let idx = pool.firstIndex(where: { $0.id == id }) {
                result.append(pool.remove(at: idx))
            }
        }
        result.append(contentsOf: pool)
        return result
    }

    /// 单元格显示文本
    func displayText(of s: Student) -> String {
        if let slot = guardianSlot, let part = guardianPart {
            let guardian = slot <= s.guardians.count ? s.guardians[slot - 1] : nil
            switch part {
            case .name: return guardian?.name ?? ""
            case .relation: return guardian?.relation ?? ""
            case .phone: return guardian?.phone ?? ""
            }
        }
        switch field {
        case .name: return s.name
        case .studentNumber: return s.studentNumber
        case .boarding: return s.boardingText
        case .phone: return s.phone
        case .boardingAddress: return s.boardingAddress
        case .policeStation: return s.policeStation
        case .recordCount: return String(s.records.count)
        case nil, .none:
            return s.customValues[customField?.id.uuidString ?? ""]?.displayText ?? ""
        }
    }

    /// 把单元格编辑写入学生（返回修改后的副本；不符合字段格式标准时原样返回）
    func applying(_ edit: CellEdit, to student: Student) -> Student {
        var s = student
        // 监护人槽位列
        if let slot = guardianSlot, let part = guardianPart {
            let t = trimmed(edit)
            while s.guardians.count < slot {
                s.guardians.append(Guardian())
            }
            switch part {
            case .name: s.guardians[slot - 1].name = t
            case .relation: s.guardians[slot - 1].relation = t
            case .phone:
                guard FieldFormat.isValidPhone(t) else { return student }
                s.guardians[slot - 1].phone = t
            }
            return s
        }

        switch (cellKind, edit) {
        case (.text, .text(let raw)), (.choice, .text(let raw)), (.multiChoice, .text(let raw)):
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case .name:
                guard !t.isEmpty else { return student } // 姓名 NOT NULL
                s.name = t
            case .studentNumber:
                guard FieldFormat.isValidStudentNumber(t) else { return student } // 学号 NOT NULL
                s.studentNumber = t
            case .phone:
                guard FieldFormat.isValidPhone(t) else { return student }
                s.phone = t
            case .boardingAddress: s.boardingAddress = t
            case .policeStation: s.policeStation = t
            default: break
            }
            if field == nil, let f = customField {
                let key = f.id.uuidString
                if trimmedTextIsEmpty(t) {
                    s.customValues.removeValue(forKey: key)
                    return s
                }
                switch f.type {
                case .text:
                    s.customValues[key] = .text(t)
                case .number:
                    guard let n = Double(t) else { return student } // 数字列：仅接受合法数字
                    s.customValues[key] = .number(n)
                case .date:
                    if let d = StudentImporter.parseExcelDate(t) {
                        s.customValues[key] = .date(d)
                    } else if let d = Fmt.date.date(from: t) {
                        s.customValues[key] = .date(d)
                    } else {
                        return student
                    }
                case .boolean:
                    s.customValues[key] = .boolean(StudentImporter.parseBoarding(t))
                case .choice(let options):
                    // 仅接受选项内的值或空（清空）
                    guard t.isEmpty || options.contains(t) else { return student }
                    s.customValues[key] = .text(t)
                case .multiChoice(let options):
                    // 值应为选项子集（顿号拼接）或空
                    if t.isEmpty {
                        s.customValues[key] = .text(t)
                    } else {
                        let parts = t.components(separatedBy: "、").filter { !$0.isEmpty }
                        guard parts.allSatisfy({ options.contains($0) }) else { return student }
                        s.customValues[key] = .text(parts.joined(separator: "、"))
                    }
                case .address:
                    // 地址为多行文本，允许换行（表格单元格提交前已转为单行）
                    s.customValues[key] = .text(t)
                case .dateTime:
                    // 文本方式写入日期时间由选择器路径处理，这里兜底拒绝
                    return student
                case .phone:
                    guard t.isEmpty || FieldFormat.isValidPhone(t) else { return student }
                    s.customValues[key] = .text(t)
                case .idCard:
                    guard t.isEmpty || FieldFormat.isValidIDCard(t) else { return student }
                    s.customValues[key] = .text(t)
                case .linkStudents, .attachment:
                    // 学生表不支持这两类字段（通用表的行编辑另行走 TableSpec）
                    return student
                }
            }

        case (.checkbox, .boolean(let value)):
            if field == .boarding {
                s.isBoarding = value
            } else if let f = customField {
                s.customValues[f.id.uuidString] = .boolean(value)
            }

        case (.datePicker, .date(let date)), (.dateTimePicker, .date(let date)):
            if let f = customField {
                s.customValues[f.id.uuidString] = .date(date)
            }

        default:
            break
        }
        return s
    }

    private func trimmed(_ edit: CellEdit) -> String {
        if case .text(let t) = edit {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func trimmedTextIsEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

