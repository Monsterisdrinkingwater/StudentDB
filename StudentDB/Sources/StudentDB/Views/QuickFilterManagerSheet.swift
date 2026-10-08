import SwiftUI

// MARK: - 统一构造器的纯逻辑（便于测试）

/// 值输入控件的形态：由列类型决定
enum QuickFilterValueInput: Equatable {
    /// 勾选列：二选一（匹配文字用列的实际显示值：内置住宿列为「住宿/走读」，自定义是/否列为「是/否」）
    case boolPick(trueValue: String, falseValue: String)
    /// 单选/多选列：从选项中选一个（筛选 = 包含该选项）
    case options([String])
    /// 其他列：输入包含文字（附现有值建议）
    case text
}

enum QuickFilterBuilder {

    static func valueInput(for spec: StudentColumnSpec) -> QuickFilterValueInput {
        switch spec.cellKind {
        case .checkbox:
            if spec.field == .boarding {
                return .boolPick(trueValue: "住宿", falseValue: "走读")
            }
            return .boolPick(trueValue: "是", falseValue: "否")
        case .choice(let options):
            return .options(options)
        case .multiChoice(let options):
            return .options(options)
        default:
            return .text
        }
    }

    /// 生成条件：统一为「列包含值」
    static func condition(columnID: String, value: String) -> QuickCondition {
        .columnContains(columnID: columnID, value: value)
    }

    /// 标签列表里的条件说明（新条件带列名；旧条件类型沿用原描述）
    static func caption(for condition: QuickCondition, columns: [StudentColumnSpec]) -> String {
        switch condition {
        case .columnContains(let columnID, let value):
            if let title = columns.first(where: { $0.id == columnID })?.title {
                return "「\(title)」包含「\(value)」"
            }
            return "包含「\(value)」"
        case .customField(let fieldID, let value):
            if let title = columns.first(where: { $0.customField?.id == fieldID })?.title {
                return "「\(title)」包含「\(value)」"
            }
            return condition.displayName
        default:
            return condition.displayName
        }
    }
}

// MARK: - 快捷筛选标签管理

/// 管理侧栏快捷筛选标签：查看、添加、删除。
/// 添加统一为「选一列 + 选/输一个值」，列类型决定值控件。
struct QuickFilterManagerSheet: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var columnID: String?
    @State private var boolValue = true
    @State private var optionValue = ""
    @State private var textValue = ""

    /// 可选的列（内置按顺序过滤已删 + 监护人 + 自定义按顺序）
    private var queryColumns: [StudentColumnSpec] {
        StudentColumnSpec.allColumns(fields: store.data.orderedFields, guardianSlots: 1,
                                     builtinOrder: store.data.builtinOrder,
                                     deletedBuiltin: store.data.deletedBuiltinFields)
    }

    private var selectedColumn: StudentColumnSpec? {
        queryColumns.first { $0.id == columnID }
    }

    private var valueInput: QuickFilterValueInput? {
        selectedColumn.map { QuickFilterBuilder.valueInput(for: $0) }
    }

    /// 当前选定的筛选值（nil = 还不能添加）
    private var currentValue: String? {
        guard let input = valueInput else { return nil }
        switch input {
        case .boolPick(let trueValue, let falseValue):
            return boolValue ? trueValue : falseValue
        case .options:
            return optionValue.isEmpty ? nil : optionValue
        case .text:
            let v = textValue.trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
    }

    private var suggestedName: String {
        guard let column = selectedColumn, let value = currentValue else { return "新筛选" }
        return "\(column.title)：\(value)"
    }

    private var canAdd: Bool {
        currentValue != nil
    }

    /// 文本列的现有值建议（点击填入）
    private var suggestions: [String] {
        guard case .text = valueInput, let column = selectedColumn else { return [] }
        return Array(StudentQuery.distinctValues(column: column, in: store.data.students).prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("快捷筛选标签")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Text("标签显示在侧栏顶部，点击即可应用到当前列表的筛选。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            Divider()

            List {
                Section {
                    HStack {
                        Text("全部")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("固定标签 · 不筛选")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("内置")
                }

                Section {
                    if store.data.quickFilters.isEmpty {
                        Text("暂无自定义标签，在下方添加。")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(store.data.quickFilters) { filter in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(filter.name)
                                    .font(.callout.weight(.medium))
                                Text(QuickFilterBuilder.caption(for: filter.condition, columns: queryColumns))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.deleteQuickFilter(id: filter.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除标签")
                        }
                    }
                } header: {
                    Text("自定义标签")
                }

                Section {
                    TextField("标签名称（留空自动取名）", text: $newName)
                    Picker("筛选列", selection: $columnID) {
                        ForEach(queryColumns) { spec in
                            Label(spec.title, systemImage: columnIcon(spec))
                                .tag(Optional(spec.id))
                        }
                    }
                    valueRow
                    Button("添加标签", action: add)
                        .disabled(!canAdd)
                } header: {
                    Text("添加标签")
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onAppear {
            if columnID == nil { columnID = queryColumns.first?.id }
        }
        .onChange(of: columnID) { _ in resetValueInput() }
    }

    /// 按列类型显示对应的值控件
    @ViewBuilder
    private var valueRow: some View {
        switch valueInput {
        case .boolPick(let trueValue, let falseValue):
            Picker("值", selection: Binding(
                get: { boolValue ? trueValue : falseValue },
                set: { boolValue = $0 == trueValue }
            )) {
                Text(trueValue).tag(trueValue)
                Text(falseValue).tag(falseValue)
            }
        case .options(let options):
            Picker("值", selection: $optionValue) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        case .text:
            HStack {
                TextField("包含的文字（模糊匹配，不区分大小写）", text: $textValue)
                if !suggestions.isEmpty {
                    Menu("现有值…") {
                        ForEach(suggestions, id: \.self) { value in
                            Button(value) { textValue = value }
                        }
                    }
                    .fixedSize()
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func resetValueInput() {
        boolValue = true
        optionValue = ""
        textValue = ""
        if case .options(let options) = valueInput {
            optionValue = options.first ?? ""
        }
    }

    private func columnIcon(_ spec: StudentColumnSpec) -> String {
        if let custom = spec.customField { return custom.type.systemImage }
        switch spec.field {
        case .name: return "person"
        case .studentNumber: return "number"
        case .boarding: return "bed.double"
        case .phone: return "phone"
        case .boardingAddress: return "house"
        case .policeStation: return "shield"
        case .recordCount: return "doc.text"
        case nil: return "person.2" // 监护人列
        }
    }

    private func add() {
        guard let column = selectedColumn, let value = currentValue else { return }
        let condition = QuickFilterBuilder.condition(columnID: column.id, value: value)
        let name = newName.trimmingCharacters(in: .whitespaces)
        store.addQuickFilter(QuickFilter(name: name.isEmpty ? suggestedName : name, condition: condition))
        newName = ""
        textValue = ""
    }
}
