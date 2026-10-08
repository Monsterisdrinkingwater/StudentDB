import SwiftUI

/// 学生详情：基本信息（可拖拽排列）/ 记录 / 附件 三个标签页
struct StudentDetailView: View {
    @ObservedObject var store: ProjectStore
    let student: Student

    enum Tab: String, CaseIterable, Identifiable {
        case info, records, files
        var id: String { rawValue }
    }

    @State private var tab: Tab = .info
    @State private var showEdit = false
    @State private var showAddRecord = false
    @State private var addRecordTableID: UUID?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            picker
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showEdit = true
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .help("编辑学生信息")

                Menu {
                    ForEach(store.data.tables.filter { $0.kind == .record }) { table in
                        Button("添加\(table.name)") { addRecordTableID = table.id }
                    }
                    if store.data.tables.first(where: { $0.kind == .record }) == nil {
                        Button("（还没有记录表）") {}
                            .disabled(true)
                    }
                    Divider()
                    Button("在访达中显示附件文件夹") {
                        if let dir = store.studentFilesDirectory(student.id) {
                            store.revealInFinder(dir)
                        }
                    }
                    Divider()
                    Button("删除学生…", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("更多操作")
            }
        }
        .sheet(isPresented: $showEdit) {
            StudentFormSheet(store: store, mode: .edit(student))
                .frame(width: 560)
        }
        .sheet(item: Binding(
            get: { addRecordTableID.flatMap { store.data.table(id: $0) }.map { SimpleTableItem(id: $0.id, name: $0.name) } },
            set: { addRecordTableID = $0?.id }
        )) { item in
            if let table = store.data.table(id: item.id) {
                RowEditorSheet(store: store, table: table, editingRowID: nil,
                               initialStudentIDs: [student.id]) { _ in }
                    .resizableSheet(minWidth: 460, minHeight: 380, idealWidth: 560, idealHeight: 460)
            }
        }
        .confirmationDialog(
            "确定删除「\(student.name)」吗？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除学生", role: .destructive) {
                store.deleteStudent(id: student.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该学生的全部信息、记录和附件将被删除（附件移入废纸篓）。此操作不可撤销。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 14) {
            AvatarView(name: student.name, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(student.name.isEmpty ? "（未命名）" : student.name)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text(student.studentNumber.isEmpty ? "未填学号" : "学号 \(student.studentNumber)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    BoardingBadge(isBoarding: student.isBoarding)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var picker: some View {
        Picker("视图", selection: $tab) {
            Text("基本信息").tag(Tab.info)
            Text("记录（\(student.records.count)）").tag(Tab.records)
            Text("附件").tag(Tab.files)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 420)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .info:
            InfoTabView(store: store, student: student, onEdit: { showEdit = true })
        case .records:
            RecordsTabView(store: store, student: student)
        case .files:
            StudentFilesTabView(store: store, student: student)
        }
    }
}

// MARK: - 基本信息标签页（布局驱动 + 拖拽排列）

struct InfoTabView: View {
    @ObservedObject var store: ProjectStore
    let student: Student
    var onEdit: () -> Void

    @State private var draggingID: String?

    private var activeGuardians: [Guardian] {
        student.guardians.filter { !$0.isEmpty }
    }

    /// 内置字段是否可见（未被软删除）
    private func builtinVisible(_ key: String) -> Bool {
        !store.data.deletedBuiltinFields.contains(key)
    }

    /// 详情页展示的项（锚点）顺序：内置信息列 + 监护人卡片（guardian1）+ 自定义列。
    /// 顺序来自统一布局 columnLayout（与表格列拖拽、字段管理页共享）。
    private var anchorIDs: [String] {
        let full = store.data.columnLayout.isEmpty ? store.currentColumnLayout() : store.data.columnLayout
        var anchors: [String] = []
        for id in full {
            let anchor: String?
            if let field = StudentTableField(rawValue: id) {
                anchor = (field == .recordCount || !builtinVisible(field.rawValue)) ? nil : id
            } else if id.hasPrefix("guardian1-") {
                anchor = "guardian1-name" // 监护人卡片锚点
            } else if id.hasPrefix("guardian") {
                anchor = nil // 监护人2+组不在详情页展示
            } else {
                anchor = store.data.orderedFields.contains { $0.id.uuidString == id } ? id : nil
            }
            if let anchor, !anchors.contains(anchor) {
                anchors.append(anchor)
            }
        }
        return anchors
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("按住每行左侧手柄拖动可自由排列字段")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(anchorIDs.enumerated()), id: \.element) { index, id in
                    detailItem(for: id, isLast: index == anchorIDs.count - 1)
                        .opacity(draggingID == id ? 0.35 : 1)
                        .onDrag {
                            draggingID = id
                            return NSItemProvider(object: id as NSString)
                        }
                        .onDrop(of: [.text], delegate: DetailRowDropDelegate(
                            targetID: id,
                            draggingID: $draggingID,
                            onMove: { from, to in
                                moveAnchor(from, to)
                            }
                        ))
                }

                FormCard(title: "备注", systemImage: "info.circle") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("建档于 \(Fmt.dateTime.string(from: student.createdAt))，最近更新 \(Fmt.dateTime.string(from: student.updatedAt))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
            .padding(20)
        }
    }

    // MARK: 详情项视图

    @ViewBuilder
    private func detailItem(for id: String, isLast: Bool) -> some View {
        if let field = StudentTableField(rawValue: id) {
            draggableRow(label: field.title) {
                switch field {
                case .name:
                    InfoRow(label: "姓名", value: student.name)
                case .studentNumber:
                    InfoRow(label: "学号", value: student.studentNumber)
                case .boarding:
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("是否住宿")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .trailing)
                        BoardingBadge(isBoarding: student.isBoarding)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                case .phone:
                    InfoRow(label: "联系电话", value: student.phone, systemImage: "phone")
                case .boardingAddress:
                    InfoRow(label: "住宿地址", value: student.boardingAddress, systemImage: "mappin.and.ellipse")
                case .policeStation:
                    InfoRow(label: "对应派出所", value: student.policeStation, systemImage: "shield.lefthalf.filled")
                case .recordCount:
                    EmptyView()
                }
            }
            if !isLast { Divider() }
        } else if id == "guardian1-name" {
            draggableRow(label: "监护人") {
                FormCard(title: "监护人", systemImage: "person.2") {
                    if activeGuardians.isEmpty {
                        Text("未填写监护人信息")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(activeGuardians) { guardian in
                            GuardianInfoRow(guardian: guardian, isLast: guardian.id == activeGuardians.last?.id)
                        }
                    }
                }
            }
        } else if let fieldDef = store.data.orderedFields.first(where: { $0.id.uuidString == id }) {
            draggableRow(label: fieldDef.name) {
                InfoRow(label: fieldDef.name,
                        value: student.customValues[id]?.displayText ?? "")
            }
            if !isLast { Divider() }
        }
    }

