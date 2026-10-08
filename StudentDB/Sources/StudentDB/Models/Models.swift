import Foundation

// MARK: - 格式化工具

enum Fmt {
    static let date: DateFormatter = make("yyyy年M月d日", locale: "zh_CN")
    static let dateTime: DateFormatter = make("yyyy-MM-dd HH:mm")
    static let csvDateTime: DateFormatter = make("yyyy-MM-dd HH:mm")
    static let fileStamp: DateFormatter = make("yyyy-MM-dd-HHmmss-SSS")

    private static func make(_ format: String, locale: String? = nil) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        if let locale { f.locale = Locale(identifier: locale) }
        return f
    }

    static func fileSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1 { return "\(bytes) B" }
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - 自定义字段

enum FieldType: Codable, Equatable, Hashable {
    case text
    case number
    case date
    case boolean
    /// 下拉选择（Access 查阅列）：限定选项列表
    case choice(options: [String])
    /// 多选（标签）：可勾选多个选项，值以顿号拼接保存
    case multiChoice(options: [String])
    /// 日期时间（精确到分）
    case dateTime
    /// 地址（多行文本，适合长地址）
    case address
    /// 关联学生（Access 查阅列）：值为学生 UUID 列表，TableCell 下拉选择
    case linkStudents
    /// 附件字段：单元格本身不存值，文件存放在项目包内该字段专属目录
    case attachment
    /// 联系电话（位数/格式校验）
    case phone
    /// 身份证号（18 位含校验码，兼容 15 位旧证）
    case idCard

    /// 界面上可选择的字段类型（选项内容在添加后编辑）
    static let selectableTypes: [FieldType] = [
        .text, .number, .date, .dateTime, .boolean,
        .choice(options: []), .multiChoice(options: []), .address, .attachment,
        .phone, .idCard
    ]

    var id: String {
        switch self {
        case .text: return "text"
        case .number: return "number"
        case .date: return "date"
        case .boolean: return "boolean"
        case .choice: return "choice"
        case .multiChoice: return "multiChoice"
        case .dateTime: return "dateTime"
        case .address: return "address"
        case .linkStudents: return "linkStudents"
        case .attachment: return "attachment"
        case .phone: return "phone"
        case .idCard: return "idCard"
        }
    }

    /// 是否与另一个类型同类（下拉/多选忽略选项内容）
    func sameKind(as other: FieldType) -> Bool { id == other.id }

    var displayName: String {
        switch self {
        case .text: return "文本"
        case .number: return "数字"
        case .date: return "日期"
        case .boolean: return "是/否"
        case .choice: return "单选（下拉）"
        case .multiChoice: return "多选"
        case .dateTime: return "日期时间"
        case .address: return "地址（多行）"
        case .linkStudents: return "关联学生"
        case .attachment: return "附件"
        case .phone: return "联系电话"
        case .idCard: return "身份证号"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "textformat"
        case .number: return "number"
        case .date: return "calendar"
        case .boolean: return "checkmark.circle"
        case .choice: return "chevron.up.chevron.down"
        case .multiChoice: return "checklist"
        case .dateTime: return "clock.calendar"
        case .address: return "mappin.and.ellipse"
        case .linkStudents: return "person.2"
        case .attachment: return "paperclip"
        case .phone: return "phone"
        case .idCard: return "person.text.rectangle"
        }
    }

    init(from decoder: Decoder) throws {
        // 新格式 {kind: "choice", options: [...]}；旧格式为单值字符串 "text"
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let raw = try? c.decode(String.self, forKey: .kind) {
            switch raw {
            case "text": self = .text
            case "number": self = .number
            case "date": self = .date
            case "boolean": self = .boolean
            case "choice":
                let options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? []
                self = .choice(options: options)
            case "multiChoice":
                let options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? []
                self = .multiChoice(options: options)
            case "dateTime": self = .dateTime
            case "address": self = .address
            case "linkStudents": self = .linkStudents
            case "attachment": self = .attachment
            case "phone": self = .phone
            case "idCard": self = .idCard
            default:
                self = .text
            }
            return
        }
        let single = try decoder.singleValueContainer().decode(String.self)
        switch single {
        case "number": self = .number
        case "date": self = .date
        case "boolean": self = .boolean
        default: self = .text
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .kind)
        if case .choice(let options) = self {
            try c.encode(options, forKey: .options)
        }
        if case .multiChoice(let options) = self {
            try c.encode(options, forKey: .options)
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case options
    }
}

/// 自定义字段定义（每个项目独立维护）
struct CustomField: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var type: FieldType = .text
    /// 创建时间（旧数据为 nil）
    var createdAt: Date?
}

