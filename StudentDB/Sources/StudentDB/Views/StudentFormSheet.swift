import SwiftUI

/// 新建 / 编辑学生表单
struct StudentFormSheet: View {
    enum Mode: Equatable {
        case add
        case edit(Student)
    }

    @ObservedObject var store: ProjectStore
    let mode: Mode
    var onAdded: ((Student) -> Void)?

    @Environment(\.dismiss) private var dismiss

    // 表单状态
    @State private var name = ""
    @State private var studentNumber = ""
    @State private var isBoarding = false
    @State private var phone = ""
    @State private var boardingAddress = ""
    @State private var policeStation = ""
    @State private var guardians: [Guardian] = []
    @State private var customTexts: [String: String] = [:]
    @State private var customNumbers: [String: String] = [:]
    @State private var customDates: [String: Date] = [:]
    @State private var customBools: [String: Bool] = [:]
    @State private var customLinkIDs: [String: [UUID]] = [:]

    @State private var attemptedSave = false

    /// 表单平铺锚点：统一布局顺序（内置 + 监护人组 + 自定义），无分组
    private var formAnchors: [String] {
        let full = store.data.columnLayout.isEmpty ? store.currentColumnLayout() : store.data.columnLayout
        var anchors: [String] = []
        var guardianGroups = 1
        for id in full {
            let anchorID: String?
            if let field = StudentTableField(rawValue: id) {
                anchorID = (field == .recordCount || !builtinVisible(field.rawValue)) ? nil : id
            } else if id.hasPrefix("guardian") {
                if id.hasSuffix("-name") {
                    let slot = id.dropLast(5) // "guardianN"
                    let n = Int(slot.dropFirst(8)) ?? 1
                    guardianGroups = max(guardianGroups, n)
                    anchorID = id
                } else {
                    anchorID = nil
                }
            } else {
                anchorID = store.data.orderedFields.contains { $0.id.uuidString == id } ? id : nil
            }
            if let anchorID, !anchors.contains(anchorID) {
                anchors.append(anchorID)
            }
        }
        // 监护人组数：布局组数、当前编辑的组数、至少 1 取最大；不足的组锚点追加尾部
        let groups = max(guardianGroups, max(guardians.count, 1))
        for n in 1...groups {
            let id = "guardian\(n)-name"
            if !anchors.contains(id) {
                anchors.append(id)
            }
        }
        return anchors
    }

