import SwiftUI

// MARK: - 新增 / 编辑学生表单（iOS）

/// 新增 / 编辑学生表单。
/// 字段对照 macOS StudentFormSheet：姓名（必填）/ 学号 / 住宿 Toggle / 电话 / 住宿地址 / 派出所 / 监护人组。
/// 自定义字段不在本表单编辑：编辑保存时在原有学生数据上修改，自定义字段等原样保留。
/// 姓名 / 学号 / 电话校验非法时显示红色提示，且保存按钮禁用（禁止保存）。
struct iOSStudentFormSheet: View {
    @ObservedObject var store: ProjectStore
    /// nil = 新增学生；非 nil = 编辑该学生
    var student: Student?

    @Environment(\.dismiss) private var dismiss

    // 表单状态
    @State private var name = ""
    @State private var studentNumber = ""
    @State private var isBoarding = false
    @State private var phone = ""
    @State private var boardingAddress = ""
    @State private var policeStation = ""
    @State private var guardians: [Guardian] = []
    /// 防止同一 sheet 重复弹出时多次加载初始值
    @State private var didLoadInitial = false

    private var isEditMode: Bool { student != nil }

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                guardianSection
            }
            .navigationTitle(isEditMode ? "编辑学生信息" : "添加学生")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditMode ? "保存" : "添加", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .onAppear(perform: loadInitialValues)
    }

    // MARK: 校验（非法时红色提示，且保存按钮禁用）

    /// 姓名：必填（对照 macOS StudentFormSheet.validationMessage）
    private var nameError: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请填写姓名" : nil
    }

    /// 学号：必填且不能与其他学生重复（FieldFormat.isValidStudentNumber + 存储层唯一性校验）
    private var studentNumberError: String? {
        let trimmed = studentNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FieldFormat.isValidStudentNumber(trimmed) else { return "请填写学号" }
        if store.isStudentNumberTaken(trimmed, excluding: student?.id) {
            return "学号「\(trimmed)」已被其他学生使用"
        }
        return nil
    }

    /// 电话：FieldFormat.isValidPhone（选填，填写后必须合法）
    private var phoneError: String? {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return FieldFormat.isValidPhone(trimmed)
            ? nil
            : "电话格式不正确：应为 7-15 位数字（可含 +86 或 - 分隔）"
    }

    private var canSave: Bool {
        nameError == nil && studentNumberError == nil && phoneError == nil
    }

    /// 字段下方的红色错误提示
    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }

    // MARK: 表单区块

    private var basicSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("姓名（必填）", text: $name)
                if let error = nameError { errorText(error) }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("学号（必填，不能与其他学生重复）", text: $studentNumber)
                if let error = studentNumberError { errorText(error) }
            }
            Toggle("是否住宿", isOn: $isBoarding)
            VStack(alignment: .leading, spacing: 4) {
                TextField("联系电话（选填）", text: $phone)
                    .keyboardType(.phonePad)
                if let error = phoneError { errorText(error) }
            }
            TextField("住宿地址（选填）", text: $boardingAddress)
            TextField("对应派出所（选填）", text: $policeStation)
        } header: {
            Text("基本信息")
        }
    }

    private var guardianSection: some View {
        Section {
            ForEach($guardians) { $guardian in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("姓名", text: $guardian.name)
                        TextField("关系（父/母/祖父…）", text: $guardian.relation)
                        TextField("电话", text: $guardian.phone)
                            .keyboardType(.phonePad)
                    }
                    Button(role: .destructive) {
                        removeGuardian(guardian.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除该监护人")
                }
            }
            Button {
                guardians.append(Guardian())
            } label: {
                Label("添加监护人", systemImage: "plus.circle")
            }
        } header: {
            Text("监护人")
        } footer: {
            Text("整组留空的监护人不会保存。")
        }
    }

    private func removeGuardian(_ id: UUID) {
        guardians.removeAll { $0.id == id }
    }

    // MARK: 逻辑

    /// 载入初始值（对照 macOS StudentFormSheet.loadInitialValues）
    private func loadInitialValues() {
        guard !didLoadInitial else { return }
        didLoadInitial = true
        guard let existing = student else {
            guardians = [Guardian()]   // 新增时先给一组空白监护人
            return
        }
        name = existing.name
        studentNumber = existing.studentNumber
        isBoarding = existing.isBoarding
        phone = existing.phone
        boardingAddress = existing.boardingAddress
        policeStation = existing.policeStation
        guardians = existing.guardians
    }

    /// 保存：新增走 store.addStudent，编辑走 store.updateStudent
    private func save() {
        guard canSave else { return }   // 保存按钮已禁用，此处兜底
        // 在原有学生上修改：自定义字段、记录、建档时间等本表单未覆盖的数据原样保留
        var target = student ?? Student()
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.studentNumber = studentNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        target.isBoarding = isBoarding
        target.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        target.boardingAddress = boardingAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        target.policeStation = policeStation.trimmingCharacters(in: .whitespacesAndNewlines)
        target.guardians = guardians.filter { !$0.isEmpty }

        if student != nil {
            store.updateStudent(target)
        } else {
            store.addStudent(target)
        }
        dismiss()
    }
}