/// 字段值：按值本身编码，修改字段类型后旧值仍可显示
enum CustomValue: Codable, Equatable, Hashable {
    case text(String)
    case number(Double)
    case date(Date)
    case boolean(Bool)
    /// 关联学生（存学生 UUID 列表；显示文本由表层解析学生名）
    case link([UUID])

    var displayText: String {
        switch self {
        case .text(let s):
            return s
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
            var formatted = String(format: "%.2f", n)
            while formatted.hasSuffix("0") { formatted.removeLast() }
            if formatted.hasSuffix(".") { formatted.removeLast() }
            return formatted
        case .date(let d):
            return Fmt.dateTime.string(from: d)
        case .boolean(let b):
            return b ? "是" : "否"
        case .link(let ids):
            return ids.map { $0.uuidString }.joined(separator: ",")
        }
    }

    /// 关联学生的 id（非关联类型返回空）
    var linkedStudentIDs: [UUID] {
        if case .link(let ids) = self { return ids }
        return []
    }
}

extension CustomValue {
    enum CodingKeys: String, CodingKey {
        case text, number, date, boolean, link
    }

    /// 旧版（Swift 合成枚举 Codable）格式：{"text": {"_0": "值"}}
    private enum LegacyIndex: String, CodingKey {
        case _0 = "_0"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .text) { self = .text(s); return }
        if var sub = try? c.nestedUnkeyedContainer(forKey: .text) {
            self = .text(try sub.decode(String.self)); return
        }
        if let sub = try? c.nestedContainer(keyedBy: LegacyIndex.self, forKey: .text),
           let s = try? sub.decode(String.self, forKey: LegacyIndex._0) { self = .text(s); return }
        if let n = try? c.decode(Double.self, forKey: .number) { self = .number(n); return }
        if let sub = try? c.nestedContainer(keyedBy: LegacyIndex.self, forKey: .number),
           let n = try? sub.decode(Double.self, forKey: LegacyIndex._0) { self = .number(n); return }
        if let d = try? c.decode(Date.self, forKey: .date) { self = .date(d); return }
        if let sub = try? c.nestedContainer(keyedBy: LegacyIndex.self, forKey: .date),
           let d = try? sub.decode(Date.self, forKey: LegacyIndex._0) { self = .date(d); return }
        if let b = try? c.decode(Bool.self, forKey: .boolean) { self = .boolean(b); return }
        if let sub = try? c.nestedContainer(keyedBy: LegacyIndex.self, forKey: .boolean),
           let b = try? sub.decode(Bool.self, forKey: LegacyIndex._0) { self = .boolean(b); return }
        if let ids = try? c.decode([UUID].self, forKey: .link) { self = .link(ids); return }
        if let sub = try? c.nestedContainer(keyedBy: LegacyIndex.self, forKey: .link),
           let ids = try? sub.decode([UUID].self, forKey: LegacyIndex._0) { self = .link(ids); return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "未知字段值格式"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s): try c.encode(s, forKey: .text)
        case .number(let n): try c.encode(n, forKey: .number)
        case .date(let d): try c.encode(d, forKey: .date)
        case .boolean(let b): try c.encode(b, forKey: .boolean)
        case .link(let ids): try c.encode(ids, forKey: .link)
        }
    }
}

// MARK: - 监护人

struct Guardian: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var relation: String = ""
    var phone: String = ""

    var isEmpty: Bool { name.isEmpty && relation.isEmpty && phone.isEmpty }

    var displayText: String {
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        if !relation.isEmpty { parts.append("(\(relation))") }
        if !phone.isEmpty { parts.append(phone) }
        return parts.joined(separator: " ")
    }
}

// MARK: - 关心关爱记录

