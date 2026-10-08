import SwiftUI

// MARK: - 自定义字段管理

struct FieldsManagerSheet: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newType: FieldType = .text
    @State private var pendingDelete: CustomField?

    var body: some View {
        VStack(spacing: 0) {
            Text("管理自定义字段")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 6)

            Text("自定义字段会出现在每位学生的“其他信息”里，可按需增加，如：班级、性别、出生日期、户籍地址等。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()

            List {
                Section("内置字段（姓名、学号必备；其余可删除）") {
                    ForEach(store.data.visibleBuiltinFields, id: \.rawValue) { field in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.square")
                                .foregroundStyle(.secondary)
                            Text(field.title)
                                .frame(width: 170, alignment: .leading)
                            Spacer()
                            Button {
                                store.moveBuiltinField(key: field.rawValue, offset: -1)
                            } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless)
                                .help("上移")
                            Button {
                                store.moveBuiltinField(key: field.rawValue, offset: 1)
                            } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.borderless)
                                .help("下移")
                            Button(role: .destructive) {
                                store.hardDeleteBuiltinField(key: field.rawValue)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(ProjectStore.protectedBuiltinFields.contains(field.rawValue))
                                .help(ProjectStore.protectedBuiltinFields.contains(field.rawValue)
                                      ? "姓名和学号为必备字段，不可删除"
                                      : "删除字段及其全部数据")
                        }
                        .padding(.vertical, 2)
                    }
                    if !store.data.deletedBuiltinFields.isEmpty {
                        ForEach(store.data.builtinOrder.compactMap { StudentTableField(rawValue: $0) }
                                .filter { store.data.deletedBuiltinFields.contains($0.rawValue) },
                                id: \.rawValue) { field in
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.uturn.backward")
                                    .foregroundStyle(.orange)
                                Text(field.title)
                                    .foregroundStyle(.secondary)
                                    .strikethrough()
                                    .frame(width: 170, alignment: .leading)
                                Spacer()
                                Button("恢复") {
                                    store.restoreBuiltinField(key: field.rawValue)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("自定义字段") {
                    if store.data.orderedFields.isEmpty {
                        Text("还没有自定义字段，在下方添加。")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(store.data.orderedFields.enumerated()), id: \.element.id) { index, field in
                        FieldRow(field: field,
                                 canMoveUp: index > 0,
                                 canMoveDown: index < store.data.orderedFields.count - 1,
                                 onMove: { offset in store.moveField(id: field.id, offset: offset) },
                                 onUpdate: { store.updateField($0) },
                                 onTypeChange: { fieldID, newType in
                                     store.changeFieldType(fieldID: fieldID, to: newType)
                                 },
                                 onDelete: { pendingDelete = field })
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                TextField("字段名称，如：班级", text: $newName)
                    .onSubmit(addField)
                Picker("", selection: $newType) {
                    ForEach(FieldType.selectableTypes, id: \.id) { t in
                        Label(t.displayName, systemImage: t.systemImage).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                Button("添加字段", action: addField)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 520)
        .confirmationDialog(
            "删除字段「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除字段", role: .destructive) {
                if let field = pendingDelete {
                    store.deleteField(id: field.id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有学生填写的该字段内容将被清除。")
        }
    }

    private func addField() {
        store.addField(name: newName, type: newType)
        newName = ""
        newType = .text
    }
}

private struct FieldRow: View {
    @State var field: CustomField
    var canMoveUp = true
    var canMoveDown = true
    var onMove: (Int) -> Void = { _ in }
    let onUpdate: (CustomField) -> Void
    /// 类型切换走带数据转换的 API（存量学生字段值同步转换）
    var onTypeChange: (UUID, FieldType) -> Void = { _, _ in }
    let onDelete: () -> Void

    /// 选项条目（单选/多选共用，+/− 编辑）
    @State private var optionRows: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: field.type.systemImage)
                    .foregroundStyle(.secondary)
                TextField("名称", text: Binding(
                    get: { field.name },
                    set: { field.name = $0; onUpdate(field) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                Spacer()
                Button { onMove(-1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveUp)
                    .help("上移")
                Button { onMove(1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveDown)
                    .help("下移")
                Picker("", selection: Binding(
                    get: { field.type },
                    set: { newValue in
                        // 类型切换：单选/多选之间互转保留选项列表；值转换交给 store
                        func extractOptions(_ t: FieldType) -> [String] {
                            if case .choice(let o) = t { return o }
                            if case .multiChoice(let o) = t { return o }
                            return []
                        }
                        let oldOptions = extractOptions(field.type)
                        if case .choice = newValue {
                            field.type = .choice(options: oldOptions)
                        } else if case .multiChoice = newValue {
                            field.type = .multiChoice(options: oldOptions)
                        } else {
                            field.type = newValue
                        }
                        onTypeChange(field.id, field.type)
                    }
                )) {
                    ForEach(FieldType.selectableTypes, id: \.id) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除字段")
            }
            if case .choice(let options) = field.type {
                optionsEditor(placeholder: "选项（用、或,分隔），如：男、女", options: options)
            } else if case .multiChoice(let options) = field.type {
                optionsEditor(placeholder: "选项（用、或,分隔），可多选，如：团员、班干部、住宿生", options: options)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func optionsEditor(placeholder: String, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(optionRows.indices), id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("选项 \(index + 1)", text: Binding(
                        get: { optionRows.indices.contains(index) ? optionRows[index] : "" },
                        set: { newValue in
                            if optionRows.indices.contains(index) {
                                optionRows[index] = newValue
                                commitOptions()
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    // 减号：删除该条目
                    Button {
                        guard optionRows.indices.contains(index) else { return }
                        optionRows.remove(at: index)
                        commitOptions()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("删除该选项")
                }
            }
            // 加号：添加选项条目
            Button {
                optionRows.append("")
            } label: {
                Label("添加选项", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("新增一个选项")
        }
        .onAppear {
            optionRows = options.isEmpty ? [""] : options
        }
    }

    private func commitOptions() {
        let options = optionRows
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 保持当前是单选还是多选，仅更新选项
        if case .multiChoice = field.type {
            field.type = .multiChoice(options: options)
        } else {
            field.type = .choice(options: options)
        }
        onUpdate(field)
    }
}

// MARK: - 记录类型管理

struct RecordTypesSheet: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("管理记录类型")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 6)

            Text("记录类型用于分类关心关爱记录。删除类型不影响已有记录的显示。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()

            List {
                ForEach(store.data.recordTypes.indices, id: \.self) { index in
                    HStack {
                        TextField("类型名称", text: Binding(
                            get: { store.data.recordTypes[index] },
                            set: { store.updateRecordType(at: index, to: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            store.deleteRecordType(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除类型")
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                Button("恢复默认分类…", role: .destructive) {
                    showRestoreDefaults = true
                }
                Spacer()
                TextField("新类型名称，如：心理辅导", text: $newName)
                    .onSubmit(addType)
                Button("添加类型", action: addType)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 420, height: 380)
        .confirmationDialog(
            "恢复默认分类？",
            isPresented: $showRestoreDefaults,
            titleVisibility: .visible
        ) {
            Button("恢复为默认分类", role: .destructive) {
                store.setRecordTypes(ProjectData.defaultRecordTypes)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将替换为：\(ProjectData.defaultRecordTypes.joined(separator: "、"))。当前自定义类型会被移除（已有记录保留原类别文字）。")
        }
    }

    @State private var showRestoreDefaults = false

    private func addType() {
        store.addRecordType(newName)
        newName = ""
    }
}