    /// 平铺渲染每个锚点
    @ViewBuilder
    private func formSection(for anchor: String, isLast: Bool) -> some View {
        if let field = StudentTableField(rawValue: anchor) {
            switch field {
            case .name:
                formRow("姓名", required: true) { TextField("必填", text: $name) }
            case .studentNumber:
                formRow("学号", required: true) { TextField("必填，不能与其他学生重复", text: $studentNumber) }
            case .boarding:
                formRow("是否住宿") {
                    Picker("", selection: $isBoarding) {
                        Text("走读").tag(false)
                        Text("住宿").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
            case .phone:
                formRow("联系电话") { TextField("选填", text: $phone) }
            case .boardingAddress:
                formRow("住宿地址") { TextField("选填", text: $boardingAddress) }
            case .policeStation:
                formRow("对应派出所") { TextField("选填", text: $policeStation) }
            case .recordCount:
                EmptyView()
            }
            if !isLast { Divider() }
        } else if anchor.hasPrefix("guardian"), anchor.hasSuffix("-name") {
            let slot = Int(anchor.dropFirst(8).dropLast(5)) ?? 1
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("监护人\(slot)")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    // 只在第一组显示添加按钮，避免重复
                    if slot == 1 {
                        Button {
                            withAnimation { guardians.append(Guardian()) }
                        } label: {
                            Label("添加监护人", systemImage: "plus")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.top, 6)
                if guardians.indices.contains(slot - 1) {
                    GuardianEditorRow(guardian: $guardians[slot - 1]) {
                        removeGuardianGroup(at: slot - 1)
                    }
                }
            }
            if !isLast { Divider().padding(.top, 8) }
        } else if let fieldDef = store.data.orderedFields.first(where: { $0.id.uuidString == anchor }) {
            customFieldRow(fieldDef)
            if !isLast { Divider() }
        }
    }

    private func removeGuardianGroup(at index: Int) {
        withAnimation {
            guardians.remove(at: index)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(mode == .add ? "添加学生" : "编辑学生信息")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 所有字段按统一布局平铺（与表格列/详情行拖拽顺序一致），不做分组
                    ForEach(Array(formAnchors.enumerated()), id: \.offset) { index, anchor in
                        formSection(for: anchor, isLast: index == formAnchors.count - 1)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            Divider()
            HStack {
                if let message = validationMessage, attemptedSave {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .add ? "添加" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear(perform: loadInitialValues)
    }

    // MARK: - 行布局


    /// 内置字段是否可见（未被软删除）
    private func builtinVisible(_ key: String) -> Bool {
        !store.data.deletedBuiltinFields.contains(key)
    }

    private func formRow<Content: View>(_ label: String, required: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 2) {
                Text(label)
                if required {
                    Text("*").foregroundStyle(.red)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 92, alignment: .trailing)
            content()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func customFieldRow(_ field: CustomField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                Text(field.name)
                Image(systemName: field.type.systemImage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 92, alignment: .trailing)
            switch field.type {
            case .text:
                TextField("选填", text: textBinding(field))
            case .phone:
                TextField("选填", text: textBinding(field))
                    .overlay(alignment: .trailing) {
                        if let s = customTexts[field.id.uuidString], !s.isEmpty, !FieldFormat.isValidPhone(s) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("电话格式不正确（7-15 位数字，可带 +86/-/空格）")
                        }
                    }
            case .idCard:
                TextField("选填", text: textBinding(field))
                    .overlay(alignment: .trailing) {
                        if let s = customTexts[field.id.uuidString], !s.isEmpty, !FieldFormat.isValidIDCard(s) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("身份证号应为 18 位（含校验码，末位可为 X）或 15 位")
                        }
                    }
            case .number:
                TextField("选填", text: numberBinding(field))
            case .date:
                DatePicker("", selection: dateBinding(field), displayedComponents: .date)
                    .labelsHidden()
            case .boolean:
                Toggle("", isOn: boolBinding(field))
                    .toggleStyle(.switch)
                    .labelsHidden()
            case .choice(let options):
                Picker("", selection: choiceBinding(field)) {
                    Text("未选择").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            case .multiChoice(let options):
                MultiChoicePicker(options: options, selection: multiBinding(field))
            case .address:
                TextEditor(text: addressBinding(field))
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            case .dateTime:
                DatePicker("", selection: dateBinding(field))
                    .labelsHidden()
            case .linkStudents:
                Text("不支持在学生表单中编辑")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .attachment:
                Text("在详情页附件区管理")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    // 自定义字段绑定

    private func textBinding(_ field: CustomField) -> Binding<String> {
        Binding(
            get: { customTexts[field.id.uuidString] ?? "" },
            set: { customTexts[field.id.uuidString] = $0 }
        )
    }

    private func numberBinding(_ field: CustomField) -> Binding<String> {
        Binding(
            get: { customNumbers[field.id.uuidString] ?? "" },
            set: { customNumbers[field.id.uuidString] = $0 }
        )
    }

    private func dateBinding(_ field: CustomField) -> Binding<Date> {
        Binding(
            get: { customDates[field.id.uuidString] ?? Date() },
            set: { customDates[field.id.uuidString] = $0 }
        )
    }

    private func choiceBinding(_ field: CustomField) -> Binding<String> {
        textBinding(field)
    }

    /// 多选绑定：数组 ⇄ 顿号拼接文本
    private func multiBinding(_ field: CustomField) -> Binding<[String]> {
        Binding(
            get: {
                (customTexts[field.id.uuidString] ?? "")
                    .components(separatedBy: "、").filter { !$0.isEmpty }
            },
            set: { customTexts[field.id.uuidString] = $0.joined(separator: "、") }
        )
    }

    private func addressBinding(_ field: CustomField) -> Binding<String> {
        textBinding(field)
    }

    private func boolBinding(_ field: CustomField) -> Binding<Bool> {
        Binding(
            get: { customBools[field.id.uuidString] ?? false },
            set: { customBools[field.id.uuidString] = $0 }
        )
    }

    // MARK: - 逻辑

    private var validationMessage: String? {
        if builtinVisible("name"), name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写姓名"
        }
        let number = studentNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if builtinVisible("studentNumber"), number.isEmpty {
            return "请填写学号"
        }
        let excluding: UUID? = if case .edit(let s) = mode { s.id } else { nil }
        if store.isStudentNumberTaken(studentNumber, excluding: excluding) {
            return "学号「\(number)」已被其他学生使用"
        }
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPhone.isEmpty && !FieldFormat.isValidPhone(trimmedPhone) {
            return "电话格式不正确：应为 7-15 位数字（可含 +86 或 - 分隔）"
        }
        return nil
    }

    private func loadInitialValues() {
        guard case .edit(let student) = mode else {
            guardians = [Guardian()]
            return
        }
        name = student.name
        studentNumber = student.studentNumber
        isBoarding = student.isBoarding
        phone = student.phone
        boardingAddress = student.boardingAddress
        policeStation = student.policeStation
        guardians = student.guardians.isEmpty ? [] : student.guardians
        for field in store.data.fieldDefinitions {
            guard let value = student.customValues[field.id.uuidString] else { continue }
            switch value {
            case .text(let s): customTexts[field.id.uuidString] = s
            case .number(let n): customNumbers[field.id.uuidString] = n == n.rounded() ? String(Int(n)) : String(n)
            case .date(let d): customDates[field.id.uuidString] = d
            case .boolean(let b): customBools[field.id.uuidString] = b
            case .link(let ids): customLinkIDs[field.id.uuidString] = ids
            }
        }
    }

    private func save() {
        attemptedSave = true
        guard validationMessage == nil else {
            NSSound.beep()
            return
        }

        var student: Student
        if case .edit(let existing) = mode {
            student = existing
        } else {
            student = Student()
        }

        student.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        student.studentNumber = studentNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        student.isBoarding = isBoarding
        student.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        student.boardingAddress = boardingAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        student.policeStation = policeStation.trimmingCharacters(in: .whitespacesAndNewlines)
        student.guardians = guardians.filter { !$0.isEmpty }

        var values = student.customValues
        for field in store.data.fieldDefinitions {
            switch field.type {
            case .text, .phone, .idCard:
                if let s = customTexts[field.id.uuidString], !s.isEmpty {
                    values[field.id.uuidString] = .text(s)
                } else {
                    values.removeValue(forKey: field.id.uuidString)
                }
            case .number:
                if let s = customNumbers[field.id.uuidString], let n = Double(s) {
                    values[field.id.uuidString] = .number(n)
                } else {
                    values.removeValue(forKey: field.id.uuidString)
                }
            case .date:
                if let d = customDates[field.id.uuidString] {
                    values[field.id.uuidString] = .date(d)
                } else {
                    values.removeValue(forKey: field.id.uuidString)
                }
            case .boolean:
                if let b = customBools[field.id.uuidString] {
                    values[field.id.uuidString] = .boolean(b)
                } else {
                    values.removeValue(forKey: field.id.uuidString)
                }
            case .choice, .multiChoice, .address:
                if let s = customTexts[field.id.uuidString], !s.isEmpty {
                    values[field.id.uuidString] = .text(s)
                } else {
                    values.removeValue(forKey: field.id.uuidString)
                }
            case .dateTime:
                if let d = customDates[field.id.uuidString] {
                    values[field.id.uuidString] = .date(d)
                } else {
                    values.removeValue(forKey: field.id.uuidString)
                }
            case .linkStudents, .attachment:
                break
            }
        }
        student.customValues = values

        switch mode {
        case .add:
            store.addStudent(student)
            onAdded?(student)
        case .edit:
            store.updateStudent(student)
        }
        dismiss()
    }
}

// MARK: - 快速添加自定义字段

struct AddFieldPopover: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: FieldType = .text
    /// 选项条目（单选/多选，+/− 编辑）
    @State private var optionRows: [String] = [""]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加自定义字段")
                .font(.headline)
            TextField("字段名称，如：班级", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Picker("类型", selection: $type) {
                ForEach(FieldType.selectableTypes, id: \.id) { t in
                    Label(t.displayName, systemImage: t.systemImage).tag(t)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            if type.sameKind(as: .choice(options: [])) || type.sameKind(as: .multiChoice(options: [])) {
                // 选项条目列表：每行一个选项，− 删除、+ 添加
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(optionRows.indices), id: \.self) { index in
                        HStack(spacing: 6) {
                            TextField("选项 \(index + 1)，如：男", text: Binding(
                                get: { optionRows.indices.contains(index) ? optionRows[index] : "" },
                                set: { newValue in
                                    if optionRows.indices.contains(index) {
                                        optionRows[index] = newValue
                                    }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            Button {
                                guard optionRows.indices.contains(index) else { return }
                                optionRows.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("删除该选项")
                        }
                    }
                    Button {
                        optionRows.append("")
                    } label: {
                        Label("添加选项", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private var trimmedOptions: [String] {
        optionRows
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func add() {
        let finalType: FieldType
        if type.sameKind(as: .choice(options: [])) {
            finalType = .choice(options: trimmedOptions)
        } else if type.sameKind(as: .multiChoice(options: [])) {
            finalType = .multiChoice(options: trimmedOptions)
        } else {
            finalType = type
        }
        store.addField(name: name, type: finalType)
        name = ""
        type = .text
        optionRows = [""]
        dismiss()
    }
}

// MARK: - 监护人编辑行

private struct GuardianEditorRow: View {
    @Binding var guardian: Guardian
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("姓名", text: $guardian.name)
                .frame(width: 110)
            TextField("关系（父/母/祖父…）", text: $guardian.relation)
                .frame(width: 150)
            TextField("电话", text: $guardian.phone)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("移除该监护人")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 多选组件（表单用）

struct MultiChoicePicker: View {
    let options: [String]
    @Binding var selection: [String]

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    if selection.contains(option) {
                        selection.removeAll { $0 == option }
                    } else {
                        selection.append(option)
                    }
                } label: {
                    if selection.contains(option) {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
            if !selection.isEmpty {
                Divider()
                Button("清除已选", role: .destructive) { selection.removeAll() }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.isEmpty ? "选择…" : selection.joined(separator: "、"))
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                Image(systemName: "checklist")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