struct CareRecord: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var type: String = "关心关爱"
    var content: String = ""
    var createdAt: Date = Date()
}

// MARK: - 学生

struct Student: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var studentNumber: String = ""
    var isBoarding: Bool = false
    var phone: String = ""
    var boardingAddress: String = ""
    var policeStation: String = ""
    var customValues: [String: CustomValue] = [:]
    var guardians: [Guardian] = []
    var records: [CareRecord] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var avatarInitial: String { String(name.prefix(1)) }
    /// “住宿/走读”文本（表格排序用）
    var boardingText: String { isBoarding ? "住宿" : "走读" }
}

// MARK: - 项目数据（students.json 的顶层结构）

struct ProjectData: Codable, Equatable {
    var formatVersion: Int = 1
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// 记录类型（可自行增删）；记录里保存的是类型文字，删除类型不影响历史记录
    var recordTypes: [String] = ProjectData.defaultRecordTypes
    var fieldDefinitions: [CustomField] = []
    var students: [Student] = []
    /// 列表视图（隐式单视图：打开项目时收敛为一个，只保存个性化设置）
    var views: [ListView] = [ListView(name: "全部学生")]
    /// 收敛保留的那个视图的 id（兼容旧多视图数据）
    var currentViewID: UUID?
    /// 侧栏快捷筛选标签（“全部”为固定标签，不在此列表）
    var quickFilters: [QuickFilter] = QuickFilter.defaults
    /// 内置字段显示顺序（StudentTableField.rawValue）
    var builtinOrder: [String] = ["name", "studentNumber", "boarding", "phone",
                                  "boardingAddress", "policeStation", "recordCount"]
    /// 自定义字段显示顺序（字段 UUID）
    var fieldOrder: [UUID] = []
    /// 被删除的内置字段（软删除：界面隐藏、数据保留，可恢复）
    var deletedBuiltinFields: Set<String> = []
    /// 全部列的统一显示顺序（内置 key / guardianN-part / 字段 UUID）；空 = 默认分组顺序。
    /// 表格拖拽列、详情页拖拽行、字段管理页调序都写到这里。
    var columnLayout: [String] = []
    /// 通用数据表（记录表、成绩表等，Access 式多表）；学生表为强类型不在此列
    var tables: [DBTable] = []
    /// 学生表列宽记忆（列规格 id → 宽度）
    var columnWidths: [String: CGFloat] = [:]
    /// 当前打开的数据表 id；nil/失效 = 学生表
    var currentTableID: UUID?
    /// 记录已迁移为独立表的标记（一次性迁移防重复）
    var recordMigrationDone: Bool = false
    /// 学分规则（编辑规则后整体替换；旧项目缺省为内置预设，见 CreditRule.defaults）
    var creditRules: [CreditRule] = CreditRule.defaults
    /// 学分记录（留痕：日期时间、学生、规则名/分值快照、备注、学期）
    var creditRecords: [CreditRecord] = []
    /// 学分面板所选学期（nil = 按当前日期推断，见 CreditSemester.infer）
    var creditSemesterKey: String? = nil

    static let defaultRecordTypes = ["关心关爱记录", "谈话记录", "家校沟通记录", "违纪记录"]

    /// 取数据表
    func table(id: UUID?) -> DBTable? {
        tables.first { $0.id == id }
    }

