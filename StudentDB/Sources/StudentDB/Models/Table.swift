import Foundation

// MARK: - 通用数据表（Access 式多表）

/// 表的种类：记录表（关心关爱/谈话/家校/违纪，每类一张）与用户自建表
enum TableKind: String, Codable, CaseIterable {
    case record
    case custom

    var displayName: String {
        switch self {
        case .record: return "记录表"
        case .custom: return "自定义表"
        }
    }

    var systemImage: String {
        switch self {
        case .record: return "square.and.pencil"
        case .custom: return "tablecells"
        }
    }
}

/// 通用数据表：字段用 CustomField（复用 8 种字段类型 + 关联学生/附件），行值为字段字典。
/// 学生表为强类型（Student），不在 tables 中。
struct DBTable: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name = "新表"
    var systemImage: String = "tablecells"
    var kind: TableKind = .custom
    /// 创建时间（旧数据为 nil，显示时回退到"早期创建"）
    var createdAt: Date?
    var fields: [CustomField] = []
    /// 字段显示顺序（不含的字段追加在尾部）
    var fieldOrder: [UUID] = []
    var rows: [DBRow] = []
    /// 每张表自己的视图（隐式单视图：保存排序/布局/列显隐；筛选仅会话内生效）
    var views: [ListView] = []
    var currentViewID: UUID?
    /// 全部列的统一显示顺序（字段 UUID）；空 = fields 默认顺序
    var columnLayout: [String] = []
    /// 列宽记忆（列 id → 宽度）
    var columnWidths: [String: CGFloat] = [:]

    enum CodingKeys: String, CodingKey {
        case id, name, systemImage, kind, fields, fieldOrder, rows, views
        case currentViewID, columnLayout, columnWidths, createdAt
    }

    /// 兼容旧数据：缺失键用默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "新表"
        systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage) ?? "tablecells"
        kind = try c.decodeIfPresent(TableKind.self, forKey: .kind) ?? .custom
        fields = try c.decodeIfPresent([CustomField].self, forKey: .fields) ?? []
        fieldOrder = try c.decodeIfPresent([UUID].self, forKey: .fieldOrder) ?? []
        rows = try c.decodeIfPresent([DBRow].self, forKey: .rows) ?? []
        views = try c.decodeIfPresent([ListView].self, forKey: .views) ?? [ListView(name: "全部")]
        currentViewID = try c.decodeIfPresent(UUID.self, forKey: .currentViewID)
        columnLayout = try c.decodeIfPresent([String].self, forKey: .columnLayout) ?? []
        columnWidths = try c.decodeIfPresent([String: CGFloat].self, forKey: .columnWidths) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    init(id: UUID = UUID(), name: String, systemImage: String = "tablecells",
         kind: TableKind = .custom, fields: [CustomField] = []) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.kind = kind
        self.fields = fields
        self.views = [ListView(name: "全部")]
    }

    /// 按保存顺序排列的字段
    var orderedFields: [CustomField] {
        var result: [CustomField] = []
        var consumed = Set<UUID>()
        for fieldID in fieldOrder {
            if let f = fields.first(where: { $0.id == fieldID }) {
                result.append(f)
                consumed.insert(f.id)
            }
        }
        for f in fields where !consumed.contains(f.id) {
            result.append(f)
        }
        return result
    }

    /// 可见列 id 列表（隐藏列由视图控制）
    func visibleColumns(for view: ListView) -> [CustomField] {
        orderedFields.filter { !view.hiddenColumnIDs.contains($0.id.uuidString) }
    }

    var currentView: ListView {
        view(id: currentViewID) ?? views.first ?? ListView(name: "全部")
    }

    func view(id: UUID?) -> ListView? {
        views.first { $0.id == id }
    }

    /// 关联学生字段的定义（每表最多一个，取第一个）
    var linkField: CustomField? {
        fields.first { $0.type == .linkStudents }
    }

    /// 行 id 集合（隐藏行判断等场景）
    func row(id: UUID) -> DBRow? {
        rows.first { $0.id == id }
    }
}

/// 通用表的一行：字段字典 + 时间戳
struct DBRow: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var values: [String: CustomValue] = [:]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(values: [String: CustomValue] = [:]) {
        self.values = values
    }
}

// MARK: - 通用表查询（表内筛选 / 排序 / 列筛选）

enum TableQuery {

    /// 行的某个字段显示文本；关联学生解析为学生名（缺失学生显示占位）
    static func displayText(of row: DBRow, field: CustomField, studentName: (UUID) -> String) -> String {
        guard let value = row.values[field.id.uuidString] else { return "" }
        if case .link(let ids) = value {
            return ids.map { studentName($0) }.joined(separator: "、")
        }
        return value.displayText
    }

