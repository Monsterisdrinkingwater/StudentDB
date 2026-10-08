import SwiftUI
import AppKit

/// 表格视图：像 Excel 一样查看并直接编辑当前视图里全部学生的数据。
/// 采用 view-based NSTableView + 类型化单元格（参考 Notion 的做法）：
/// 文本列双击就地编辑；“住宿/是否”列单击勾选框直接切换；日期列内嵌日期选择器。
struct StudentTableView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var store: ProjectStore
    /// 已按视图筛选+排序的学生
    let students: [Student]
    /// 按视图列配置得到的列
    let columns: [StudentColumnSpec]
    /// 监护人扁平列组数（用于字段显隐菜单）
    let guardianSlots: Int
    @Binding var selection: Set<UUID>

    @State private var editingStudent: Student?
    @State private var showDeleteConfirm = false
    @State private var showAddStudent = false
    /// 列操作：待删除 / 待重命名的字段
    @State private var pendingDeleteColumn: StudentColumnSpec?
    @State private var pendingRenameColumn: StudentColumnSpec?
    @State private var renameText = ""
    @State private var showAddFieldPopover = false
    @State private var showBatchEdit = false
    @State private var showBatchDeleteConfirm = false
    @State private var autoFitToken = 0

    private func editDisplayText(_ edit: CellEdit) -> String {
        if case .text(let t) = edit { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }

    private var selectedStudent: Student? {
        selection.count == 1 ? students.first { $0.id == selection.first! } : nil
    }

    /// 选中学生集合（批量操作用）
    private var selectedStudents: [Student] {
        students.filter { selection.contains($0.id) }
    }

    var body: some View {
        ZStack {
            if students.isEmpty || columns.isEmpty {
                ContentUnavailableView(
                    students.isEmpty ? "没有匹配的学生" : "所有字段都已隐藏",
                    systemImage: students.isEmpty ? "rectangle.stack" : "eye.slash",
                    description: Text(students.isEmpty
                                      ? "清除或调整筛选条件，或点击 + 添加学生。"
                                      : "点击右上角「字段」菜单恢复要显示的列。")
                )
            } else {
                EditableStudentTable(
                    students: students,
                    columns: columns,
                    sortKey: store.currentView.sortKey,
                    sortAscending: store.currentView.sortAscending,
                    columnFilters: store.currentView.columnFilters,
                    store: store,
                    selection: $selection,
                    onSortChange: { key, ascending in
                        var v = store.currentView
                        v.sortKey = key
                        v.sortAscending = ascending
                        store.updateView(v)
                    },
                    onCommit: { studentID, spec, edit in
                        guard let student = store.student(id: studentID) else { return }
                        let updated = spec.applying(edit, to: student)
                        if updated != student {
                            store.updateStudent(updated)
                            // 表格编辑立即同步落盘，不等待防抖，杜绝修改丢失
                            try? store.saveNow()
                        } else if !spec.displayText(of: student).contains(editDisplayText(edit)) {
                            // 输入不符合字段格式标准被拒绝时提示
                            NSSound.beep()
                        }
                    },
                    onHideColumn: { spec in
                        hideColumn(spec)
                    },
                    onMoveColumn: { spec, offset in
                        moveColumn(spec, offset: offset)
                    },
                    onRenameColumn: { spec in
                        pendingRenameColumn = spec
                        renameText = spec.title
                    },
                    onDeleteColumn: { spec in
                        pendingDeleteColumn = spec
                    },
                    onLayoutChange: { ids in
                        store.setColumnLayout(ids)
                    },
                    onDeleteSelection: {
                        showBatchDeleteConfirm = true
                    },
                    storedLayout: store.data.columnLayout.isEmpty
                        ? StudentColumnSpec.allColumns(
                            fields: store.data.orderedFields,
                            guardianSlots: store.currentView.guardianColumnCount,
                            builtinOrder: store.data.builtinOrder,
                            deletedBuiltin: store.data.deletedBuiltinFields).map { $0.id }
                        : store.data.columnLayout,
                    storedWidths: store.data.columnWidths,
                    onColumnWidthChange: { columnID, width in
                        store.setStudentColumnWidth(columnID: columnID, width: width)
                    },
                    autoFitToken: autoFitToken
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                // 添加一列：新建字段，新列立即追加在表格尾部。
                // popover 锚定在本按钮上，气泡出现在触发位置旁
                Button {
                    showAddFieldPopover = true
                } label: {
                    Label("添加列", systemImage: "plus")
                }
                .help("添加一列（新建字段）")

                Button {
                    autoFitToken += 1
                } label: {
                    Text("适应内容")
                }
                .help("自动调整所有列宽，保证内容完整显示")
                .sheet(isPresented: $showBatchEdit) {
            BatchEditSheet(store: store, studentIDs: selection)
                .frame(width: 440)
        }
        .confirmationDialog(
            "批量删除 \(selectedStudents.count) 名学生？",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedStudents.count) 人", role: .destructive) {
                store.deleteStudents(ids: selection)
                selection.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            let names = selectedStudents.prefix(5).map { $0.name }.joined(separator: "、")
            let extra = selectedStudents.count > 5 ? " 等 \(selectedStudents.count) 人" : ""
            Text("将删除「\(names)」\(extra)的全部信息、记录和附件。此操作不可撤销（可从项目备份恢复）。")
        }
        .popover(isPresented: $showAddFieldPopover, arrowEdge: .bottom) {
                    AddFieldPopover(store: store)
                        .frame(width: 280)
                }

                // 字段显隐 / 新建（图标无法自解释，用文字按钮）
                fieldsMenu

                // 批量修改：多选后统一赋值一个字段（文字按钮，避免看不懂的图标）
                Button {
                    showBatchEdit = true
                } label: {
                    Text("批量修改")
                }
                .disabled(selectedStudents.count < 2)
                .help(selectedStudents.count < 2 ? "选中 2 名以上学生（⌘/⇧ 多选）后可批量修改" : "批量修改选中的 \(selectedStudents.count) 人")

                // 删除选中（含多选）
                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Text("删除")
                }
                .disabled(selectedStudents.isEmpty)
                .help("删除选中的 \(selectedStudents.count) 名学生")

                Button {
                    if let s = selectedStudent { editingStudent = s }
                } label: {
                    Text("编辑")
                }
                .disabled(selectedStudent == nil)
                .help("在表单中编辑选中的学生")

                Menu {
                    Button("添加学生…") {
                        showAddStudent = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("更多操作")
            }
        }
        .sheet(item: $editingStudent) { student in
            StudentFormSheet(store: store, mode: .edit(student))
                .frame(width: 560)
        }
        .sheet(isPresented: $showAddStudent) {
            StudentFormSheet(store: store, mode: .add)
                .frame(width: 560)
        }
        .confirmationDialog(
            "确定删除「\(selectedStudent?.name ?? "")」吗？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除学生", role: .destructive) {
                if let id = selectedStudent?.id {
                    store.deleteStudent(id: id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该学生的全部信息、记录和附件将被删除（附件移入废纸篓）。此操作不可撤销。")
        }
        .confirmationDialog(
            "删除字段「\(pendingDeleteColumn?.title ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteColumn != nil },
                set: { if !$0 { pendingDeleteColumn = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除字段", role: .destructive) {
                if let spec = pendingDeleteColumn {
                    if let field = spec.customField {
                        store.deleteField(id: field.id) // 自定义字段：真删除
                    } else if let field = spec.field, spec.guardianSlot == nil {
                        store.hardDeleteBuiltinField(key: field.rawValue) // 内置字段：真删除（姓名/学号不可删）
                    }
                }
                pendingDeleteColumn = nil
            }
            Button("取消", role: .cancel) { pendingDeleteColumn = nil }
        } message: {
            if pendingDeleteColumn?.customField != nil {
                Text("所有学生填写的该字段内容将被永久删除（恢复可用项目备份）。引用它的快捷筛选标签也会一并移除。")
            } else {
                Text("该字段及其全部数据将从项目中永久删除（姓名和学号不可删除）。恢复字段后数据为空，可从项目备份找回。")
            }
        }
        .alert("重命名字段", isPresented: Binding(
            get: { pendingRenameColumn != nil },
            set: { if !$0 { pendingRenameColumn = nil } }
        )) {
            TextField("字段名称", text: $renameText)
            Button("重命名") {
                if let spec = pendingRenameColumn, var field = spec.customField {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        field.name = trimmed
                        store.updateField(field)
                    }
                }
                pendingRenameColumn = nil
            }
            Button("取消", role: .cancel) { pendingRenameColumn = nil }
        } message: {
            Text("仅修改字段名称，已填写的内容保持不变。")
        }
    }

    /// 移动列（统一布局：内置/监护人/自定义一视同仁）
    private func moveColumn(_ spec: StudentColumnSpec, offset: Int) {
        store.moveColumn(id: spec.id, offset: offset)
    }

    private func hideColumn(_ spec: StudentColumnSpec) {
        var v = store.currentView
        let visibleCount = StudentColumnSpec.columns(
            fields: store.data.orderedFields, hidden: v.hiddenColumnIDs,
            guardianSlots: v.guardianColumnCount,
            builtinOrder: store.data.builtinOrder,
            deletedBuiltin: store.data.deletedBuiltinFields
        ).count
        guard visibleCount > 1 else {
            NSSound.beep()
            return
        }
        v.hiddenColumnIDs.insert(spec.id)
        store.updateView(v)
    }

    // MARK: 字段显示 / 隐藏菜单

    private var allColumns: [StudentColumnSpec] {
        StudentColumnSpec.allColumns(fields: store.data.orderedFields,
                                     guardianSlots: store.currentView.guardianColumnCount,
                                     builtinOrder: store.data.builtinOrder,
                                     deletedBuiltin: store.data.deletedBuiltinFields)
    }

    /// 字段菜单：新建 / 显示隐藏列（列的删除在列头右键菜单里）
    private var fieldsMenu: some View {
        Menu {
            Button {
                showAddFieldPopover = true
            } label: {
                Label("新建字段…", systemImage: "plus.square.on.square")
            }
            Divider()
            ForEach(allColumns) { spec in
                Button {
                    toggleColumn(spec)
                } label: {
                    if store.currentView.hiddenColumnIDs.contains(spec.id) {
                        Text("\(spec.title)（已隐藏）")
                    } else {
                        Label(spec.title, systemImage: "checkmark")
                    }
                }
            }
        } label: {
            Text("字段")
        }
        .help("显示或隐藏表格字段")
    }

    private func toggleColumn(_ spec: StudentColumnSpec) {
        var v = store.currentView
        if v.hiddenColumnIDs.contains(spec.id) {
            v.hiddenColumnIDs.remove(spec.id)
        } else {
            // 至少保留一列可见
            let visibleCount = StudentColumnSpec.columns(
                fields: store.data.fieldDefinitions, hidden: v.hiddenColumnIDs
            ).count
            guard visibleCount > 1 else {
                NSSound.beep()
                return
            }
            v.hiddenColumnIDs.insert(spec.id)
        }
        store.updateView(v)
    }
}

// MARK: - 类型化单元格视图

/// 文本单元格（双击进入编辑）
final class StudentTextCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 必须用 NSTextField(string:)（字段型，可编辑）；labelWithString: 是 Label 型，永远无法编辑
        let tf = NSTextField(string: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.lineBreakMode = .byTruncatingTail
        // 不可选择：单击始终落在表格上（行选择/⌘/⇧ 多选更可靠）
        tf.isSelectable = false
        tf.isEditable = false
        textField = tf
        addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 勾选框单元格（单击直接切换）
final class StudentCheckboxCellView: NSView {
    let button: NSButton

    override init(frame frameRect: NSRect) {
        button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frameRect)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 日期单元格：按钮＋弹出式日历（内嵌 NSDatePicker 在表格里交互不可靠）
final class StudentDateCellView: NSView {
    let button: StudentDateButton

    override init(frame frameRect: NSRect) {
        button = StudentDateButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frameRect)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 学生表日期格按钮（携带学生/列上下文）
final class StudentDateButton: NSButton {
    var studentID: UUID?
    var columnID: String = ""
}

/// 学生表弹出日历（携带学生/列上下文）
final class StudentGraphicalDatePicker: NSDatePicker {
    var studentID: UUID?
    var columnID: String = ""
}

/// 下拉选择单元格（单击选值，限定选项）
final class StudentChoiceCellView: NSView {
    let popup: NSPopUpButton

    override init(frame frameRect: NSRect) {
        popup = NSPopUpButton()
        popup.isBordered = false
        popup.preferredEdge = .minY
        popup.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frameRect)
        addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 多选单元格（点击弹出勾选菜单，值以顿号拼接）
final class StudentMultiChoiceCellView: NSView {
    let button: NSButton
    var options: [String] = []

    override init(frame frameRect: NSRect) {
        button = NSButton()
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frameRect)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Excel 式可筛选表头

/// 每列右端带筛选漏斗按钮的表头；点击漏斗弹出筛选面板，其余区域保持原生行为（点击排序 / 拖动换列）
final class FilterableTableHeaderView: NSTableHeaderView {
    var onFilterTapped: (NSUserInterfaceItemIdentifier, NSRect) -> Void = { _, _ in }
    /// 当前设置了筛选的列（漏斗高亮显示）
    var activeFilterIDs: Set<String> = [] {
        didSet {
            if oldValue != activeFilterIDs {
                syncFilterButtons()
            }
        }
    }

    var buttons: [String: NSButton] = [:]

    override func layout() {
        super.layout()
        syncFilterButtons()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 横向滚动时 layout 不一定触发，绘制时兜底对齐按钮
        syncFilterButtons()
    }

    /// 漏斗按钮只作显示：命中在 mouseDown 里按「列右端漏斗区」实时判定，
    /// 不依赖 buttons 字典的 frame 副本（reload/高亮切换后副本可能过期，点击落空还会
    /// 掉进原生表头的事件跟踪循环，表现为“再点没反应/卡住”）。
    private func funnelTarget(at point: NSPoint) -> (id: String, rect: NSRect)? {
        guard let table = tableView else { return nil }
        for index in 0..<table.numberOfColumns {
            let rect = headerRect(ofColumn: index)
            let funnelRect = NSRect(x: rect.maxX - 25, y: 0, width: 25, height: bounds.height)
            guard funnelRect.contains(point), rect.width > 64 else { continue }
            let id = table.tableColumns[index].identifier.rawValue
            return (id, funnelRect)
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if funnelTarget(at: point) != nil {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let target = funnelTarget(at: point) {
            // 锚定矩形用漏斗中心的小矩形（与旧版按钮几何一致）：
            // 传整个漏斗区（y=0 起）会让 .minY 边缘落在表头顶端，弹层定位到标题栏方向而不可见
            let anchor = NSRect(x: target.rect.midX - 8,
                                y: (bounds.height - 16) / 2,
                                width: 16, height: 16)
            onFilterTapped(NSUserInterfaceItemIdentifier(target.id), anchor)
            return
        }
        super.mouseDown(with: event)
    }

    private func syncFilterButtons() {
        guard let table = tableView else { return }
        var seen = Set<String>()
        for column in table.tableColumns {
            let id = column.identifier.rawValue
            seen.insert(id)
            let index = table.column(withIdentifier: column.identifier)
            guard index >= 0, headerRect(ofColumn: index).width > 64 else {
                buttons[id]?.isHidden = true
                continue
            }
            let colRect = headerRect(ofColumn: index)
            let button: NSButton
            if let existing = buttons[id] {
                button = existing
            } else {
                button = NSButton(title: "", target: nil, action: nil)
                button.isBordered = false
                button.identifier = column.identifier
                // 底色遮罩：防止过长的列标题文字穿透到漏斗下面造成重叠
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                addSubview(button)
                buttons[id] = button
            }
            button.isHidden = false
            button.frame = NSRect(x: colRect.maxX - 21, y: (bounds.height - 16) / 2, width: 16, height: 16)
            let active = activeFilterIDs.contains(id)
            let symbolName = active ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "筛选此列")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            button.contentTintColor = active ? .controlAccentColor : .tertiaryLabelColor
        }
        for (id, button) in buttons where !seen.contains(id) {
            button.removeFromSuperview()
            buttons.removeValue(forKey: id)
        }
    }
}

// MARK: - 可编辑 NSTableView 封装

struct EditableStudentTable: NSViewRepresentable {
    let students: [Student]
    let columns: [StudentColumnSpec]
    let sortKey: ListSortKey
    let sortAscending: Bool
    /// 当前设置了筛选的列（表头漏斗高亮）
    var columnFilters: [String: ColumnFilter] = [:]
    /// 宿主 store（表头筛选弹窗需要；测试场景可空）
    var store: ProjectStore? = nil
    @Binding var selection: Set<UUID>
    var onSortChange: (ListSortKey, Bool) -> Void
    var onCommit: (UUID, StudentColumnSpec, CellEdit) -> Void
    /// 隐藏列（视图级）
    var onHideColumn: (StudentColumnSpec) -> Void = { _ in }
    /// 移动列位置（-1 左移 / +1 右移）
    var onMoveColumn: (StudentColumnSpec, Int) -> Void = { _, _ in }
    /// 重命名自定义字段
    var onRenameColumn: (StudentColumnSpec) -> Void = { _ in }
    /// 删除字段（自定义字段真删；内置字段软删除可恢复）
    var onDeleteColumn: (StudentColumnSpec) -> Void = { _ in }
    /// 列拖拽重排后回传新的可见列顺序（含隐藏列时由上层兜底）
    var onLayoutChange: ([String]) -> Void = { _ in }
    /// 行右键菜单“删除选中”触发（确认框在上层）
    var onDeleteSelection: () -> Void = { }
    /// 上层保存的完整布局（含隐藏列），拖拽写回时合并隐藏项
    var storedLayout: [String] = []
    /// 上层保存的列宽记忆
    var storedWidths: [String: CGFloat] = [:]
    /// 列宽变化回写（拖拽/自适应结束后调用）
    var onColumnWidthChange: (String, CGFloat) -> Void = { _, _ in }
    /// 自适应列宽令牌（递增触发一次 autofit）
    var autoFitToken: Int = 0

    static let textCellID = NSUserInterfaceItemIdentifier("studentTextCell")
    static let checkboxCellID = NSUserInterfaceItemIdentifier("studentCheckboxCell")
    static let dateCellID = NSUserInterfaceItemIdentifier("studentDateCell")
    static let choiceCellID = NSUserInterfaceItemIdentifier("studentChoiceCell")
    static let multiChoiceCellID = NSUserInterfaceItemIdentifier("studentMultiChoiceCell")
    static let dateTimeCellID = NSUserInterfaceItemIdentifier("studentDateTimeCell")

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = FilterableTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true // 拖拽列标题自由排列
        table.allowsMultipleSelection = true // ⌘/⇧ 多选，支持批量操作
        table.rowHeight = 26
        // 列间距为 0：视觉边框与列边界重合，拖动边框只影响该列及后续列，
        // 不会因间隙错位而误触列头拖拽（导致前面的列被移动）
        table.intercellSpacing = NSSize(width: 0, height: 2)
        // 列宽固定为理想宽度，超出窗口宽度时横向滚动（而不是挤压列）
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClickedRow)
        context.coordinator.tableView = table

        // 列标题右键菜单（Notion 式：排序 / 隐藏 / 删除）
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        // Excel 式表头筛选：每列右端漏斗按钮，点击弹出筛选面板
        if let header = table.headerView as? FilterableTableHeaderView {
            header.onFilterTapped = { columnID, rect in
                context.coordinator.openFilterPopover(columnID: columnID.rawValue, headerRect: rect)
            }
        }
        table.headerView?.menu = headerMenu

        // 表格行右键菜单（多选后直接删除选中）
        let rowMenu = NSMenu()
        rowMenu.delegate = context.coordinator
        table.menu = rowMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false // 滚动条常显
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // 列：与目标规格对齐（增量，避免抖动）
        let specIDs = columns.map { $0.id }
        if specIDs != coordinator.columnIDs {
            coordinator.alignColumns(table, to: columns)
            coordinator.columnIDs = specIDs
        }

        // 自适应列宽（工具栏「适应内容」按钮触发）
        if autoFitToken != coordinator.lastAutoFitToken {
            coordinator.lastAutoFitToken = autoFitToken
            coordinator.performAutoFit()
        }

        // 数据：签名变化才刷新；控件自身的提交跳过整表重载（单元格已显示新值）
        let signature = students.map { "\($0.id.uuidString)#\($0.updatedAt.timeIntervalSince1970)" }
        if signature != coordinator.rowSignatures {
            let canSuppress = coordinator.suppressReloadOnce && students.count == coordinator.lastRowCount
            coordinator.suppressReloadOnce = false
            coordinator.rowSignatures = signature
            if !canSuppress {
                table.reloadData()
                coordinator.pendingSelectionSync = true
            }
        }
        coordinator.lastRowCount = students.count

        // 选中行同步（仅在刷新数据或外部清空时执行，避免与用户 ⌘/⇧ 多选竞争）
        let desiredIndexes = IndexSet(students.enumerated().compactMap { selection.contains($0.element.id) ? $0.offset : nil })
        let currentIndexes = IndexSet(table.selectedRowIndexes)
        if coordinator.pendingSelectionSync || (selection.isEmpty && !currentIndexes.isEmpty) {
            if desiredIndexes != currentIndexes {
                table.deselectAll(coordinator)
                for index in desiredIndexes.sorted() {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true)
                }
            }
            coordinator.pendingSelectionSync = false
        }

        // 排序描述符同步（表头箭头指示）
        var needsSortUpdate = table.sortDescriptors.isEmpty
        if let current = table.sortDescriptors.first {
            let currentKey = columns.first(where: { $0.sortKey?.rawValue == current.key })?.sortKey
            if currentKey != sortKey || current.ascending != sortAscending {
                needsSortUpdate = true
            }
        }
        if needsSortUpdate {
            if let spec = columns.first(where: { $0.sortKey == sortKey }) {
                table.sortDescriptors = [Self.descriptor(for: spec, ascending: sortAscending)]
            } else {
                table.sortDescriptors = []
            }
        }

        // 表头筛选漏斗状态同步（有筛选的列高亮）
        if let header = table.headerView as? FilterableTableHeaderView {
            let activeIDs = Set(columns.filter { columnFilters[$0.id]?.isActive == true }.map { $0.id })
            header.activeFilterIDs = activeIDs
        }
    }

    private func rebuildColumns(_ table: NSTableView) {
        // 兼容保留：全量重建（极少走到）
        Self.alignColumnsStatic(table, columns: columns, storedWidths: [:])
    }

    /// 增量对齐列：同集合仅重排（保宽度不闪烁）；集合变化则重建并恢复宽度与滚动位置
    private static func alignColumnsStatic(_ table: NSTableView, columns: [StudentColumnSpec],
                                           storedWidths: [String: CGFloat] = [:]) {
        let oldIDs = table.tableColumns.map { $0.identifier.rawValue }
        let newIDs = columns.map { $0.id }
        let scroll = table.enclosingScrollView
        let savedOriginX = scroll?.contentView.bounds.origin.x ?? 0

        if Set(oldIDs) == Set(newIDs), oldIDs.count == newIDs.count {
            // 仅顺序不同：用 moveColumn 原地重排，不销毁列
            for (targetIndex, id) in newIDs.enumerated() {
                if let currentIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
                   currentIndex != targetIndex {
                    table.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
            return
        }

        // 集合变化：记录宽度后重建
        var widths: [String: CGFloat] = [:]
        for column in table.tableColumns {
            widths[column.identifier.rawValue] = column.width
        }
        for column in table.tableColumns {
            table.removeTableColumn(column)
        }
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.minWidth = 50
            column.maxWidth = 420
            column.width = widths[spec.id] ?? storedWidths[spec.id] ?? EditableStudentTable.idealWidth(for: spec)
            if let sortKey = spec.sortKey {
                column.sortDescriptorPrototype = NSSortDescriptor(
                    key: sortKey.rawValue, ascending: true,
                    selector: #selector(NSString.localizedStandardCompare(_:))
                )
            }
            table.addTableColumn(column)
        }
        // 恢复横向滚动位置
        if let scroll, savedOriginX > 0 {
            let maxX = max(0, scroll.contentView.bounds.width - scroll.contentView.frame.width)
            scroll.contentView.setBoundsOrigin(NSPoint(x: min(savedOriginX, maxX + 200), y: 0))
        }
    }

    static func idealWidth(for spec: StudentColumnSpec) -> CGFloat {
        switch spec.cellKind {
        case .checkbox: return 56
        case .datePicker: return 120
        case .dateTimePicker: return 150
        case .choice: return 100
        case .multiChoice: return 130
        default:
            if spec.guardianPart == .relation { return 80 }
            if spec.guardianPart == .name { return 90 }
            if spec.guardianPart == .phone { return 110 }
            switch spec.field {
            case .name, .studentNumber: return 90
            case .phone: return 110
            case .boardingAddress: return 150
            case .policeStation: return 110
            case .recordCount: return 48
            default: return 110
            }
        }
    }

    static func descriptor(for spec: StudentColumnSpec, ascending: Bool) -> NSSortDescriptor {
        switch spec.sortKey {
        case .name, .studentNumber, .policeStation:
            return NSSortDescriptor(
                key: spec.sortKey!.rawValue, ascending: ascending,
                selector: #selector(NSString.localizedStandardCompare(_:))
            )
        default:
            return NSSortDescriptor(key: spec.sortKey!.rawValue, ascending: ascending)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSControlTextEditingDelegate, NSMenuDelegate, NSTextFieldDelegate, NSPopoverDelegate {
        var parent: EditableStudentTable
        weak var tableView: NSTableView?
        var columnIDs: [String] = []
        var rowSignatures: [String] = []
        var lastAutoFitToken = 0
        private var widthSaveWork: DispatchWorkItem?
        var pendingSelectionSync = false
        /// 正在编辑的文本单元格（双击时记录）
        var editingContext: (studentID: UUID, spec: StudentColumnSpec)?
        /// 打开中的列筛选弹窗
        var filterPopover: NSPopover?
        /// 控件交互产生的提交：下一次数据变化只更新签名、不整表重载（避免夺走正在编辑的字段编辑器）
        var suppressReloadOnce = false
        var lastRowCount = 0

        init(_ parent: EditableStudentTable) {
            self.parent = parent
        }

        /// 控件直接交互的提交路径（排序关键字段以外的列；排序变化需要整表重载调整行序）
        func commitFromControl(_ studentID: UUID, _ spec: StudentColumnSpec, _ edit: CellEdit) {
            suppressReloadOnce = parent.sortKey != spec.sortKey
            parent.onCommit(studentID, spec, edit)
        }

        func alignColumns(_ table: NSTableView, to columns: [StudentColumnSpec]) {
            EditableStudentTable.alignColumnsStatic(table, columns: columns,
                                                    storedWidths: parent.storedWidths)
        }


        // MARK: 筛选弹层自管理关闭（applicationDefined）

        private var filterDismissMonitor: Any?

        /// 弹层打开期间：点击弹层以外任意位置或按 ESC 关闭弹层，事件本身放行（不吞点击）
        func installFilterDismissMonitor() {
            removeFilterDismissMonitor()
            filterDismissMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                // 弹层窗口内部的事件放行（正常交互）
                if event.window === self.filterPopover?.contentViewController?.view.window {
                    return event
                }
                if event.type == .keyDown, event.keyCode != 53 {  // 53 = ESC
                    return event
                }
                self.closeFilterPopover()
                return event
            }
        }

        func closeFilterPopover() {
            filterPopover?.close()
        }

        private func removeFilterDismissMonitor() {
            if let monitor = filterDismissMonitor {
                NSEvent.removeMonitor(monitor)
                filterDismissMonitor = nil
            }
        }

        // MARK: 筛选弹层关闭原因诊断
        public func popoverDidClose(_ notification: Notification) {
            removeFilterDismissMonitor()
        }

        /// 打开某列的 Excel 式筛选面板
        func openFilterPopover(columnID: String, headerRect: NSRect) {
            guard let headerView = tableView?.headerView,
                  let spec = parent.columns.first(where: { $0.id == columnID }),
                  let store = parent.store else { return }
            filterPopover?.close()
            let popover = NSPopover()
            // 不用 .transient：滚动/表格重载/系统事件会让它毫秒级自动关闭（用户表现为“点不开”），
            // 且点击外部后的第一次点击会被吞。改为自管理：点击外部或 ESC 才关闭。
            popover.behavior = .applicationDefined
            let hosting = NSHostingController(
                rootView: ColumnFilterPopover(store: store, spec: spec)
                    .frame(width: 280)
                    // 控件底色（深色模式下为深灰而非纯黑），弹层边框箭头由系统绘制
                    .background(Color(nsColor: .controlBackgroundColor))
            )
            popover.contentViewController = hosting
            filterPopover = popover
            popover.delegate = self
            popover.show(relativeTo: headerRect, of: headerView, preferredEdge: .minY)
            installFilterDismissMonitor()
        }

        private func spec(for column: NSTableColumn) -> StudentColumnSpec? {
            parent.columns.first { $0.id == column.identifier.rawValue }
        }

        private func student(at row: Int) -> Student? {
            parent.students.indices.contains(row) ? parent.students[row] : nil
        }

        // MARK: 数据源

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.students.count
        }

        // MARK: 单元格视图（按列类型）

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let spec = spec(for: tableColumn), let student = student(at: row) else {
                return nil
            }
            switch spec.cellKind {
            case .checkbox:
                let view = tableView.makeView(withIdentifier: EditableStudentTable.checkboxCellID, owner: self)
                    as? StudentCheckboxCellView ?? StudentCheckboxCellView()
                view.identifier = EditableStudentTable.checkboxCellID
                view.button.state = boolValue(of: student, spec: spec) ? .on : .off
                view.button.target = self
                view.button.action = #selector(checkboxToggled(_:))
                return view

            case .datePicker:
                let view = tableView.makeView(withIdentifier: EditableStudentTable.dateCellID, owner: self)
                    as? StudentDateCellView ?? StudentDateCellView()
                view.identifier = EditableStudentTable.dateCellID
                if let date = customDate(of: student, spec: spec) {
                    view.button.title = Fmt.date.string(from: date)
                } else {
                    view.button.title = "设置日期"
                }
                view.button.target = self
                view.button.action = #selector(dateButtonTapped(_:))
                view.button.studentID = student.id
                view.button.columnID = spec.id
                return view

            case .dateTimePicker:
                let view = tableView.makeView(withIdentifier: EditableStudentTable.dateTimeCellID, owner: self)
                    as? StudentDateCellView ?? StudentDateCellView()
                view.identifier = EditableStudentTable.dateTimeCellID
                if let date = customDate(of: student, spec: spec) {
                    view.button.title = Fmt.dateTime.string(from: date)
                } else {
                    view.button.title = "设置日期"
                }
                view.button.target = self
                view.button.action = #selector(dateButtonTapped(_:))
                view.button.studentID = student.id
                view.button.columnID = spec.id
                return view

            case .multiChoice(let options):
                let view = tableView.makeView(withIdentifier: EditableStudentTable.multiChoiceCellID, owner: self)
                    as? StudentMultiChoiceCellView ?? StudentMultiChoiceCellView()
                view.identifier = EditableStudentTable.multiChoiceCellID
                let current = spec.displayText(of: student)
                view.button.title = current.isEmpty ? "选择…" : current
                view.button.target = self
                view.button.action = #selector(multiChoiceTapped(_:))
                view.options = options
                view.button.toolTip = options.joined(separator: "、")
                return view

            case .choice(let options):
                let view = tableView.makeView(withIdentifier: EditableStudentTable.choiceCellID, owner: self)
                    as? StudentChoiceCellView ?? StudentChoiceCellView()
                view.identifier = EditableStudentTable.choiceCellID
                view.popup.removeAllItems()
                view.popup.addItem(withTitle: "—")
                for option in options {
                    view.popup.addItem(withTitle: option)
                }
                let current = spec.displayText(of: student)
                view.popup.selectItem(withTitle: current.isEmpty ? "—" : current)
                view.popup.target = self
                view.popup.action = #selector(choiceSelected(_:))
                return view

            default:
                let view = tableView.makeView(withIdentifier: EditableStudentTable.textCellID, owner: self)
                    as? StudentTextCellView ?? StudentTextCellView()
                view.identifier = EditableStudentTable.textCellID
                view.textField?.stringValue = spec.displayText(of: student)
                view.textField?.isEditable = false
                view.textField?.isSelectable = false
                // 电话/身份证：非法值红色显示 + 悬停说明规则
                let text = spec.displayText(of: student)
                if !text.isEmpty, let field = spec.customField {
                    let invalid: Bool
                    switch field.type {
                    case .phone: invalid = !FieldFormat.isValidPhone(text)
                    case .idCard: invalid = !FieldFormat.isValidIDCard(text)
                    default: invalid = false
                    }
                    if invalid {
                        view.textField?.textColor = .systemRed
                        view.toolTip = field.type == .phone
                            ? "电话格式不正确（7-15 位数字，可带 +86/-/空格）"
                            : "身份证号应为 18 位（含校验码，末位可为 X）或 15 位"
                    }
                }
                return view
            }
        }

        private func boolValue(of student: Student, spec: StudentColumnSpec) -> Bool {
            if spec.field == .boarding { return student.isBoarding }
            if let f = spec.customField {
                if case .boolean(let value) = student.customValues[f.id.uuidString] { return value }
            }
            return false
        }

        private func dateValue(of student: Student, spec: StudentColumnSpec) -> Date {
            if let f = spec.customField,
               case .date(let date) = student.customValues[f.id.uuidString] {
                return date
            }
            return Date()
        }

        /// 自定义日期字段的当前值（空返回 nil）
        private func customDate(of student: Student, spec: StudentColumnSpec) -> Date? {
            guard let f = spec.customField,
                  case .date(let date)? = student.customValues[f.id.uuidString] else { return nil }
            return date
        }

        // MARK: 日期格（弹出式日历选择）

        var datePopover: NSPopover?

        @objc func dateButtonTapped(_ sender: NSButton) {
            guard let button = sender as? StudentDateButton,
                  let studentID = button.studentID,
                  let spec = parent.columns.first(where: { $0.id == button.columnID }),
                  let student = parent.students.first(where: { $0.id == studentID }) else { return }
            // 行未选中时先选中行，不弹日历（与其他控件格一致）
            if !parent.selection.contains(studentID) {
                parent.selection = [studentID]
                return
            }

            datePopover?.close()
            let picker = StudentGraphicalDatePicker()
            picker.datePickerStyle = .clockAndCalendar
            picker.datePickerElements = spec.cellKind == .dateTimePicker ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
            picker.dateValue = customDate(of: student, spec: spec) ?? Date()
            picker.studentID = studentID
            picker.columnID = spec.id
            picker.target = self
            picker.action = #selector(popoverDateChanged(_:))

            // 弹层按日历固有尺寸自适应，避免写死尺寸导致的截断/大片空白
            let size = picker.fittingSize
            picker.frame = NSRect(origin: .zero, size: size)
            picker.autoresizingMask = [.width, .height]
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.addSubview(picker)
            let controller = NSViewController()
            controller.view = container
            controller.preferredContentSize = size
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            datePopover = popover
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }

        @objc func popoverDateChanged(_ sender: NSDatePicker) {
            guard let picker = sender as? StudentGraphicalDatePicker,
                  let studentID = picker.studentID,
                  let spec = parent.columns.first(where: { $0.id == picker.columnID }) else { return }
            parent.onCommit(studentID, spec, .date(sender.dateValue))
        }

        // MARK: 编辑交互

        /// 双击文本单元格进入编辑（view-based 表格的文本编辑需手动开启）；
        /// 其他类型格维持原行为（控件格由各自控件直接交互）。
        @objc func doubleClickedRow() {
            guard let tableView else { return }
            let row = tableView.clickedRow
            let columnIndex = tableView.clickedColumn
            guard row >= 0, beginTextEdit(row: row, columnIndex: columnIndex) else { return }
        }

        /// 双击文本类单元格：临时启用字段编辑器就地编辑。
        /// 返回该格是否文本类并已进入编辑；结束编辑在 commitTextEdit 里还原静态显示。
        func beginTextEdit(row: Int, columnIndex: Int) -> Bool {
            guard let tableView, columnIndex >= 0, columnIndex < parent.columns.count else { return false }
            let spec = parent.columns[columnIndex]
            guard case .text(editable: true) = spec.cellKind,
                  let student = student(at: row),
                  let view = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: false)
                      as? StudentTextCellView,
                  let textField = view.textField else { return false }

            editingContext = (student.id, spec)
            textField.isEditable = true
            // isSelectable 必须一并临时打开，否则字段编辑器挂不上（单击要求落在行上，
            // 平时保持 false，编辑结束在 commitTextEdit 还原）
            textField.isSelectable = true
            // 三条提交路径都指向 coordinator，任一生效即提交（幂等）：
            // 1. textField.delegate 的 controlTextDidEndEditing（编辑结束，回车/失焦）
            // 2. textField 的 target/action（回车触发）
            // 3. tableView.delegate 的 controlTextDidEndEditing（AppKit 转发）
            textField.delegate = self
            textField.target = self
            textField.action = #selector(textFieldActionFired(_:))
            tableView.window?.makeFirstResponder(textField)
            DispatchQueue.main.async {
                textField.currentEditor()?.selectAll(nil)
            }
            return true
        }

        /// NSTextField 的 action（回车时触发）
        @objc func textFieldActionFired(_ sender: NSTextField) {
            commitTextEdit(sender)
        }

        /// 文本编辑结束：提交并还原为静态显示。
        /// 注意：view-based 表格转发该通知时 object 可能是 field editor（NSTextView），
        /// 必须取其委托的控件再提交，否则编辑结果会被静默丢弃。
        func controlTextDidEndEditing(_ obj: Notification) {
            let value: String
            let field: NSTextField?
            if let tf = obj.object as? NSTextField {
                field = tf
                value = tf.stringValue
            } else if let editor = obj.object as? NSTextView,
                      let tf = editor.delegate as? NSTextField {
                field = tf
                value = editor.string
            } else {
                field = nil
                value = ""
            }
            if let field {
                commitTextEdit(field, rawValue: value)
            }
        }

        /// 提交文本编辑（幂等：editingContext 取出即清空，防多路径重复提交）
        private func commitTextEdit(_ textField: NSTextField, rawValue: String? = nil) {
            guard let context = editingContext else { return }
            editingContext = nil
            textField.isEditable = false
            textField.isSelectable = false // 还原：单击继续落在行选择上
            textField.delegate = nil
            let value = rawValue ?? textField.stringValue
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let field = context.spec.customField {
                switch field.type {
                case .phone where !FieldFormat.isValidPhone(trimmed):
                    NSSound.beep()
                case .idCard where !FieldFormat.isValidIDCard(trimmed):
                    NSSound.beep()
                default:
                    break
                }
            }
            commitFromControl(context.studentID, context.spec, .text(value))
        }

        /// 勾选框：单击直接切换
        @objc func checkboxToggled(_ sender: NSButton) {
            guard let tableView else { return }
            let row = tableView.row(for: sender)
            let columnIndex = tableView.column(for: sender)
            guard row >= 0, columnIndex >= 0, columnIndex < parent.columns.count,
                  let student = student(at: row) else { return }
            let spec = parent.columns[columnIndex]
            // 行未选中时第一次点击只选中行（保证 ⌘/⇧ 多选顺畅）
            if !parent.selection.contains(student.id) {
                parent.selection = [student.id]
                sender.state = student.isBoarding ? .on : .off
                return
            }
            commitFromControl(student.id, spec, .boolean(sender.state == .on))
        }

        /// 多选：弹出勾选菜单，切换选项后拼接提交
        @objc func multiChoiceTapped(_ sender: NSButton) {
            guard let tableView,
                  let view = sender.superview as? StudentMultiChoiceCellView else { return }
            let row = tableView.row(for: sender)
            let columnIndex = tableView.column(for: sender)
            guard row >= 0, columnIndex >= 0, columnIndex < parent.columns.count,
                  let student = student(at: row), !view.options.isEmpty else { return }
            let spec = parent.columns[columnIndex]
            let options = view.options

            let current = Set(spec.displayText(of: student)
                .components(separatedBy: "、").filter { !$0.isEmpty })

            let menu = NSMenu()
            for option in options {
                let target: Set<String>
                if current.contains(option) {
                    target = current.subtracting([option])
                } else {
                    target = current.union([option])
                }
                let value = options.filter { target.contains($0) }.joined(separator: "、")
                let item = NSMenuItem(title: option,
                                      action: #selector(multiChoiceItemToggled(_:)),
                                      keyEquivalent: "")
                item.state = current.contains(option) ? .on : .off
                item.target = self
                item.representedObject = [
                    "studentID": student.id.uuidString,
                    "specID": spec.id,
                    "value": value
                ] as [String: Any]
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }

        @objc func multiChoiceItemToggled(_ sender: NSMenuItem) {
            guard let info = sender.representedObject as? [String: Any],
                  let studentIDString = info["studentID"] as? String,
                  let studentID = UUID(uuidString: studentIDString),
                  let specID = info["specID"] as? String,
                  let value = info["value"] as? String,
                  let spec = parent.columns.first(where: { $0.id == specID }) else { return }
            parent.onCommit(studentID, spec, .text(value))
        }

        /// 下拉选择：限定选项
        @objc func choiceSelected(_ sender: NSPopUpButton) {
            guard let tableView else { return }
            let row = tableView.row(for: sender)
            let columnIndex = tableView.column(for: sender)
            guard row >= 0, columnIndex >= 0, columnIndex < parent.columns.count,
                  let student = student(at: row) else { return }
            let spec = parent.columns[columnIndex]
            let value = sender.titleOfSelectedItem == "—" ? "" : (sender.titleOfSelectedItem ?? "")
            parent.onCommit(student.id, spec, .text(value))
        }

        // MARK: 选中变化（UI → 状态）

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { row in
                parent.students.indices.contains(row) ? parent.students[row].id : nil
            })
            if parent.selection != ids {
                parent.selection = ids
            }
        }

        // MARK: 排序

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let spec = parent.columns.first(where: { $0.sortKey?.rawValue == descriptor.key }),
                  let key = spec.sortKey else { return }
            parent.onSortChange(key, descriptor.ascending)
        }

        // MARK: 列拖拽重排（写回统一布局，表格/详情/字段管理共享）

        // MARK: 列宽记忆（拖拽结束后防抖保存）与自适应

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = tableView else { return }
            widthSaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let table = self.tableView else { return }
                for column in table.tableColumns {
                    let minW = min(Self.textWidth(column.title, font: NSFont.systemFont(ofSize: 12, weight: .semibold)) + 32, 280)
                    if column.width < minW { column.width = minW }
                    self.parent.onColumnWidthChange(column.identifier.rawValue, column.width)
                }
            }
            widthSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }

        /// 自适应列宽：列标题与各行显示文本的最大宽度 + 边距
        func performAutoFit() {
            guard let table = tableView else { return }
            let font = NSFont.systemFont(ofSize: 13)
            var newWidths: [String: CGFloat] = [:]
            for column in table.tableColumns {
                let id = column.identifier.rawValue
                guard let spec = parent.columns.first(where: { $0.id == id }) else { continue }
                var maxW = Self.textWidth(column.title, font: font)
                for student in parent.students.prefix(200) {
                    let text = spec.displayText(of: student)
                    if !text.isEmpty {
                        maxW = max(maxW, Self.textWidth(text, font: font))
                    }
                }
                let width = min(max(maxW + 26, 56), 420)
                column.width = width
                newWidths[id] = width
            }
            for (id, width) in newWidths {
                parent.onColumnWidthChange(id, width)
            }
        }

        static func textWidth(_ text: String, font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView else { return }
            let visibleIDs = tableView.tableColumns.map { $0.identifier.rawValue }
            let visibleSet = Set(visibleIDs)
            // 新布局 = 拖拽后的可见列顺序 + 隐藏列按旧布局顺序追加尾部
            let layout = visibleIDs + parent.storedLayout.filter { !visibleSet.contains($0) }
            parent.onLayoutChange(layout)
        }

        // MARK: 列标题右键菜单（Notion 式：排序 / 隐藏 / 重命名 / 删除）

        /// 菜单弹出时根据鼠标所在的列标题动态生成菜单项。
        /// 目标列在此时缓存——菜单项被点击时鼠标已移到菜单上，
        /// 不能再用鼠标位置反推（否则会取错列或不触发）。
        private var menuTargetColumn: StudentColumnSpec?

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            // 行菜单（表格体右键）：多选删除入口
            if menu !== tableView?.headerView?.menu {
                let count = parent.selection.count
                guard count > 0 else { return }
                let item = NSMenuItem(title: "删除选中的 \(count) 名学生…",
                                      action: #selector(deleteSelectionFromMenu), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
                return
            }
            // 列头菜单：筛选 / 排序 / 移动 / 隐藏 / 重命名 / 删除
            guard let index = headerColumnIndex() else { return }
            let spec = parent.columns[index]
            menuTargetColumn = spec

            if parent.store != nil {
                menu.addItem(item("筛选此列…", #selector(headerShowFilter)))
            }
            if spec.sortKey != nil {
                menu.addItem(item("按此列升序排序", #selector(headerSortAscending)))
                menu.addItem(item("按此列降序排序", #selector(headerSortDescending)))
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item("左移一列", #selector(headerMoveLeft)))
            menu.addItem(item("右移一列", #selector(headerMoveRight)))
            menu.addItem(item("隐藏此列", #selector(headerHideColumn)))
            // 修改类型：自定义字段任意类型互切；内置非必备列转为同名列的自定义字段并迁移数据
            if let store = parent.store {
                let typeMenu = NSMenu(title: "修改类型")
                let currentKind = spec.customField?.type.id
                let convertibleBuiltin = spec.customField == nil
                    && !ProjectStore.protectedBuiltinFields.contains(spec.id)
                    && spec.field != .recordCount
                    && spec.guardianSlot == nil
                let enabled = spec.customField != nil || convertibleBuiltin
                for type in FieldType.selectableTypes {
                    let typeItem = NSMenuItem(title: type.displayName,
                                              action: #selector(headerChangeType(_:)),
                                              keyEquivalent: "")
                    typeItem.target = self
                    typeItem.isEnabled = enabled
                    typeItem.representedObject = type.id
                    typeItem.state = type.id == currentKind ? .on : .off
                    typeMenu.addItem(typeItem)
                }
                let typeMenuItem = NSMenuItem(title: enabled ? "修改类型…" : "修改类型（此列不支持）",
                                              action: nil, keyEquivalent: "")
                typeMenuItem.submenu = typeMenu
                menu.addItem(typeMenuItem)
            }
            menu.addItem(NSMenuItem.separator())
            if spec.customField != nil {
                menu.addItem(item("重命名字段…", #selector(headerRenameColumn)))
            }
            let deleteItem = item("删除此列…", #selector(headerDeleteColumn))
            if ProjectStore.protectedBuiltinFields.contains(spec.id) {
                deleteItem.isEnabled = false // 姓名、学号必备列不可删
            }
            menu.addItem(deleteItem)
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            return i
        }

        private var clickedHeaderColumn: StudentColumnSpec? {
            menuTargetColumn
        }

        @MainActor @objc func headerChangeType(_ sender: NSMenuItem) {
            guard let spec = menuTargetColumn,
                  let store = parent.store,
                  let kind = sender.representedObject as? String,
                  let newType = FieldType.selectableTypes.first(where: { $0.id == kind }) else { return }
            if let custom = spec.customField {
                guard !custom.type.sameKind(as: newType) else { return }
                store.changeFieldType(fieldID: custom.id, to: newType)
            } else {
                // 内置列：转换为同名列的自定义字段并按新类型迁移值（姓名/学号/记录数/监护人列已被菜单禁用）
                store.convertBuiltinField(key: spec.id, to: newType)
            }
        }

        /// 鼠标当前所在的列标题索引
        private func headerColumnIndex() -> Int? {
            guard let tableView, let headerView = tableView.headerView,
                  let window = tableView.window else { return nil }
            let screenRect = NSRect(origin: NSEvent.mouseLocation, size: .zero)
            let windowPoint = window.convertFromScreen(screenRect).origin
            let location = headerView.convert(windowPoint, from: nil)
            let index = headerView.column(at: location)
            guard index >= 0, index < parent.columns.count else { return nil }
            return index
        }

        @objc func deleteSelectionFromMenu() {
            parent.onDeleteSelection()
        }

        /// 列头菜单：打开该列的 Excel 式筛选面板
        @objc func headerShowFilter() {
            guard let spec = clickedHeaderColumn,
                  let tableView,
                  let headerView = tableView.headerView else { return }
            let index = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(spec.id))
            guard index >= 0 else { return }
            openFilterPopover(columnID: spec.id, headerRect: headerView.headerRect(ofColumn: index))
        }

        @objc func headerSortAscending() {
            guard let spec = clickedHeaderColumn, let key = spec.sortKey else { return }
            parent.onSortChange(key, true)
        }

        @objc func headerSortDescending() {
            guard let spec = clickedHeaderColumn, let key = spec.sortKey else { return }
            parent.onSortChange(key, false)
        }

        @objc func headerHideColumn() {
            guard let spec = clickedHeaderColumn else { return }
            parent.onHideColumn(spec)
        }

        @objc func headerMoveLeft() {
            guard let spec = clickedHeaderColumn else { return }
            parent.onMoveColumn(spec, -1)
        }

        @objc func headerMoveRight() {
            guard let spec = clickedHeaderColumn else { return }
            parent.onMoveColumn(spec, 1)
        }

        @objc func headerRenameColumn() {
            guard let spec = clickedHeaderColumn else { return }
            parent.onRenameColumn(spec)
        }

        @objc func headerDeleteColumn() {
            guard let spec = clickedHeaderColumn else { return }
            parent.onDeleteColumn(spec)
        }
    }
}

// MARK: - 列筛选面板（Excel 自动筛选）

/// Excel 式列筛选：按值勾选清单 + 文字包含，实时生效并保存到当前视图
struct ColumnFilterPopover: View {
    @ObservedObject var store: ProjectStore
    let spec: StudentColumnSpec

    @State private var searchText = ""
    @State private var values: [String] = []
    @State private var checked: Set<String> = []
    /// onAppear 恢复已有筛选时不触发 apply（避免打开瞬间就写数据引发全表重载）
    @State private var restoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if spec.sortKey != nil {
                HStack(spacing: 8) {
                    Text("排序")
                        .font(.callout.weight(.medium))
                        .frame(width: 56, alignment: .leading)
                    Button("升序") { setSort(ascending: true) }
                        .buttonStyle(.bordered)
                    Button("降序") { setSort(ascending: false) }
                        .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("包含文字")
                    .font(.callout.weight(.medium))
                TextField("不限", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchText) { _ in
                        guard !restoring else { return }
                        apply()
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("值（\(values.count)）")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("全选") {
                        checked = Set(values)
                        apply()
                    }
                    Button("清空") {
                        checked = []
                        apply()
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(values, id: \.self) { value in
                            Toggle(isOn: Binding(
                                get: { checked.contains(value) },
                                set: { isOn in
                                    if isOn {
                                        checked.insert(value)
                                    } else {
                                        checked.remove(value)
                                    }
                                    apply()
                                }
                            )) {
                                Text(value.isEmpty ? "（空）" : value)
                                    .font(.callout)
                                    .lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                }
                .frame(height: min(CGFloat(values.count) * 22 + 10, 220))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
                )
            }

            HStack {
                Spacer()
                Button("清除该列筛选") {
                    store.setColumnFilter(columnID: spec.id, filter: nil)
                    checked = Set(values)
                    searchText = ""
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(12)
        .onAppear {
            restoring = true
            DispatchQueue.main.async { restoring = false }
            // 值清单始终取全部学生（不被已设置的筛选缩小范围，避免勾选项越筛越少）
            values = StudentQuery.distinctValues(column: spec, in: store.data.students)
            if let filter = store.currentView.columnFilters[spec.id] {
                searchText = filter.searchText
                checked = filter.selectedValues ?? Set(values)
            } else {
                checked = Set(values)
            }
        }
    }

    /// 应用当前勾选：全部勾选 = 不限制；部分勾选 = 白名单；另有文字包含条件叠加
    private func apply() {
        var filter = ColumnFilter()
        filter.searchText = searchText.trimmingCharacters(in: .whitespaces)
        if values.isEmpty || checked.count == values.count {
            filter.selectedValues = nil
        } else {
            filter.selectedValues = checked
        }
        if filter.isActive {
            store.setColumnFilter(columnID: spec.id, filter: filter)
        } else {
            store.setColumnFilter(columnID: spec.id, filter: nil)
        }
    }

    private func setSort(ascending: Bool) {
        guard let key = spec.sortKey else { return }
        var v = store.currentView
        v.sortKey = key
        v.sortAscending = ascending
        store.updateView(v)
    }
}