    /// 兼容旧版数据文件：缺失的字段（views 等）用默认值补齐
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        recordTypes = try c.decodeIfPresent([String].self, forKey: .recordTypes) ?? ProjectData.defaultRecordTypes
        fieldDefinitions = try c.decodeIfPresent([CustomField].self, forKey: .fieldDefinitions) ?? []
        students = try c.decodeIfPresent([Student].self, forKey: .students) ?? []
        views = try c.decodeIfPresent([ListView].self, forKey: .views) ?? [ListView(name: "全部学生")]
        currentViewID = try c.decodeIfPresent(UUID.self, forKey: .currentViewID)
        quickFilters = try c.decodeIfPresent([QuickFilter].self, forKey: .quickFilters) ?? QuickFilter.defaults
        let defaultOrder = ["name", "studentNumber", "boarding", "phone",
                            "boardingAddress", "policeStation", "recordCount"]
        let decodedOrder = try c.decodeIfPresent([String].self, forKey: .builtinOrder) ?? []
        // 保存的顺序优先，未记录的内置字段按默认顺序追加
        var order = decodedOrder.filter { defaultOrder.contains($0) }
        for key in defaultOrder where !order.contains(key) {
            order.append(key)
        }
        builtinOrder = order
        fieldOrder = try c.decodeIfPresent([UUID].self, forKey: .fieldOrder) ?? []
        deletedBuiltinFields = try c.decodeIfPresent(Set<String>.self, forKey: .deletedBuiltinFields) ?? []
        columnLayout = try c.decodeIfPresent([String].self, forKey: .columnLayout) ?? []
        tables = try c.decodeIfPresent([DBTable].self, forKey: .tables) ?? []
        columnWidths = try c.decodeIfPresent([String: CGFloat].self, forKey: .columnWidths) ?? [:]
        currentTableID = try c.decodeIfPresent(UUID.self, forKey: .currentTableID)
        recordMigrationDone = try c.decodeIfPresent(Bool.self, forKey: .recordMigrationDone) ?? false
        creditRules = try c.decodeIfPresent([CreditRule].self, forKey: .creditRules) ?? CreditRule.defaults
        creditRecords = try c.decodeIfPresent([CreditRecord].self, forKey: .creditRecords) ?? []
        creditSemesterKey = try c.decodeIfPresent(String.self, forKey: .creditSemesterKey)
    }

    /// 按保存顺序排列的自定义字段（顺序外的新字段追加在尾部）
    var orderedFields: [CustomField] {
        var result: [CustomField] = []
        var consumed = Set<UUID>()
        for id in fieldOrder {
            if let f = fieldDefinitions.first(where: { $0.id == id }) {
                result.append(f)
                consumed.insert(id)
            }
        }
        for f in fieldDefinitions where !consumed.contains(f.id) {
            result.append(f)
        }
        return result
    }

    /// 按保存顺序排列且未被删除的内置字段
    var visibleBuiltinFields: [StudentTableField] {
        let all = builtinOrder.compactMap { StudentTableField(rawValue: $0) }
        return all.filter { !deletedBuiltinFields.contains($0.rawValue) }
    }
}

// MARK: - 列表筛选

enum StudentFilter: String, Codable, CaseIterable, Identifiable {
    case all
    case boarding
    case day

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .boarding: return "住宿"
        case .day: return "走读"
        }
    }
}

// MARK: - 快捷筛选（侧栏可自定义的标签按钮）

/// 筛选条件：视图与快捷筛选标签共用（类 SQL WHERE 子句）
enum QuickCondition: Codable, Equatable, Hashable {
    case all
    case boarding(Bool)
    case policeStation(String)
    case customField(fieldID: UUID, value: String)
    /// 任意列的模糊查询（LIKE %value%）：key 为列规格 id（内置字段 key / guardianN-part / 字段 UUID）
    case columnContains(columnID: String, value: String)

    var displayName: String {
        switch self {
        case .all: return "全部学生"
        case .boarding(true): return "住宿学生"
        case .boarding(false): return "走读学生"
        case .policeStation(let s): return "派出所「\(s)」"
        case .customField(_, let v): return "字段包含「\(v)」"
        case .columnContains(_, let v): return "包含「\(v)」"
        }
    }
}

/// 侧栏快捷筛选标签
struct QuickFilter: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var condition: QuickCondition

    static let defaults: [QuickFilter] = [
        QuickFilter(name: "住宿", condition: .boarding(true)),
        QuickFilter(name: "走读", condition: .boarding(false))
    ]
}

// MARK: - 列表视图（隐式单视图：保存排序/布局/列显隐等个性化设置；筛选只在会话内）

enum ListSortKey: String, Codable, CaseIterable, Identifiable {
    case name
    case studentNumber
    case isBoarding
    case policeStation
    case createdAt
    case updatedAt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "姓名"
        case .studentNumber: return "学号"
        case .isBoarding: return "住宿状态"
        case .policeStation: return "派出所"
        case .createdAt: return "建档时间"
        case .updatedAt: return "更新时间"
        }
    }
}