    /// 带拖拽手柄的行
    private func draggableRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .help("拖动排列「\(label)」")
            content()
        }
    }

    // MARK: 拖拽移动（写回统一布局）

    /// 把 from 锚点移动到 to 锚点位置：锚点序展开为完整列布局后保存
    private func moveAnchor(_ from: String, _ to: String) {
        var anchors = anchorIDs
        guard let fromIdx = anchors.firstIndex(of: from),
              let toIdx = anchors.firstIndex(of: to), fromIdx != toIdx else { return }
        anchors.remove(at: fromIdx)
        anchors.insert(from, at: toIdx)

        var newLayout: [String] = []
        for anchor in anchors {
            if anchor == "guardian1-name" {
                newLayout += ["guardian1-name", "guardian1-relation", "guardian1-phone"]
            } else {
                newLayout.append(anchor)
            }
        }
        // 详情页不展示的列（监护人2+组、记录数）按原顺序补回尾部
        let full = store.data.columnLayout.isEmpty ? store.currentColumnLayout() : store.data.columnLayout
        let newSet = Set(newLayout)
        for id in full where !newSet.contains(id) {
            newLayout.append(id)
        }
        store.setColumnLayout(newLayout)
    }
}

// MARK: - 详情页行拖拽代理

/// 拖到目标行上时把拖动项移动到该位置
private struct DetailRowDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingID: String?
    var onMove: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != targetID else { return }
        onMove(dragging, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

// MARK: - 监护人信息行

private struct GuardianInfoRow: View {
    let guardian: Guardian
    let isLast: Bool

    var body: some View {
        HStack(spacing: 8) {
            if !guardian.relation.isEmpty {
                Text(guardian.relation)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Text(guardian.name)
                .font(.callout.weight(.medium))
            Text(guardian.phone)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 6)
        if !isLast {
            Divider()
        }
    }
}

private struct SimpleTableItem: Identifiable {
    let id: UUID
    let name: String
}
