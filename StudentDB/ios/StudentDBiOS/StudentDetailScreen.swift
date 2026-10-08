import SwiftUI

// MARK: - 学生详情页（iOS）

/// 学生详情：基本信息 / 记录 两个页签。
/// 通过 studentID 实时从 appModel.store 解析学生，编辑保存后随数据自动刷新。
struct StudentDetailScreen: View {
    @EnvironmentObject private var appModel: AppModel
    let studentID: UUID

    var body: some View {
        if let store = appModel.store {
            StudentDetailContent(store: store, studentID: studentID)
        } else {
            iOSMessageView(title: "尚未打开项目",
                           message: "请先打开或新建一个学生信息项目。",
                           systemImage: "tray")
        }
    }
}

/// 详情内容：单独一层以便用 @ObservedObject 观察 ProjectStore.data 的变化
/// （AppModel.store 本身不变，数据变化发布在 ProjectStore 上）
private struct StudentDetailContent: View {
    @ObservedObject var store: ProjectStore
    let studentID: UUID

    private enum Tab: Hashable {
        case info
        case records
    }

    @State private var tab: Tab = .info
    @State private var showEdit = false

    /// 每次渲染都从 store 取最新数据（编辑保存后自动刷新）
    private var student: Student? {
        store.data.students.first { $0.id == studentID }
    }

    /// 记录页签数据：各数据表中通过「关联学生」字段关联到此学生的行，按表分组，组内按创建时间倒序
    private var recordGroups: [LinkedRecordGroup] {
        var groups: [LinkedRecordGroup] = []
        for table in store.data.tables {
            guard let linkField = table.linkField else { continue }
            var rows: [LinkedRecordRow] = []
            for row in table.rows {
                guard case .link(let ids)? = row.values[linkField.id.uuidString],
                      ids.contains(studentID) else { continue }
                rows.append(LinkedRecordRow(id: row.id,
                                            createdAt: row.createdAt,
                                            summary: rowSummary(row, table: table, excluding: linkField)))
            }
            guard !rows.isEmpty else { continue }
            groups.append(LinkedRecordGroup(id: table.id,
                                            tableName: table.name,
                                            rows: rows.sorted { $0.createdAt > $1.createdAt }))
        }
        return groups
    }

    private var totalRecordCount: Int {
        recordGroups.reduce(0) { $0 + $1.rows.count }
    }

    var body: some View {
        if let current = student {
            detailView(current)
                .navigationTitle(current.name.isEmpty ? "学生详情" : current.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showEdit = true
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .accessibilityLabel("编辑学生信息")
                    }
                }
                .sheet(isPresented: $showEdit) {
                    editSheet
                }
        } else {
            iOSMessageView(title: "学生不存在",
                           message: "该学生可能已被删除。",
                           systemImage: "person.slash")
                .navigationTitle("学生详情")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 页面骨架

    private func detailView(_ student: Student) -> some View {
        VStack(spacing: 0) {
            header(student)
            Picker("页签", selection: $tab) {
                Text("基本信息").tag(Tab.info)
                Text("记录（\(totalRecordCount)）").tag(Tab.records)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .info:
                infoList(student)
            case .records:
                recordsList
            }
        }
    }

    /// 头部：头像 + 姓名 + 学号 + 住宿徽章
    private func header(_ student: Student) -> some View {
        HStack(spacing: 14) {
            iOSAvatarView(name: student.name, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(student.name.isEmpty ? "（未命名）" : student.name)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text(student.studentNumber.isEmpty ? "未填学号" : "学号 \(student.studentNumber)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    iOSBoardingBadge(isBoarding: student.isBoarding)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 基本信息页签

    private func infoList(_ student: Student) -> some View {
        List {
            Section("基本信息") {
                // 内置字段全部展示；点击任意一行弹出编辑表单
                infoRow(label: "姓名", value: student.name)
                infoRow(label: "学号", value: student.studentNumber)
                Button {
                    showEdit = true
                } label: {
                    HStack {
                        Text("是否住宿")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        iOSBoardingBadge(isBoarding: student.isBoarding)
                    }
                }
                .buttonStyle(.plain)
                infoRow(label: "联系电话", value: student.phone)
                infoRow(label: "住宿地址", value: student.boardingAddress)
                infoRow(label: "对应派出所", value: student.policeStation)
            }
            if !store.data.orderedFields.isEmpty {
                Section("自定义字段") {
                    ForEach(store.data.orderedFields) { field in
                        infoRow(label: field.name,
                                value: student.customValues[field.id.uuidString]?.displayText ?? "")
                    }
                }
            }
            Section("监护人") {
                let active = student.guardians.filter { !$0.isEmpty }
                if active.isEmpty {
                    Text("未填写监护人信息")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(active) { guardian in
                        guardianRow(guardian)
                    }
                }
            }
            Section {
                Text("建档于 \(Fmt.dateTime.string(from: student.createdAt))，最近更新 \(Fmt.dateTime.string(from: student.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 「标签 + 值」信息行，点击弹出编辑表单
    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { showEdit = true }
    }

    /// 监护人行：姓名 + 关系胶囊 + 电话
    private func guardianRow(_ guardian: Guardian) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(guardian.name.isEmpty ? "（未填姓名）" : guardian.name)
                    .font(.body.weight(.medium))
                if !guardian.relation.isEmpty {
                    Text(guardian.relation)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            if !guardian.phone.isEmpty {
                Text(guardian.phone)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: 记录页签

    private var recordsList: some View {
        List {
            if recordGroups.isEmpty {
                Text("暂无关联记录（在各记录表或数据表中添加并关联该学生后，会显示在这里）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recordGroups) { group in
                    Section(group.tableName) {
                        ForEach(group.rows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.summary.isEmpty ? "（无内容）" : row.summary)
                                    .font(.callout)
                                Text("创建于 \(Fmt.dateTime.string(from: row.createdAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 行的关键字段文本：除「关联学生」外，取前 3 个非空字段的显示文本
    private func rowSummary(_ row: DBRow, table: DBTable, excluding linkField: CustomField) -> String {
        var parts: [String] = []
        for field in table.orderedFields where field.id != linkField.id {
            let text = TableQuery.displayText(of: row, field: field) { id in
                store.data.students.first { $0.id == id }?.name ?? "未知学生"
            }
            if !text.isEmpty { parts.append(text) }
            if parts.count >= 3 { break }
        }
        return parts.joined(separator: " · ")
    }

    /// 编辑表单：保存走 store.updateStudent，详情随数据自动刷新
    private var editSheet: some View {
        Group {
            if let current = store.data.students.first(where: { $0.id == studentID }) {
                iOSStudentFormSheet(store: store, student: current)
            }
        }
    }
}

// MARK: 记录分组数据（文件内私有）

private struct LinkedRecordGroup: Identifiable {
    let id: UUID          // 数据表 id
    let tableName: String
    let rows: [LinkedRecordRow]
}

private struct LinkedRecordRow: Identifiable {
    let id: UUID          // 行 id
    let createdAt: Date
    let summary: String
}