/// 视图显示方式：详情（选中学生看详情）或表格（Excel 样式看全部）
enum ViewLayout: String, Codable, CaseIterable, Identifiable {
    case detail
    case table

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .detail: return "详情"
        case .table: return "表格"
        }
    }
}

/// Excel 式列筛选（表头漏斗）：文本包含 + 值清单白名单；仅会话内生效，不随项目保存
struct ColumnFilter: Codable, Equatable, Hashable {
    /// 包含匹配（不区分大小写）；空 = 不限制
    var searchText: String = ""
    /// 勾选的值；nil = 全部通过，空集合 = 全部排除，非空 = 白名单
    var selectedValues: Set<String>? = nil

    var isActive: Bool { !searchText.isEmpty || selectedValues != nil }
}

struct ListView: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    /// 关键字筛选（姓名、学号、家长、派出所、自定义字段等全字段匹配）；仅会话内生效，不持久化
    var keyword: String = ""
    /// 结构化筛选条件（由快捷筛选标签或菜单设置）；仅会话内生效，不持久化
    var condition: QuickCondition = .all
    /// 排序
    var sortKey: ListSortKey
    var sortAscending: Bool
    /// 显示方式：详情 / 表格
    var layout: ViewLayout
    /// 表格视图里隐藏的列（内置字段 key 或自定义字段 UUID 字符串）
    var hiddenColumnIDs: Set<String>
    /// 表格里监护人扁平列的组数（每组：姓名/关系/电话）
    var guardianColumnCount: Int
    /// Excel 式列筛选（列规格 id → 筛选条件）；仅会话内生效，不持久化
    var columnFilters: [String: ColumnFilter] = [:]
    /// 通用表：按字段 UUID 排序（优先于 sortKey；学生表不用）
    var sortFieldID: UUID?

    init(id: UUID = UUID(), name: String, keyword: String = "", condition: QuickCondition = .all,
         sortKey: ListSortKey = .name, sortAscending: Bool = true,
         layout: ViewLayout = .detail, hiddenColumnIDs: Set<String> = [], guardianColumnCount: Int = 1) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.condition = condition
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.layout = layout
        self.hiddenColumnIDs = hiddenColumnIDs
        self.guardianColumnCount = min(max(guardianColumnCount, 1), 5)
    }

    /// 筛选三项（keyword / condition / columnFilters）不进 CodingKeys：
    /// 旧文件里的对应键被忽略，解码后一律为空（显示全部学生）
    enum CodingKeys: String, CodingKey {
        case id, name
        case sortKey, sortAscending, layout, hiddenColumnIDs, guardianColumnCount, sortFieldID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名视图"
        sortKey = try c.decodeIfPresent(ListSortKey.self, forKey: .sortKey) ?? .name
        sortAscending = try c.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? true
        layout = try c.decodeIfPresent(ViewLayout.self, forKey: .layout) ?? .detail
        hiddenColumnIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenColumnIDs) ?? []
        guardianColumnCount = min(max(try c.decodeIfPresent(Int.self, forKey: .guardianColumnCount) ?? 1, 1), 5)
        sortFieldID = try c.decodeIfPresent(UUID.self, forKey: .sortFieldID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(sortKey, forKey: .sortKey)
        try c.encode(sortAscending, forKey: .sortAscending)
        try c.encode(layout, forKey: .layout)
        try c.encode(hiddenColumnIDs, forKey: .hiddenColumnIDs)
        try c.encode(guardianColumnCount, forKey: .guardianColumnCount)
        if let sortFieldID {
            try c.encode(sortFieldID, forKey: .sortFieldID)
        }
    }
}

/// 视图筛选/排序逻辑（列表与导出共用）
enum StudentQuery {

