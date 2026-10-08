import SwiftUI

/// 批量修改：多选学生后，选一个字段统一赋值（类 SQL：UPDATE ... SET 字段=值 WHERE 选中）
struct BatchEditSheet: View {
    @ObservedObject var store: ProjectStore
    /// 目标学生（表格当前多选）
    let studentIDs: Set<UUID>

    @Environment(\.dismiss) private var dismiss

    /// 可批量修改的列（全部可编辑列）
    private var editableColumns: [StudentColumnSpec] {
        StudentColumnSpec.allColumns(
            fields: store.data.orderedFields,
            guardianSlots: 1,
            builtinOrder: store.data.builtinOrder,
            deletedBuiltin: store.data.deletedBuiltinFields
        ).filter { $0.cellKind != .readonly }
    }

    @State private var columnID: String?
    @State private var textValue = ""
    @State private var boolValue = false
    @State private var dateValue = Date()

    private var selectedColumn: StudentColumnSpec? {
        editableColumns.first { $0.id == columnID }
    }

    /// 是否可应用：文本类需非空
    private var canApply: Bool {
        guard let spec = selectedColumn else { return false }
        switch spec.cellKind {
        case .text, .choice, .multiChoice:
            return !textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("批量修改")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 4)
            Text("将统一修改选中的 \(studentIDs.count) 名学生")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            Divider()

            Form {
                Picker("修改字段", selection: $columnID) {
                    ForEach(editableColumns) { spec in
                        Text(spec.title).tag(Optional(spec.id))
                    }
                }
                if let spec = selectedColumn {
                    valueEditor(for: spec)
                    Text(appliedDescription(for: spec))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("应用到 \(studentIDs.count) 人", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: 380)
        .onAppear {
            columnID = editableColumns.first?.id
        }
    }

    // MARK: 值控件（按字段类型）

    @ViewBuilder
    private func valueEditor(for spec: StudentColumnSpec) -> some View {
        switch spec.cellKind {
        case .text:
            TextField("新值", text: $textValue)
        case .checkbox:
            Picker("新值", selection: $boolValue) {
                Text("是（住宿）").tag(true)
                Text("否（走读）").tag(false)
            }
            .pickerStyle(.radioGroup)
        case .datePicker:
            DatePicker("新值", selection: $dateValue, displayedComponents: .date)
        case .dateTimePicker:
            DatePicker("新值", selection: $dateValue)
        case .choice(let options):
            Picker("新值", selection: $textValue) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .multiChoice(let options):
            MultiChoicePicker(options: options, selection: multiBinding)
        case .readonly:
            EmptyView()
        }
    }

    private var multiBinding: Binding<[String]> {
        Binding(
            get: {
                textValue.components(separatedBy: "、").filter { !$0.isEmpty }
            },
            set: { textValue = $0.joined(separator: "、") }
        )
    }

    private func appliedDescription(for spec: StudentColumnSpec) -> String {
        switch spec.cellKind {
        case .text, .choice, .multiChoice:
            return "所有选中学生的「\(spec.title)」将设为：\(textValue)"
        case .checkbox:
            return "所有选中学生的「\(spec.title)」将设为：\(boolValue ? "是" : "否")"
        case .datePicker, .dateTimePicker:
            return "所有选中学生的「\(spec.title)」将设为：\(Fmt.dateTime.string(from: dateValue))"
        case .readonly:
            return ""
        }
    }

    // MARK: 应用

    private func apply() {
        guard let spec = selectedColumn else { return }
        let edit: CellEdit
        switch spec.cellKind {
        case .text, .choice, .multiChoice:
            edit = .text(textValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .checkbox:
            edit = .boolean(boolValue)
        case .datePicker, .dateTimePicker:
            edit = .date(dateValue)
        case .readonly:
            return
        }

        var applied = 0
        for id in studentIDs {
            guard let student = store.student(id: id) else { continue }
            let updated = spec.applying(edit, to: student)
            if updated != student {
                store.updateStudent(updated)
                applied += 1
            }
        }
        // 批量操作立即落盘
        try? store.saveNow()
        _ = applied
        dismiss()
    }
}