    /// 视图筛选 + 排序（关键字全字段匹配；condition 中通用可用的部分生效）
    static func apply(view: ListView, rows: [DBRow], fields: [CustomField],
                      studentName: (UUID) -> String) -> [DBRow] {
        var list = rows
        switch view.condition {
        case .all:
            break
        case .columnContains(let columnID, let value):
            if let field = fields.first(where: { $0.id.uuidString == columnID }) {
                list = list.filter {
                    displayText(of: $0, field: field, studentName: studentName)
                        .localizedCaseInsensitiveContains(value)
                }
            }
        case .customField(let fieldID, let value):
            if let field = fields.first(where: { $0.id == fieldID }) {
                list = list.filter {
                    displayText(of: $0, field: field, studentName: studentName)
                        .localizedCaseInsensitiveContains(value)
                }
            }
        case .policeStation, .boarding:
            break // 仅学生表语义
        }

        let keyword = view.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            list = list.filter { row in
                fields.contains { field in
                    displayText(of: row, field: field, studentName: studentName)
                        .localizedCaseInsensitiveContains(keyword)
                }
            }
        }

        // 排序：按字段；linkStudents 列按学生数/姓名稳定性即可（用显示文本）
        if let sortField = fields.first(where: { $0.id.uuidString == view.sortKey.rawValue }) {
            list.sort { a, b in
                let ta = displayText(of: a, field: sortField, studentName: studentName)
                let tb = displayText(of: b, field: sortField, studentName: studentName)
                return view.sortAscending
                    ? ta.localizedStandardCompare(tb) == .orderedAscending
                    : ta.localizedStandardCompare(tb) == .orderedDescending
            }
        } else if view.sortKey == .createdAt {
            list.sort { view.sortAscending ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt }
        } else if view.sortKey == .updatedAt {
            list.sort { view.sortAscending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt }
        }
        return list
    }

    /// Excel 式列筛选（与列显示文本匹配；多个筛选取交集，叠加在视图条件上）
    static func applyColumnFilters(_ rows: [DBRow], fields: [CustomField],
                                   filters: [String: ColumnFilter],
                                   studentName: (UUID) -> String) -> [DBRow] {
        let active = filters.filter { $0.value.isActive }
        guard !active.isEmpty else { return rows }
        return rows.filter { row in
            active.allSatisfy { columnID, filter in
                guard let field = fields.first(where: { $0.id.uuidString == columnID }) else { return true }
                let text = displayText(of: row, field: field, studentName: studentName)
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

    /// 某列出现过的全部显示值（筛选值清单）
    static func distinctValues(field: CustomField, in rows: [DBRow],
                               studentName: (UUID) -> String) -> [String] {
        Array(Set(rows.map { displayText(of: $0, field: field, studentName: studentName) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - 记录表默认结构

extension DBTable {

    /// 新项目的默认记录表（四类，按 ProjectData.defaultRecordTypes）
    static func defaultRecordTables() -> [DBTable] {
        ProjectData.defaultRecordTypes.map {
            recordTable(name: $0, recordTypes: ProjectData.defaultRecordTypes)
        }
    }

    /// 记录类表的默认字段：日期 / 关联学生 / 内容
    static func recordTable(name: String, recordTypes: [String]) -> DBTable {
        var typeField = CustomField(name: "类型", type: .choice(options: recordTypes))
        typeField.id = UUID(uuidString: "C0FFEE00-0000-0000-0000-B0A2E5C0DE01")!
        var dateField = CustomField(name: "日期", type: .date)
        dateField.id = UUID(uuidString: "C0FFEE00-0000-0000-0000-000000000002")!
        var linkField = CustomField(name: "学生", type: .linkStudents)
        linkField.id = UUID(uuidString: "C0FFEE00-0000-0000-0000-000000000003")!
        var contentField = CustomField(name: "内容", type: .address)
        contentField.id = UUID(uuidString: "C0FFEE00-0000-0000-0000-000000000004")!
        let fields = [dateField, typeField, linkField, contentField]
        var table = DBTable(name: name, systemImage: "square.and.pencil", kind: .record, fields: fields)
        table.createdAt = Date()
        table.fieldOrder = fields.map { $0.id }
        // 记录表默认视图按日期倒序（最新在前）
        var view = table.views[0]
        view.sortKey = .createdAt
        view.sortAscending = false
        table.views = [view]
        table.currentViewID = view.id
        return table
    }
}