    static func filter(view: ListView, students: [Student], fields: [CustomField],
                       builtinOrder: [String] = [], deletedBuiltin: Set<String> = []) -> [Student] {
        var list = students
        switch view.condition {
        case .all:
            break
        case .boarding(let boarding):
            list = list.filter { $0.isBoarding == boarding }
        case .policeStation(let station):
            list = list.filter { $0.policeStation == station }
        case .customField(let fieldID, let value):
            list = list.filter {
                ($0.customValues[fieldID.uuidString]?.displayText ?? "")
                    .localizedCaseInsensitiveContains(value)
            }
        case .columnContains(let columnID, let value):
            // 内置字段被软删除后查询条件失效（返回全部），与列规格一致
            let spec = StudentColumnSpec.builtins(order: builtinOrder, deleted: deletedBuiltin)
                .first { $0.id == columnID }
                ?? StudentColumnSpec.allColumns(fields: fields, guardianSlots: 1,
                                                 builtinOrder: builtinOrder,
                                                 deletedBuiltin: deletedBuiltin).first { $0.id == columnID }
            list = list.filter { student in
                guard let spec else { return true }
                return spec.displayText(of: student).localizedCaseInsensitiveContains(value)
            }
        }
        let keyword = view.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            list = list.filter {
                SearchKit.searchableText(of: $0, fields: fields, deletedBuiltin: deletedBuiltin)
                    .localizedCaseInsensitiveContains(keyword)
            }
        }
        return list
    }

    static func sort(_ students: [Student], by view: ListView) -> [Student] {
        students.sorted { a, b in
            let result: Bool
            switch view.sortKey {
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .studentNumber:
                result = a.studentNumber.localizedStandardCompare(b.studentNumber) == .orderedAscending
            case .isBoarding:
                result = !a.isBoarding && b.isBoarding
            case .policeStation:
                result = a.policeStation.localizedStandardCompare(b.policeStation) == .orderedAscending
            case .createdAt:
                result = a.createdAt < b.createdAt
            case .updatedAt:
                result = a.updatedAt < b.updatedAt
            }
            return view.sortAscending ? result : !result
        }
    }

    static func apply(view: ListView, students: [Student], fields: [CustomField],
                      builtinOrder: [String] = [], deletedBuiltin: Set<String> = []) -> [Student] {
        sort(filter(view: view, students: students, fields: fields,
                    builtinOrder: builtinOrder, deletedBuiltin: deletedBuiltin), by: view)
    }

    /// 表格视图表头排序用的比较器
    static func sortComparator(view: ListView) -> KeyPathComparator<Student> {
        let order: SortOrder = view.sortAscending ? .forward : .reverse
        switch view.sortKey {
        case .name:
            return KeyPathComparator(\Student.name, comparator: .localizedStandard, order: order)
        case .studentNumber:
            return KeyPathComparator(\Student.studentNumber, comparator: .localizedStandard, order: order)
        case .isBoarding:
            return KeyPathComparator(\Student.boardingText, comparator: .localizedStandard, order: order)
        case .policeStation:
            return KeyPathComparator(\Student.policeStation, comparator: .localizedStandard, order: order)
        case .createdAt:
            return KeyPathComparator(\Student.createdAt, order: order)
        case .updatedAt:
            return KeyPathComparator(\Student.updatedAt, order: order)
        }
    }

    /// 数据中出现过的派出所（用于筛选菜单）
    static func policeStations(in students: [Student]) -> [String] {
        let set = Set(students.map { $0.policeStation }.filter { !$0.isEmpty })
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 应用 Excel 式列筛选（按列显示文本匹配，多个筛选条件之间取交集，叠加在视图条件之上）
    static func applyColumnFilters(_ students: [Student], columns: [StudentColumnSpec],
                                   filters: [String: ColumnFilter]) -> [Student] {
        let active = filters.filter { $0.value.isActive }
        guard !active.isEmpty else { return students }
        return students.filter { student in
            active.allSatisfy { columnID, filter in
                guard let spec = columns.first(where: { $0.id == columnID }) else { return true }
                let text = spec.displayText(of: student)
                if let selected = filter.selectedValues, !selected.contains(text) {
                    return false
                }
                if !filter.searchText.isEmpty,
                   !text.localizedCaseInsensitiveContains(filter.searchText) {
                    return false
                }
                return true
            }
        }
    }

    /// 某列出现过的全部显示值（Excel 筛选值清单）
    static func distinctValues(column: StudentColumnSpec, in students: [Student]) -> [String] {
        Array(Set(students.map { column.displayText(of: $0) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
