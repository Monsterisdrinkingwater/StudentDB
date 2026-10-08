import SwiftUI
import UniformTypeIdentifiers

/// 估算文本宽度（列自适应用）
func genericTextWidth(_ text: String, font: NSFont = NSFont.systemFont(ofSize: 13)) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
}

// MARK: - 通用数据表区（记录表 / 自定义表的主视图区）

/// 当前表 ≠ 学生表时的右侧主区：表格 + 行详情两种布局。
struct GenericTableArea: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    @Binding var selection: Set<UUID>

    @State private var editingRowID: UUID?
    @State private var showAddRow = false
    @State private var showDeleteConfirm = false
    @State private var showFieldManager = false
    @State private var autoFitToken = 0
    @State private var importFile: ImportFile?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            contentArea

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showAddRow = true
                } label: {
                    Text("新增行")
                }
                .help("添加一行")

                Button {
                    if selection.count == 1, let id = selection.first { editingRowID = id }
                } label: {
                    Text("编辑")
                }
                .disabled(selection.count != 1)
                .help("编辑选中的行")

                Button {
                    showFieldManager = true
                } label: {
                    Text("字段")
                }
                .help("管理这张表的字段（增删改/类型/选项）")

                Button {
                    if let url = TableImportSheet.promptFile(tableName: table.name) {
                        importFile = ImportFile(url: url)
                    }
                } label: {
                    Text("导入")
                }
                .help("从 Excel / CSV 导入数据到这张表（支持列映射与覆盖已有行）")

                Button {
                    autoFitToken += 1
                } label: {
                    Text("适应内容")
                }
                .help("自动调整所有列宽，保证内容完整显示")

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("删除")
                }
                .disabled(selection.isEmpty)
                .help("删除选中的 \(selection.count) 行")
            }
        }
        .sheet(isPresented: $showAddRow) {
            RowEditorSheet(store: store, table: table, editingRowID: nil) { newID in
                selection = newID.map { [$0] } ?? []
            }
            .frame(width: 560)
        }
        .sheet(item: Binding(
            get: { editingRowID.map { EditingRow(id: $0) } },
            set: { editingRowID = $0?.id }
        )) { item in
            RowEditorSheet(store: store, table: table, editingRowID: item.id) { _ in }
                .frame(width: 560)
        }
        .sheet(isPresented: $showFieldManager) {
            TableFieldsSheet(store: store, tableID: table.id)
        }
        .sheet(item: $importFile) { file in
            TableImportSheet(store: store, table: table, fileURL: file.url)
        }
        .confirmationDialog(
            "删除选中的 \(selection.count) 行？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除 \(selection.count) 行", role: .destructive) {
                store.deleteRows(tableID: table.id, ids: selection)
                selection.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该行的附件将被移入废纸篓，可从访达恢复。")
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if table.fields.isEmpty {
            ContentUnavailableView("这张表还没有字段",
                                   systemImage: "tablecells",
                                   description: Text("点击右上方「添加字段」开始设计这张表。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tableVisibleRows.tableMode {
            genericTable
        } else if selection.count == 1, table.row(id: selection.first!) != nil {
            RowDetailView(store: store, table: table, rowID: selection.first!)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var genericTable: some View {
        GenericTableView(store: store, table: table, rows: tableVisibleRows.rows,
                         selection: $selection,
                         onOpenRow: { rowID in editingRowID = rowID },
                         onDeleteSelection: { showDeleteConfirm = true },
                         onColumnWidthChange: { columnID, width in
                             store.setTableColumnWidth(tableID: table.id, columnID: columnID, width: width)
                         },
                         autoFitToken: autoFitToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct EditingRow: Identifiable { let id: UUID }

    private var view: ListView { table.currentView }

    private var studentName: (UUID) -> String {
        let map = Dictionary(uniqueKeysWithValues: store.data.students.map { ($0.id, $0.name) })
        return { map[$0] ?? "（未知学生）" }
    }

    private var tableVisibleRows: (rows: [DBRow], tableMode: Bool) {
        let base = TableQuery.apply(view: view, rows: table.rows,
                                    fields: table.orderedFields, studentName: studentName)
        let filtered = TableQuery.applyColumnFilters(base, fields: table.orderedFields,
                                                     filters: view.columnFilters,
                                                     studentName: studentName)
        return (filtered, view.layout == .table || selection.count > 1)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: table.systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(table.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("· \(tableVisibleRows.rows.count) 行")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !view.columnFilters.isEmpty {
                Button {
                    updateTableView { v in v.columnFilters.removeAll() }
                } label: {
                    Label("列筛选 \(view.columnFilters.count) 项",
                          systemImage: "line.3.horizontal.decrease.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help("表格列上已设置筛选，点击全部清除")
            }
            Spacer()
            ViewLayoutSwitcher(layout: view.layout) { newValue in
                updateTableView { $0.layout = newValue }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        // 三种空态：表无行 / 有行但被筛掉 / 有行但未选中（详情布局）
        let hasRows = !table.rows.isEmpty
        let visibleEmpty = tableVisibleRows.rows.isEmpty
        return ContentUnavailableView(
            label: {
                if !hasRows {
                    Text("\(table.name) 还是空的")
                } else if visibleEmpty {
                    Text("没有匹配的行")
                } else {
                    Text("选择一行查看详情")
                }
            },
            description: {
                if !hasRows {
                    Text("点击右上方「新增行」开始填写数据。")
                } else if visibleEmpty {
                    Text("清除或调整筛选条件后可查看全部行。")
                } else {
                    Text("点击右上「表格」后选择一行，即可在此查看与编辑。")
                }
            }
        )
    }

    /// 修改当前表的视图（排序/布局/列显隐随视图保存；筛选为会话内状态）
    private func updateTableView(_ mutate: (inout ListView) -> Void) {
        var table = self.table
        guard var v = table.view(id: view.id) else { return }
        mutate(&v)
        guard let idx = table.views.firstIndex(where: { $0.id == v.id }) else { return }
        table.views[idx] = v
        table.currentViewID = v.id
        store.updateTable(table)
    }
}

// MARK: - 通用表格（SwiftUI Grid，Excel 式布局与表头交互）

// MARK: - 通用表格（NSTableView 内核，与学生表同一套交互）

/// 记录表/自定义表的表格视图：复用学生表的 NSTableView 方案——
/// 原生内联编辑（双击文本/数字，支持输入法）、⌘/⇧ 多选、列拖拽重排、列宽拖拽、
/// 表头漏斗筛选、表头右键菜单（排序/移动/隐藏/删除）。
struct GenericTableView: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let rows: [DBRow]
    @Binding var selection: Set<UUID>
    var onOpenRow: (UUID) -> Void = { _ in }
    var onDeleteSelection: () -> Void = {}
    var onColumnWidthChange: (String, CGFloat) -> Void = { _, _ in }
    var autoFitToken: Int = 0

    @State private var filterColumn: CustomField?
    @State private var pendingDeleteField: CustomField?

    private var view: ListView { table.currentView }
    private var fields: [CustomField] { table.visibleColumns(for: view) }

    var body: some View {
        ZStack {
            if fields.isEmpty {
                ContentUnavailableView("这张表还没有可见字段",
                                       systemImage: "eye.slash",
                                       description: Text("点击右上角「字段」菜单恢复或添加字段。"))
            } else {
                EditableGenericTable(
                    store: store,
                    table: table,
                    rows: rows,
                    fields: fields,
                    sortFieldID: view.sortFieldID,
                    sortAscending: view.sortAscending,
                    columnFilters: view.columnFilters,
                    selection: $selection,
                    onCommit: { rowID, field, value in
                        var updated = table.row(id: rowID) ?? DBRow()
                        updated.id = rowID
                        if let value {
                            updated.values[field.id.uuidString] = value
                        } else {
                            updated.values.removeValue(forKey: field.id.uuidString)
                        }
                        store.updateRow(tableID: table.id, row: updated)
                        try? store.saveNow()
                    },
                    onSortChange: { field, ascending in
                        mutateView { v in
                            v.sortFieldID = field.id
                            v.sortAscending = ascending
                        }
                    },
                    onHideField: { field in
                        mutateView { v in
                            v.hiddenColumnIDs.insert(field.id.uuidString)
                        }
                    },
                    onDeleteField: { field in
                        pendingDeleteField = field
                    },
                    onMoveFields: { visibleIDs in
                        // 拖拽后的可见列顺序 + 未显示字段追加尾部 → fieldOrder
                        var t = table
                        let visibleUUIDs = visibleIDs.compactMap { UUID(uuidString: $0) }
                        let visibleSet = Set(visibleUUIDs)
                        t.fieldOrder = visibleUUIDs + t.orderedFields
                            .filter { !visibleSet.contains($0.id) }
                            .map { $0.id }
                        store.updateTable(t)
                    },
                    onFilterField: { field in
                        filterColumn = field
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "删除字段「\(pendingDeleteField?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteField != nil },
                set: { if !$0 { pendingDeleteField = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除字段", role: .destructive) {
                if let field = pendingDeleteField {
                    store.deleteTableField(tableID: table.id, fieldID: field.id)
                }
                pendingDeleteField = nil
            }
            Button("取消", role: .cancel) { pendingDeleteField = nil }
        } message: {
            Text("所有行填写的该字段内容将被永久删除（可从项目备份恢复）。")
        }
        .sheet(item: $filterColumn) { field in
            GenericColumnFilterSheet(store: store, table: table, field: field)
                .frame(width: 310, height: 480)
        }
    }

    private func mutateView(_ mutate: (inout ListView) -> Void) {
        var t = table
        guard var v = t.view(id: view.id) else { return }
        mutate(&v)
        guard let idx = t.views.firstIndex(where: { $0.id == v.id }) else { return }
        t.views[idx] = v
        t.currentViewID = v.id
        store.updateTable(t)
    }
}

// MARK: - 可编辑通用 NSTableView

/// 附件格的点击上下文（NSMenuItem/NSButton 的 representedObject 需要引用类型）
final class TableCellContext {
    let fieldID: UUID
    let rowID: UUID
    init(fieldID: UUID, rowID: UUID) {
        self.fieldID = fieldID
        self.rowID = rowID
    }
}

/// 附件格菜单里对某个文件的动作
final class TableAttachmentFileAction {
    enum Kind { case open, reveal, delete }
    let url: URL
    let kind: Kind
    let context: TableCellContext
    init(url: URL, kind: Kind, context: TableCellContext) {
        self.url = url
        self.kind = kind
        self.context = context
    }
}

/// 附件格按钮（携带行/字段上下文，NSButton 无 representedObject）
final class TableAttachmentButton: NSButton {
    var context: TableCellContext?
}

/// 关联学生格按钮（携带上下文与当前关联，点菜单勾选学生）
final class TableStudentLinkButton: NSButton {
    var context: TableCellContext?
    var studentIDs: [UUID] = []
}

/// 日期格按钮（点击弹日历选择器改值）
final class TableDateButton: NSButton {
    var context: TableCellContext?
}

/// 弹出日历里的图形日期选择器（携带行/字段上下文）
final class TableGraphicalDatePicker: NSDatePicker {
    var context: TableCellContext?
}

struct EditableGenericTable: NSViewRepresentable {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let rows: [DBRow]
    let fields: [CustomField]
    let sortFieldID: UUID?
    let sortAscending: Bool
    var columnFilters: [String: ColumnFilter] = [:]
    @Binding var selection: Set<UUID>
    var onOpenRow: ((UUID) -> Void)? = nil
    var onDeleteSelection: () -> Void = {}
    var onCommit: (UUID, CustomField, CustomValue?) -> Void
    var onSortChange: (CustomField, Bool) -> Void
    var onHideField: (CustomField) -> Void
    var onDeleteField: (CustomField) -> Void
    var onMoveFields: ([String]) -> Void
    var onFilterField: (CustomField) -> Void
    var onColumnWidthChange: (String, CGFloat) -> Void = { _, _ in }
    var autoFitToken: Int = 0

    static let createdAtColumnID = "rowCreatedAt"
    static let textCellID = NSUserInterfaceItemIdentifier("genericTextCell")
    static let checkboxCellID = NSUserInterfaceItemIdentifier("genericCheckboxCell")
    static let dateCellID = NSUserInterfaceItemIdentifier("genericDateCell")
    static let choiceCellID = NSUserInterfaceItemIdentifier("genericChoiceCell")
    static let multiChoiceCellID = NSUserInterfaceItemIdentifier("genericMultiChoiceCell")
    static let attachmentCellID = NSUserInterfaceItemIdentifier("genericAttachmentCell")
    static let linkCellID = NSUserInterfaceItemIdentifier("genericStudentLinkCell")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = FilterableTableHeaderView()
        if let header = table.headerView as? FilterableTableHeaderView {
            header.onFilterTapped = { columnID, rect in
                context.coordinator.openFilterPopover(columnID: columnID.rawValue, headerRect: rect)
            }
        }
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = true
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClickedRow)
        context.coordinator.tableView = table

        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        table.headerView?.menu = headerMenu

        let rowMenu = NSMenu()
        rowMenu.delegate = context.coordinator
        table.menu = rowMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // 列：与字段对齐（集合变化才重建，保持宽度与滚动位置）
        let fieldIDs = fields.map { $0.id.uuidString }
        if fieldIDs != coordinator.columnIDs {
            coordinator.alignColumns(table)
            coordinator.columnIDs = fieldIDs
        }

        // 数据：签名变化才刷新；控件自身的提交跳过整表重载（单元格已显示新值）
        let signature = rows.map { "\($0.id.uuidString)#\($0.updatedAt.timeIntervalSince1970)" }
        if signature != coordinator.rowSignatures {
            let canSuppress = coordinator.suppressReloadOnce && rows.count == coordinator.lastRowCount
            coordinator.suppressReloadOnce = false
            coordinator.rowSignatures = signature
            if !canSuppress {
                table.reloadData()
                coordinator.pendingSelectionSync = true
            }
        }
        coordinator.lastRowCount = rows.count

        // 选中同步（仅在刷新数据或外部清空时执行，避免与用户 ⌘/⇧ 多选竞争）
        let desired = IndexSet(rows.enumerated().compactMap { selection.contains($0.element.id) ? $0.offset : nil })
        let native = IndexSet(table.selectedRowIndexes)
        if coordinator.pendingSelectionSync || (selection.isEmpty && !native.isEmpty) {
            if desired != native {
                table.deselectAll(coordinator)
                for index in desired.sorted() {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true)
                }
            }
            coordinator.pendingSelectionSync = false
        }

        // 排序指示
        if let field = fields.first(where: { $0.id == sortFieldID }) {
            let key = field.id.uuidString
            let needsUpdate: Bool
            if let current = table.sortDescriptors.first {
                needsUpdate = current.key != key || current.ascending != sortAscending
            } else {
                needsUpdate = true
            }
            if needsUpdate {
                table.sortDescriptors = [NSSortDescriptor(
                    key: key, ascending: sortAscending,
                    selector: #selector(NSString.localizedStandardCompare(_:)))]
            }
        } else if !table.sortDescriptors.isEmpty {
            table.sortDescriptors = []
        }

        // 自适应列宽（工具栏「适应内容」按钮触发）
        if autoFitToken != coordinator.lastAutoFitToken {
            coordinator.lastAutoFitToken = autoFitToken
            coordinator.performAutoFit()
        }

        // 漏斗高亮
        if let header = table.headerView as? FilterableTableHeaderView {
            header.activeFilterIDs = Set(fields.filter { columnFilters[$0.id.uuidString]?.isActive == true }
                .map { $0.id.uuidString })
        }
    }

    /// 列头完整显示标题所需的最小宽度（含漏斗预留）
    static func titleMinWidth(_ title: String) -> CGFloat {
        min(genericTextWidth(title, font: NSFont.systemFont(ofSize: 12, weight: .semibold)) + 36, 280)
    }

    static func idealWidth(_ field: CustomField) -> CGFloat {
        switch field.type {
        case .boolean: return 76
        case .date: return 130
        case .dateTime: return 150
        case .choice: return 110
        case .multiChoice: return 140
        case .linkStudents: return 130
        case .attachment: return 84
        default: return 140
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSControlTextEditingDelegate, NSMenuDelegate, NSTextFieldDelegate, NSPopoverDelegate {
        var parent: EditableGenericTable
        weak var tableView: NSTableView?
        var columnIDs: [String] = []
        var rowSignatures: [String] = []
        var editingContext: (rowID: UUID, field: CustomField)?
        var filterPopover: NSPopover?
        var lastAutoFitToken = 0
        private var widthSaveWork: DispatchWorkItem?
        var pendingSelectionSync = false
        /// 控件交互产生的提交：下一次数据变化只更新签名、不整表重载（避免夺走正在编辑的字段编辑器）
        var suppressReloadOnce = false
        var lastRowCount = 0

        init(_ parent: EditableGenericTable) { self.parent = parent }

        /// 控件直接交互的提交路径。排序或筛选依赖该字段时仍需整表重载（行序/可见性会变）。
        func commitFromControl(_ rowID: UUID, _ field: CustomField, _ value: CustomValue?) {
            suppressReloadOnce = parent.sortFieldID != field.id
                && parent.columnFilters[field.id.uuidString] == nil
            parent.onCommit(rowID, field, value)
        }

        private func fieldNameColumnWidth(_ field: CustomField) -> CGFloat {
            EditableGenericTable.idealWidth(field)
        }

        func alignColumns(_ table: NSTableView) {
            let fields = parent.fields
            let oldIDs = table.tableColumns.map { $0.identifier.rawValue }
            let newIDs = fields.map { $0.id.uuidString }
            let scroll = table.enclosingScrollView
            let savedOriginX = scroll?.contentView.bounds.origin.x ?? 0

            if Set(oldIDs) == Set(newIDs), oldIDs.count == newIDs.count {
                for (targetIndex, id) in newIDs.enumerated() {
                    if let current = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
                       current != targetIndex {
                        table.moveColumn(current, toColumn: targetIndex)
                    }
                }
                return
            }

            var widths: [String: CGFloat] = [:]
            for column in table.tableColumns {
                widths[column.identifier.rawValue] = column.width
            }
            for column in table.tableColumns {
                table.removeTableColumn(column)
            }
            for field in fields {
                let id = field.id.uuidString
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = field.name
                column.minWidth = 50
                column.maxWidth = 420
                column.width = max(widths[id] ?? parent.table.columnWidths[id] ?? EditableGenericTable.idealWidth(field),
                                   EditableGenericTable.titleMinWidth(field.name))
                column.sortDescriptorPrototype = NSSortDescriptor(
                    key: id, ascending: true,
                    selector: #selector(NSString.localizedStandardCompare(_:)))
                table.addTableColumn(column)
            }
            // 行创建时间（只读虚拟列，不占用字段定义）
            if !table.tableColumns.contains(where: { $0.identifier.rawValue == EditableGenericTable.createdAtColumnID }) {
                let created = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(EditableGenericTable.createdAtColumnID))
                created.title = "创建时间"
                created.minWidth = 90
                created.maxWidth = 200
                created.width = 150
                table.addTableColumn(created)
            }
            if let scroll, savedOriginX > 0 {
                let maxX = max(0, scroll.contentView.bounds.width - scroll.contentView.frame.width)
                scroll.contentView.setBoundsOrigin(NSPoint(x: min(savedOriginX, maxX + 200), y: 0))
            }
        }

        private func field(for column: NSTableColumn?) -> CustomField? {
            guard let column else { return nil }
            return parent.fields.first { $0.id.uuidString == column.identifier.rawValue }
        }

        private func rowAt(_ index: Int) -> DBRow? {
            parent.rows.indices.contains(index) ? parent.rows[index] : nil
        }

        // MARK: 数据源

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        // MARK: 单元格渲染

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let dbRow = rowAt(row) else { return nil }
            // 行创建时间（只读）
            if tableColumn?.identifier.rawValue == EditableGenericTable.createdAtColumnID {
                let cell = tableView.makeView(withIdentifier: EditableGenericTable.textCellID, owner: self) as? StudentTextCellView
                    ?? StudentTextCellView()
                cell.identifier = EditableGenericTable.textCellID
                cell.textField?.stringValue = Fmt.dateTime.string(from: dbRow.createdAt)
                cell.textField?.textColor = .secondaryLabelColor
                return cell
            }
            guard let field = field(for: tableColumn) else { return nil }
            let value = dbRow.values[field.id.uuidString]
            let rowID = dbRow.id

            func makeText(_ text: String, gray: Bool = false) -> StudentTextCellView {
                let cell = tableView.makeView(withIdentifier: EditableGenericTable.textCellID, owner: self) as? StudentTextCellView
                    ?? StudentTextCellView()
                cell.identifier = EditableGenericTable.textCellID
                cell.textField?.stringValue = text
                cell.textField?.textColor = gray ? .tertiaryLabelColor : .labelColor
                // 复用格还原静态显示（就地编辑临时打开的可编辑/可选状态关回去）
                cell.textField?.isEditable = false
                cell.textField?.isSelectable = false
                return cell
            }

            switch field.type {
            case .boolean:
                let cell = tableView.makeView(withIdentifier: EditableGenericTable.checkboxCellID, owner: self) as? StudentCheckboxCellView
                    ?? StudentCheckboxCellView()
                cell.identifier = EditableGenericTable.checkboxCellID
                cell.button.target = self
                cell.button.action = #selector(checkboxToggled(_:))
                cell.button.state = value?.displayText == "是" ? .on : .off
                return cell
            case .date, .dateTime:
                // 按钮＋弹出式日历：内嵌 NSDatePicker 在表格里交互不可靠，改用弹层选择
                let cell = tableView.makeView(withIdentifier: EditableGenericTable.dateCellID, owner: self) as? TableDateButton
                    ?? {
                        let button = TableDateButton(title: "", target: nil, action: nil)
                        button.identifier = EditableGenericTable.dateCellID
                        button.isBordered = false
                        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                        button.alignment = .left
                        button.lineBreakMode = .byTruncatingTail
                        return button
                    }()
                if case .date(let d)? = value {
                    cell.title = field.type == .dateTime
                        ? Fmt.dateTime.string(from: d)
                        : Fmt.date.string(from: d)
                } else {
                    cell.title = "设置日期"
                }
                cell.target = self
                cell.action = #selector(dateButtonTapped(_:))
                cell.context = TableCellContext(fieldID: field.id, rowID: rowID)
                return cell
            case .choice(let options):
                let cell = tableView.makeView(withIdentifier: EditableGenericTable.choiceCellID, owner: self) as? StudentChoiceCellView
                    ?? StudentChoiceCellView()
                cell.identifier = EditableGenericTable.choiceCellID
                cell.popup.removeAllItems()
                cell.popup.addItem(withTitle: "—")
                for option in options { cell.popup.addItem(withTitle: option) }
                let current = value?.displayText ?? ""
                cell.popup.selectItem(withTitle: current.isEmpty ? "—" : current)
                cell.popup.target = self
                cell.popup.action = #selector(choiceSelected(_:))
                return cell
            case .multiChoice(let options):
                let cell = tableView.makeView(withIdentifier: EditableGenericTable.multiChoiceCellID, owner: self) as? StudentMultiChoiceCellView
                    ?? StudentMultiChoiceCellView()
                cell.identifier = EditableGenericTable.multiChoiceCellID
                cell.options = options
                cell.button.title = value?.displayText.isEmpty == false ? value!.displayText : "（空）"
                cell.button.target = self
                cell.button.action = #selector(multiChoiceTapped(_:))
                return cell
            case .linkStudents:
                let ids = value?.linkedStudentIDs ?? []
                let map = Dictionary(uniqueKeysWithValues: parent.store.data.students.map { ($0.id, $0.name) })
                let text = ids.map { map[$0] ?? "（未知学生）" }.joined(separator: "、")
                let cell = tableView.makeView(withIdentifier: EditableGenericTable.linkCellID, owner: self) as? TableStudentLinkButton ?? {
                    let button = TableStudentLinkButton(title: "", target: nil, action: nil)
                    button.identifier = EditableGenericTable.linkCellID
                    button.isBordered = false
                    button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                    button.alignment = .left
                    button.lineBreakMode = .byTruncatingTail
                    return button
                }()
                cell.title = text.isEmpty ? "选择学生" : text
                cell.target = self
                cell.action = #selector(studentLinkTapped(_:))
                cell.context = TableCellContext(fieldID: field.id, rowID: rowID)
                cell.studentIDs = ids
                return cell
            case .attachment:
                let count = parent.store.attachmentFileURLs(tableID: parent.table.id, rowID: rowID, fieldID: field.id).count
                let cell = tableView.makeView(withIdentifier: EditableGenericTable.attachmentCellID, owner: self) as? TableAttachmentButton ?? {
                    let button = TableAttachmentButton(title: "", target: nil, action: nil)
                    button.identifier = EditableGenericTable.attachmentCellID
                    button.isBordered = false
                    button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                    button.alignment = .left
                    return button
                }()
                cell.title = count > 0 ? "📎 \(count)" : "＋ 添加"
                cell.target = self
                cell.action = #selector(attachmentTapped(_:))
                cell.context = TableCellContext(fieldID: field.id, rowID: rowID)
                return cell
            default:
                let text = value?.displayText ?? ""
                return makeText(text, gray: text.isEmpty)
            }
        }

        // MARK: 附件格（表格内直接添加/管理附件）

        @objc func attachmentTapped(_ sender: NSButton) {
            guard let button = sender as? TableAttachmentButton,
                  let ctx = button.context else { return }
            let menu = NSMenu()

            let add = NSMenuItem(title: "添加附件…", action: #selector(attachmentAddTapped(_:)), keyEquivalent: "")
            add.target = self
            add.representedObject = ctx
            menu.addItem(add)

            let files = parent.store.attachmentFileURLs(tableID: parent.table.id, rowID: ctx.rowID, fieldID: ctx.fieldID)
            if !files.isEmpty {
                menu.addItem(.separator())
                for url in files {
                    let item = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
                    item.submenu = attachmentFileMenu(url: url, context: ctx)
                    menu.addItem(item)
                }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }

        private func attachmentFileMenu(url: URL, context: TableCellContext) -> NSMenu {
            let sub = NSMenu()
            for kind in [TableAttachmentFileAction.Kind.open, .reveal, .delete] {
                let title: String
                switch kind {
                case .open: title = "打开"
                case .reveal: title = "在访达中显示"
                case .delete: title = "删除（移入废纸篓）"
                }
                let item = NSMenuItem(title: title, action: #selector(attachmentFileAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = TableAttachmentFileAction(url: url, kind: kind, context: context)
                sub.addItem(item)
            }
            return sub
        }

        @objc func attachmentAddTapped(_ item: NSMenuItem) {
            guard let ctx = item.representedObject as? TableCellContext else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.message = "选中的文件会复制进项目包，随项目一起保存"
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            var failed = 0
            for url in panel.urls {
                do {
                    try parent.store.importAttachment(at: url, tableID: parent.table.id,
                                                      rowID: ctx.rowID, fieldID: ctx.fieldID)
                } catch {
                    failed += 1
                }
            }
            if failed > 0 { NSSound.beep() }
            tableView?.reloadData()
        }

        @objc func attachmentFileAction(_ item: NSMenuItem) {
            guard let action = item.representedObject as? TableAttachmentFileAction else { return }
            switch action.kind {
            case .open:
                parent.store.openAttachment(action.url)
            case .reveal:
                parent.store.revealInFinder(action.url)
            case .delete:
                parent.store.deleteAttachment(action.url)
                tableView?.reloadData()
            }
        }

        // MARK: 关联学生格（表格内直接勾选关联学生）

        @objc func studentLinkTapped(_ sender: NSButton) {
            guard let button = sender as? TableStudentLinkButton,
                  let ctx = button.context else { return }
            let dbRow = parent.rows.first { $0.id == ctx.rowID }
            // 行未选中时先选中行，不弹菜单（与勾选/多选格一致）
            if let dbRow, !parent.selection.contains(dbRow.id) {
                parent.selection = [dbRow.id]
                return
            }
            let current = Set(button.studentIDs)
            let students = parent.store.data.students.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if students.isEmpty { NSSound.beep(); return }

            let menu = NSMenu()
            for student in students {
                let target = current.contains(student.id)
                    ? current.subtracting([student.id])
                    : current.union([student.id])
                let item = NSMenuItem(title: student.name,
                                      action: #selector(studentLinkItemToggled(_:)),
                                      keyEquivalent: "")
                item.state = current.contains(student.id) ? .on : .off
                item.target = self
                item.representedObject = [
                    "rowID": ctx.rowID.uuidString,
                    "fieldID": ctx.fieldID.uuidString,
                    "ids": target.map { $0.uuidString }
                ] as [String: Any]
                menu.addItem(item)
            }
            if !current.isEmpty {
                menu.addItem(.separator())
                let clear = NSMenuItem(title: "清空关联", action: #selector(studentLinkItemToggled(_:)), keyEquivalent: "")
                clear.target = self
                clear.representedObject = [
                    "rowID": ctx.rowID.uuidString,
                    "fieldID": ctx.fieldID.uuidString,
                    "ids": [String]()
                ] as [String: Any]
                menu.addItem(clear)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }

        @objc func studentLinkItemToggled(_ sender: NSMenuItem) {
            guard let info = sender.representedObject as? [String: Any],
                  let rowIDString = info["rowID"] as? String,
                  let rowID = UUID(uuidString: rowIDString),
                  let fieldIDString = info["fieldID"] as? String,
                  let fieldID = UUID(uuidString: fieldIDString),
                  let idStrings = info["ids"] as? [String],
                  let field = parent.fields.first(where: { $0.id == fieldID }) else { return }
            let ids = idStrings.compactMap { UUID(uuidString: $0) }
            parent.onCommit(rowID, field, ids.isEmpty ? nil : .link(ids))
        }

        // MARK: 双击行 → 文本格就地编辑 / 其他格打开行编辑器

        @objc func doubleClickedRow() {
            guard let tableView else { return }
            let row = tableView.clickedRow
            let columnIndex = tableView.clickedColumn
            guard row >= 0, let dbRow = rowAt(row) else { return }
            // 文本/数字/地址格：双击就地编辑；其他类型格：打开行编辑器（原行为）
            if beginTextEdit(row: row, columnIndex: columnIndex, rowID: dbRow.id) { return }
            parent.onOpenRow?(dbRow.id)
        }

        /// 双击文本类单元格（text / number / address）：临时启用字段编辑器就地编辑。
        /// 返回该格是否文本类并已进入编辑；结束编辑在 commitEditingText 里还原静态显示。
        /// （单击语义不受影响：平时 isSelectable=false，单击落在行选择/⌘/⇧ 多选上）
        func beginTextEdit(row: Int, columnIndex: Int, rowID: UUID) -> Bool {
            guard let tableView, columnIndex >= 0,
                  let column = tableView.tableColumns[safe: columnIndex],
                  let field = field(for: column),
                  field.type == .text || field.type == .number || field.type == .address,
                  let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: false)
                      as? StudentTextCellView,
                  let textField = cell.textField else { return false }

            editingContext = (rowID, field)
            textField.isEditable = true
            // isSelectable 必须一并临时打开，否则字段编辑器挂不上（平时保持 false，
            // 保证单击落在行上；编辑结束在 commitEditingText 还原）
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

        // MARK: 文本编辑（双击进入，三条提交路径）

        func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
            guard let field = field(for: tableColumn), let dbRow = rowAt(row) else { return false }
            switch field.type {
            case .text, .address, .number, .phone, .idCard:
                editingContext = (dbRow.id, field)
                return true
            default:
                return false // 布尔/日期/选择由控件直接交互
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            commitEditingText(from: obj.object)
        }

        @objc func textFieldActionFired(_ sender: NSTextField) {
            commitEditingText(from: sender)
        }

        private func commitEditingText(from object: Any?) {
            guard let (rowID, field) = editingContext else { return }
            guard let textField = object as? NSTextField ?? (object as? NSTextView)?.delegate as? NSTextField else { return }
            // object 可能是字段编辑器（NSTextView），此时取编辑器里的实时文本
            let raw = ((object as? NSTextView)?.string ?? textField.stringValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            editingContext = nil
            // 还原为静态显示：isSelectable/isEditable 关回去，单击继续落在行选择上
            textField.isEditable = false
            textField.isSelectable = false
            textField.delegate = nil
            var value: CustomValue?
            switch field.type {
            case .number:
                if raw.isEmpty { value = nil }
                else if let n = Double(raw) { value = .number(n) }
                else { NSSound.beep(); return }
            case .phone:
                // 非法电话：蜂鸣报错，值保留为红色显示（悬停说明规则），便于稍后修正
                if !raw.isEmpty && !FieldFormat.isValidPhone(raw) { NSSound.beep() }
                value = raw.isEmpty ? nil : .text(raw)
            case .idCard:
                if !raw.isEmpty && !FieldFormat.isValidIDCard(raw) { NSSound.beep() }
                value = raw.isEmpty ? nil : .text(raw)
            default:
                value = raw.isEmpty ? nil : .text(raw)
            }
            commitFromControl(rowID, field, value)
        }

        // MARK: 控件动作

        @objc func checkboxToggled(_ sender: NSButton) {
            guard let tableView else { return }
            let row = tableView.row(for: sender)
            let columnIndex = tableView.column(for: sender)
            guard row >= 0, columnIndex >= 0,
                  let dbRow = rowAt(row),
                  let column = tableView.tableColumns[safe: columnIndex],
                  let field = field(for: column) else { return }
            // 第一次点击只选中行（行未选中时先选中，不切换勾选）——保证多选不受干扰
            if !parent.selection.contains(dbRow.id) {
                parent.selection = [dbRow.id]
                sender.state = dbRow.values[field.id.uuidString]?.displayText == "是" ? .on : .off
                return
            }
            commitFromControl(dbRow.id, field, .boolean(sender.state == .on))
        }

        // MARK: 日期格（弹出式日历选择）

        var datePopover: NSPopover?

        @objc func dateButtonTapped(_ sender: NSButton) {
            guard let button = sender as? TableDateButton,
                  let ctx = button.context,
                  let field = parent.fields.first(where: { $0.id == ctx.fieldID }) else { return }
            guard let dbRow = parent.rows.first(where: { $0.id == ctx.rowID }) else { return }
            // 行未选中时先选中行，不弹日历（与其他控件格一致）
            if !parent.selection.contains(dbRow.id) {
                parent.selection = [dbRow.id]
                return
            }

            datePopover?.close()
            let picker = TableGraphicalDatePicker()
            picker.datePickerStyle = .clockAndCalendar
            picker.datePickerElements = field.type == .dateTime ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
            picker.dateValue = (dbRow.values[field.id.uuidString].flatMap {
                if case .date(let d) = $0 { return d } else { return nil }
            }) ?? Date()
            picker.context = ctx
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
            guard let picker = sender as? TableGraphicalDatePicker,
                  let ctx = picker.context,
                  let field = parent.fields.first(where: { $0.id == ctx.fieldID }) else { return }
            // 走直接提交（整表刷新按钮文字）；弹层是独立窗口不受刷新影响
            parent.onCommit(ctx.rowID, field, .date(sender.dateValue))
        }

        @objc func choiceSelected(_ sender: NSPopUpButton) {
            guard let tableView else { return }
            let row = tableView.row(for: sender)
            let columnIndex = tableView.column(for: sender)
            guard row >= 0, columnIndex >= 0,
                  let dbRow = rowAt(row),
                  let column = tableView.tableColumns[safe: columnIndex],
                  let field = field(for: column) else { return }
            let value = sender.titleOfSelectedItem == "—" ? "" : (sender.titleOfSelectedItem ?? "")
            commitFromControl(dbRow.id, field, value.isEmpty ? nil : .text(value))
        }

        @objc func multiChoiceTapped(_ sender: NSButton) {
            guard let tableView,
                  let view = sender.superview as? StudentMultiChoiceCellView else { return }
            let row = tableView.row(for: sender)
            let columnIndex = tableView.column(for: sender)
            guard row >= 0, columnIndex >= 0,
                  let dbRow = rowAt(row),
                  let column = tableView.tableColumns[safe: columnIndex],
                  let field = field(for: column), !view.options.isEmpty else { return }
            // 行未选中时先选中行，不弹菜单
            if !parent.selection.contains(dbRow.id) {
                parent.selection = [dbRow.id]
                return
            }
            let current = Set((dbRow.values[field.id.uuidString]?.displayText ?? "")
                .components(separatedBy: "、").filter { !$0.isEmpty })

            let menu = NSMenu()
            for option in view.options {
                let target: Set<String>
                if current.contains(option) {
                    target = current.subtracting([option])
                } else {
                    target = current.union([option])
                }
                let joined = view.options.filter { target.contains($0) }.joined(separator: "、")
                let item = NSMenuItem(title: option,
                                      action: #selector(multiChoiceItemToggled(_:)),
                                      keyEquivalent: "")
                item.state = current.contains(option) ? .on : .off
                item.target = self
                item.representedObject = [
                    "rowID": dbRow.id.uuidString,
                    "fieldID": field.id.uuidString,
                    "value": joined
                ] as [String: Any]
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }

        @objc func multiChoiceItemToggled(_ sender: NSMenuItem) {
            guard let info = sender.representedObject as? [String: Any],
                  let rowIDString = info["rowID"] as? String,
                  let rowID = UUID(uuidString: rowIDString),
                  let fieldIDString = info["fieldID"] as? String,
                  let fieldID = UUID(uuidString: fieldIDString),
                  let value = info["value"] as? String,
                  let field = parent.fields.first(where: { $0.id == fieldID }) else { return }
            parent.onCommit(rowID, field, value.isEmpty ? nil : .text(value))
        }

        // MARK: 选中同步

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { rowIdx -> UUID? in
                parent.rows.indices.contains(rowIdx) ? parent.rows[rowIdx].id : nil
            })
            if parent.selection != ids {
                parent.selection = ids
            }
        }

        // MARK: 列拖拽重排 → fieldOrder

        // MARK: 列宽记忆（防抖保存）与自适应

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = tableView else { return }
            widthSaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let table = self.tableView else { return }
                for column in table.tableColumns where column.identifier.rawValue != EditableGenericTable.createdAtColumnID {
                    // 不允许拖窄到标题与漏斗重叠
                    let minW = EditableGenericTable.titleMinWidth(column.title)
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
            let map = Dictionary(uniqueKeysWithValues: parent.store.data.students.map { ($0.id, $0.name) })
            let studentName = { (id: UUID) -> String in map[id] ?? "（未知学生）" }
            let font = NSFont.systemFont(ofSize: 13)
            var newWidths: [String: CGFloat] = [:]
            for column in table.tableColumns {
                let id = column.identifier.rawValue
                if id == EditableGenericTable.createdAtColumnID {
                    column.width = 150
                    continue
                }
                guard let field = parent.fields.first(where: { $0.id.uuidString == id }) else { continue }
                var maxW = genericTextWidth(column.title, font: font)
                for row in parent.rows.prefix(200) {
                    let text = TableQuery.displayText(of: row, field: field, studentName: studentName)
                    if !text.isEmpty {
                        maxW = max(maxW, genericTextWidth(text, font: font))
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

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView else { return }
            let visibleIDs = tableView.tableColumns.map { $0.identifier.rawValue }
            parent.onMoveFields(visibleIDs)
        }

        // MARK: 表头右键菜单

        private var menuTargetField: CustomField?

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu !== tableView?.headerView?.menu {
                let count = parent.selection.count
                guard count > 0 else { return }
                let item = NSMenuItem(title: "删除选中的 \(count) 行…",
                                      action: #selector(deleteSelectionFromMenu), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
                return
            }
            guard let headerView = tableView?.headerView,
                  let window = tableView?.window else { return }
            let screenRect = NSRect(origin: NSEvent.mouseLocation, size: .zero)
            let windowPoint = window.convertFromScreen(screenRect).origin
            let location = headerView.convert(windowPoint, from: nil)
            let index = headerView.column(at: location)
            guard index >= 0, index < parent.fields.count else { return }
            let field = parent.fields[index]
            menuTargetField = field

            menu.addItem(item("筛选此列…", #selector(headerShowFilter)))
            menu.addItem(item("按此列升序排序", #selector(headerSortAscending)))
            menu.addItem(item("按此列降序排序", #selector(headerSortDescending)))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item("左移一列", #selector(headerMoveLeft)))
            menu.addItem(item("右移一列", #selector(headerMoveRight)))
            menu.addItem(item("隐藏此列", #selector(headerHideColumn)))
            menu.addItem(NSMenuItem.separator())
            // 修改类型：任意类型互切，存量行值自动转换（转换失败的清除、单选/多选并入选项）
            let typeMenu = NSMenu(title: "修改类型")
            for type in FieldType.selectableTypes + [.linkStudents] {
                let typeItem = NSMenuItem(title: type.displayName,
                                          action: #selector(headerChangeType(_:)),
                                          keyEquivalent: "")
                typeItem.target = self
                typeItem.representedObject = type.id
                typeItem.state = type.sameKind(as: field.type) ? .on : .off
                typeMenu.addItem(typeItem)
            }
            let typeMenuItem = NSMenuItem(title: "修改类型…", action: nil, keyEquivalent: "")
            typeMenuItem.submenu = typeMenu
            menu.addItem(typeMenuItem)
            menu.addItem(NSMenuItem.separator())
            let deleteItem = item("删除此列…", #selector(headerDeleteField))
            menu.addItem(deleteItem)
        }

        @objc func headerChangeType(_ sender: NSMenuItem) {
            guard let field = menuTargetField,
                  let kind = sender.representedObject as? String else { return }
            let newType = FieldType.selectableTypes.first { $0.id == kind } ?? .linkStudents
            guard !field.type.sameKind(as: newType) else { return }
            parent.store.changeTableFieldType(tableID: parent.table.id, fieldID: field.id, to: newType)
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            return i
        }

        @objc func deleteSelectionFromMenu() {
            parent.onDeleteSelection()
        }

        @objc func headerShowFilter() {
            guard let field = menuTargetField else { return }
            parent.onFilterField(field)
        }

        @objc func headerSortAscending() {
            guard let field = menuTargetField else { return }
            parent.onSortChange(field, true)
        }

        @objc func headerSortDescending() {
            guard let field = menuTargetField else { return }
            parent.onSortChange(field, false)
        }

        @objc func headerMoveLeft() {
            guard let field = menuTargetField else { return }
            parent.store.moveTableFieldByMenu(tableID: parent.table.id, fieldID: field.id, offset: -1)
        }

        @objc func headerMoveRight() {
            guard let field = menuTargetField else { return }
            parent.store.moveTableFieldByMenu(tableID: parent.table.id, fieldID: field.id, offset: 1)
        }

        @objc func headerHideColumn() {
            guard let field = menuTargetField else { return }
            parent.onHideField(field)
        }

        @objc func headerDeleteField() {
            guard let field = menuTargetField else { return }
            parent.onDeleteField(field)
        }

        // MARK: 筛选弹窗


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

        func openFilterPopover(columnID: String, headerRect: NSRect) {
            guard let headerView = tableView?.headerView,
                  let field = parent.fields.first(where: { $0.id.uuidString == columnID }) else { return }
            filterPopover?.close()
            let popover = NSPopover()
            // 不用 .transient：滚动/表格重载/系统事件会让它毫秒级自动关闭（用户表现为“点不开”），
            // 且点击外部后的第一次点击会被吞。改为自管理：点击外部或 ESC 才关闭。
            popover.behavior = .applicationDefined
            let hosting = NSHostingController(
                rootView: GenericColumnFilterSheet(store: parent.store, table: parent.table, field: field)
                    .frame(width: 300, height: 470)
                    // 控件底色（深色模式下为深灰而非纯黑），弹层边框箭头由系统绘制
                    .background(Color(nsColor: .controlBackgroundColor))
            )
            popover.contentViewController = hosting
            filterPopover = popover
            popover.delegate = self
            // 锚定到漏斗按钮（稳定叶子视图）：表头会在每次布局/绘制时增删子视图，
            // 以表头为锚会被 AppKit 判定锚失效而自动关闭弹层（表现为“点不开”）
            if let funnel = (headerView as? FilterableTableHeaderView)?.buttons[columnID] {
                popover.show(relativeTo: funnel.bounds.insetBy(dx: -4, dy: -4),
                             of: funnel, preferredEdge: .minY)
            } else {
                popover.show(relativeTo: headerRect, of: headerView, preferredEdge: .minY)
            }
            installFilterDismissMonitor()
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 通用单元格（就地编辑，实时写回）

struct GenericCellView: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let field: CustomField
    let row: DBRow
    @Binding var selection: Set<UUID>

    @State private var textDraft: String?
    @State private var showLinkPicker = false
    @FocusState private var draftFocused: Bool

    private var value: CustomValue? { row.values[field.id.uuidString] }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
            // Excel 语义：行已选中时单击单元格直接进入编辑；否则先选中行
            .onTapGesture {
                if isTextEditable {
                    if selection.contains(row.id) {
                        beginEdit()
                    } else {
                        selection = [row.id]
                    }
                }
            }
            .popover(isPresented: $showLinkPicker, arrowEdge: .bottom) {
                StudentLinkEditor(store: store, selected: Binding(
                    get: { value?.linkedStudentIDs ?? [] },
                    set: { ids in
                        var updated = row
                        if ids.isEmpty {
                            updated.values.removeValue(forKey: field.id.uuidString)
                        } else {
                            updated.values[field.id.uuidString] = .link(ids)
                        }
                        store.updateRow(tableID: table.id, row: updated)
                    }
                ))
                .frame(width: 280, height: 340)
            }
    }

    private var isTextEditable: Bool {
        switch field.type {
        case .text, .address, .number, .phone, .idCard: return true
        default: return false
        }
    }

    private func beginEdit() {
        guard textDraft == nil else { return }
        textDraft = displayText
        // 下一帧再聚焦，确保 TextField 已上屏
        DispatchQueue.main.async { draftFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        switch field.type {
        case .text, .address, .number, .phone, .idCard:
            if let draft = textDraft {
                TextField("", text: Binding(get: { draft }, set: { textDraft = $0 }),
                          onCommit: commitDraft)
                    .textFieldStyle(.plain)
                    .focused($draftFocused)
                    .onChange(of: draftFocused) { focused in
                        if !focused { commitDraft() } // 失焦自动保存
                    }
            } else {
                Text(displayText)
                    .lineLimit(1)
                    .foregroundStyle(displayText.isEmpty ? Color.secondary.opacity(0.5) : .primary)
                    .onTapGesture(count: 2) { beginEdit() }
            }
        case .boolean:
            Toggle("", isOn: Binding(
                get: { (value?.displayText ?? "否") == "是" },
                set: { v in write(.boolean(v)) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
        case .date:
            DatePicker("", selection: Binding(
                get: { dateValue ?? Date() },
                set: { v in write(.date(v)) }
            ), displayedComponents: [.date])
            .labelsHidden()
            .datePickerStyle(.field)
        case .dateTime:
            DatePicker("", selection: Binding(
                get: { dateValue ?? Date() },
                set: { v in write(.date(v)) }
            ))
            .labelsHidden()
            .datePickerStyle(.field)
        case .choice(let options):
            Picker("", selection: Binding(
                get: { value?.displayText ?? "" },
                set: { v in write(v.isEmpty ? nil : .text(v)) }
            )) {
                Text("（空）").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        case .multiChoice(let options):
            MultiChoiceMenu(options: options, current: displayText) { v in
                write(v.isEmpty ? nil : .text(v))
            }
        case .linkStudents:
            Button {
                showLinkPicker = true
            } label: {
                Text(displayText.isEmpty ? "选择学生" : displayText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(displayText.isEmpty ? Color.secondary.opacity(0.6) : .primary)
            }
            .buttonStyle(.plain)
        case .attachment:
            AttachmentCell(store: store, table: table, field: field, row: row)
        }
    }

    private var displayText: String {
        guard let value else { return "" }
        if case .link(let ids) = value {
            let map = Dictionary(uniqueKeysWithValues: store.data.students.map { ($0.id, $0.name) })
            return ids.map { map[$0] ?? "（未知学生）" }.joined(separator: "、")
        }
        return value.displayText
    }

    private var dateValue: Date? {
        if case .date(let d)? = value { return d }
        return nil
    }

    private func write(_ newValue: CustomValue?) {
        var updated = row
        if let newValue {
            updated.values[field.id.uuidString] = newValue
        } else {
            updated.values.removeValue(forKey: field.id.uuidString)
        }
        store.updateRow(tableID: table.id, row: updated)
    }

    private func commitDraft() {
        let text = (textDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        textDraft = nil
        switch field.type {
        case .text, .address, .phone, .idCard:
            write(text.isEmpty ? nil : .text(text))
        case .number:
            if text.isEmpty { write(nil) }
            else if let n = Double(text) { write(.number(n)) }
            else { NSSound.beep() }
        default:
            break
        }
    }
}

// MARK: - 通用小组件

/// 多选菜单（顿号拼接）
struct MultiChoiceMenu: View {
    let options: [String]
    let current: String
    let onChange: (String) -> Void

    private var selected: Set<String> {
        Set(current.components(separatedBy: "、").filter { !$0.isEmpty })
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(action: {
                    var next = selected
                    if selected.contains(option) {
                        next.remove(option)
                    } else {
                        next.insert(option)
                    }
                    onChange(options.filter { next.contains($0) }.joined(separator: "、"))
                }) {
                    if selected.contains(option) {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.isEmpty ? "（空）" : current)
                    .lineLimit(1)
                    .foregroundStyle(current.isEmpty ? Color.secondary.opacity(0.6) : .primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}

/// 关联学生编辑器：重排序无关，点击弹出带搜索的勾选列表
struct StudentLinkEditor: View {
    @ObservedObject var store: ProjectStore
    @Binding var selected: [UUID]

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索学生姓名 / 学号…", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(students) { student in
                        Toggle(isOn: Binding(
                            get: { selected.contains(student.id) },
                            set: { on in
                                if on {
                                    if !selected.contains(student.id) { selected.append(student.id) }
                                } else {
                                    selected.removeAll { $0 == student.id }
                                }
                            }
                        )) {
                            HStack(spacing: 8) {
                                AvatarView(name: student.name, size: 22)
                                Text(student.name).font(.callout)
                                Text(student.studentNumber)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @State private var keyword = ""

    private var students: [Student] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return store.data.students }
        return store.data.students.filter {
            $0.name.localizedCaseInsensitiveContains(kw) ||
            $0.studentNumber.localizedCaseInsensitiveContains(kw)
        }
    }
}

/// 关联学生按钮（chip 展示 + 点击弹出选择器）——详情/行编辑用
struct StudentLinkButton: View {
    @ObservedObject var store: ProjectStore
    @Binding var selected: [UUID]
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 6) {
                if selected.isEmpty {
                    Text("选择学生")
                        .foregroundStyle(.secondary)
                } else {
                    let map = Dictionary(uniqueKeysWithValues: store.data.students.map { ($0.id, $0.name) })
                    Text(selected.map { map[$0] ?? "未知" }.joined(separator: "、"))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            StudentLinkEditor(store: store, selected: $selected)
                .frame(width: 280, height: 320)
        }
    }
}

/// 附件字段单元格（数量徽标 + 菜单）
struct AttachmentCell: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let field: CustomField
    let row: DBRow

    @State private var files: [URL] = []
    @State private var showPicker = false

    var body: some View {
        Menu {
            Button("添加文件…") { showPicker = true }
            if !files.isEmpty {
                Divider()
                ForEach(files, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        store.openAttachment(url)
                    }
                }
                Divider()
                Button("在访达中显示") {
                    if let dir = files.first?.deletingLastPathComponent() {
                        store.revealInFinder(dir)
                    }
                }
            }
        } label: {
            Label(files.isEmpty ? "＋" : "📎 \(files.count)",
                  systemImage: files.isEmpty ? "paperclip" : "paperclip.fill")
                .font(.callout)
                .foregroundStyle(files.isEmpty ? Color.secondary.opacity(0.7) : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onAppear(perform: reload)
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true,
                      onCompletion: { result in
            if let urls = try? result.get() {
                for url in urls {
                    try? store.importAttachment(at: url, tableID: table.id,
                                                rowID: row.id, fieldID: field.id)
                }
                reload()
            }
        })
    }

    private func reload() {
        files = store.attachmentFileURLs(tableID: table.id, rowID: row.id, fieldID: field.id)
    }
}

// MARK: - 通用列筛选 sheet

struct GenericColumnFilterSheet: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let field: CustomField
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var values: [String] = []
    @State private var includeEmpty = true
    @State private var checked: Set<String> = []
    @State private var loaded = false
    /// onAppear 恢复已有筛选时不触发 apply（避免打开瞬间就写数据引发全表重载）
    @State private var restoring = false

    private var currentView: ListView { table.currentView }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("筛选「\(field.name)」")
                .font(.headline)
            TextField("包含文字（不限）", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: searchText) { _ in
                    guard !restoring else { return }
                    apply()
                }

            HStack {
                Text("值")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("全选") { checked = Set(values.filter { !$0.isEmpty }); if includeEmpty { checked.insert("") }; apply() }
                Button("全不选") { checked = []; apply() }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(values, id: \.self) { value in
                        if value.isEmpty {
                            Toggle("（空）", isOn: Binding(
                                get: { includeEmpty },
                                set: { includeEmpty = $0; apply() }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.callout)
                        } else {
                            Toggle(isOn: Binding(
                                get: { checked.contains(value) },
                                set: { on in
                                    if on { checked.insert(value) } else { checked.remove(value) }
                                    apply()
                                }
                            )) {
                                Text(value).font(.callout).lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))

            HStack {
                Button("清除该列筛选") {
                    mutateView { v in
                        v.columnFilters.removeValue(forKey: field.id.uuidString)
                    }
                    checked = Set(values.filter { !$0.isEmpty })
                    if includeEmpty { checked.insert("") }
                    searchText = ""
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            restoring = true
            DispatchQueue.main.async { restoring = false }
            let map = Dictionary(uniqueKeysWithValues: store.data.students.map { ($0.id, $0.name) })
            values = TableQuery.distinctValues(field: field, in: table.rows) { map[$0] ?? "（未知学生）" }
            if let filter = currentView.columnFilters[field.id.uuidString] {
                searchText = filter.searchText
                checked = filter.selectedValues ?? Set(values)
                includeEmpty = filter.selectedValues.map { $0.contains("") } ?? true
            } else {
                checked = Set(values)
                includeEmpty = true
            }
        }
    }

    private func apply() {
        var filter = ColumnFilter()
        filter.searchText = searchText.trimmingCharacters(in: .whitespaces)
        var selected = checked
        if includeEmpty { selected.insert("") }
        // 「全选」= 非空值全部勾选且「（空）」也勾选；只差「（空）」未勾时也要生成白名单（用于筛掉空值行）
        let allNonEmpty = Set(values.filter { !$0.isEmpty }).isSubset(of: selected)
        if values.isEmpty || (allNonEmpty && includeEmpty) {
            filter.selectedValues = nil
        } else {
            filter.selectedValues = selected
        }
        mutateView { v in
            if filter.isActive {
                v.columnFilters[field.id.uuidString] = filter
            } else {
                v.columnFilters.removeValue(forKey: field.id.uuidString)
            }
        }
    }

    private func mutateView(_ mutate: (inout ListView) -> Void) {
        var t = table
        guard var v = t.view(id: currentView.id) else { return }
        mutate(&v)
        guard let idx = t.views.firstIndex(where: { $0.id == v.id }) else { return }
        t.views[idx] = v
        t.currentViewID = v.id
        store.updateTable(t)
    }
}

// MARK: - 行编辑器（新增 / 编辑行）

/// 按字段动态渲染的行编辑表单（Notion 式）
struct RowEditorSheet: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let editingRowID: UUID?
    /// 新增时预关联的学生（从学生详情创建记录时预填）
    var initialStudentIDs: [UUID] = []
    let onSaved: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftValues: [String: String] = [:]
    @State private var draftDates: [String: Date] = [:]
    @State private var draftBools: [String: Bool] = [:]
    @State private var savedLinks: [String: [UUID]] = [:]
    @State private var loaded = false

    private var title: String {
        editingRowID == nil ? "新增行 — \(table.name)" : "编辑行 — \(table.name)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(table.orderedFields) { field in
                        editorRow(field)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .onAppear(perform: loadDrafts)
    }

    private func loadDrafts() {
        guard !loaded else { return }
        loaded = true
        // 新增模式：预关联学生
        if editingRowID == nil, !initialStudentIDs.isEmpty,
           let linkField = table.linkField {
            savedLinks[linkField.id.uuidString] = initialStudentIDs
        }
        guard let rowID = editingRowID, let row = table.row(id: rowID) else { return }
        for field in table.fields {
            let key = field.id.uuidString
            let value = row.values[key]
            switch field.type {
            case .text, .address, .number, .choice, .multiChoice, .phone, .idCard:
                let text = value?.displayText ?? ""
                if field.type == .number || !text.isEmpty {
                    draftValues[key] = field.type == .number ? numberDraft(value) : text
                }
            case .boolean:
                draftBools[key] = value?.displayText == "是"
            case .date, .dateTime:
                if case .date(let d)? = value { draftDates[key] = d }
            case .linkStudents:
                if let ids = value?.linkedStudentIDs { savedLinks[key] = ids }
            case .attachment:
                break
            }
        }
    }

    private func numberDraft(_ value: CustomValue?) -> String {
        if case .number(let n)? = value {
            return n == n.rounded() ? String(Int(n)) : String(n)
        }
        return ""
    }

    @ViewBuilder
    private func editorRow(_ field: CustomField) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(field.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            fieldControl(field)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func fieldControl(_ field: CustomField) -> some View {
        let key = field.id.uuidString
        switch field.type {
        case .text, .address:
            TextField("未填写", text: Binding(get: { draftValues[key] ?? "" }, set: { draftValues[key] = $0 }))
                .textFieldStyle(.roundedBorder)
        case .phone, .idCard:
            // 电话/身份证：非法值红色 + 警告图标（悬停说明规则）
            TextField("未填写", text: Binding(get: { draftValues[key] ?? "" }, set: { draftValues[key] = $0 }))
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    let raw = draftValues[key] ?? ""
                    let invalid = !raw.isEmpty && (field.type == .phone
                        ? !FieldFormat.isValidPhone(raw)
                        : !FieldFormat.isValidIDCard(raw))
                    if invalid {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(.trailing, 6)
                            .help(field.type == .phone
                                  ? "电话格式不正确（7-15 位数字，可带 +86/-/空格）"
                                  : "身份证号应为 18 位（含校验码，末位可为 X）或 15 位")
                    }
                }
        case .number:
            TextField("未填写", text: Binding(get: { draftValues[key] ?? "" }, set: { draftValues[key] = $0 }))
                .textFieldStyle(.roundedBorder)
        case .boolean:
            Toggle("", isOn: Binding(
                get: { draftBools[key] ?? false },
                set: { draftBools[key] = $0 }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        case .date:
            DatePicker("", selection: Binding(
                get: { draftDates[key] ?? Date() },
                set: { draftDates[key] = $0 }
            ), displayedComponents: [.date])
            .labelsHidden()
        case .dateTime:
            DatePicker("", selection: Binding(
                get: { draftDates[key] ?? Date() },
                set: { draftDates[key] = $0 }
            ))
            .labelsHidden()
        case .choice(let options):
            Picker("", selection: Binding(
                get: { draftValues[key] ?? "" },
                set: { draftValues[key] = $0 }
            )) {
                Text("（空）").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case .multiChoice(let options):
            MultiChoiceMenu(options: options, current: draftValues[key] ?? "") {
                draftValues[key] = $0
            }
        case .linkStudents:
            StudentLinkButton(store: store, selected: Binding(
                get: { savedLinks[key] ?? [] },
                set: { savedLinks[key] = $0 }
            ))
            .labelsHidden()
        case .attachment:
            Text("保存后可在行详情中添加")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func save() {
        var values: [String: CustomValue] = [:]
        for field in table.fields {
            let key = field.id.uuidString
            switch field.type {
            case .text, .address, .choice, .multiChoice, .phone, .idCard:
                let text = (draftValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { values[key] = .text(text) }
            case .number:
                let text = (draftValues[key] ?? "").trimmingCharacters(in: .whitespaces)
                if let n = Double(text) { values[key] = .number(n) }
            case .boolean:
                if let b = draftBools[key] { values[key] = .boolean(b) }
            case .date, .dateTime:
                if let d = draftDates[key] { values[key] = .date(d) }
            case .linkStudents:
                if let ids = savedLinks[key], !ids.isEmpty { values[key] = .link(ids) }
            case .attachment:
                break
            }
        }

        switch editingRowID {
        case nil:
            let newRow = store.addRow(tableID: table.id, values: values)
            onSaved(newRow?.id)
        case let rowID?:
            if var updated = table.row(id: rowID) {
                for field in table.fields {
                    let key = field.id.uuidString
                    if let v = values[key] {
                        updated.values[key] = v
                    } else {
                        updated.values.removeValue(forKey: key)
                    }
                }
                store.updateRow(tableID: table.id, row: updated)
            }
            onSaved(nil)
        }
        dismiss()
    }

}

// MARK: - 行详情（Notion 式）

/// 行详情页：字段逐行就地编辑 + 关联学生（可跳转）+ 行级附件区（存项目包内）
struct RowDetailView: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let rowID: UUID

    @State private var textDrafts: [String: String] = [:]
    @State private var dateDrafts: [String: Date] = [:]
    @State private var boolDrafts: [String: Bool] = [:]
    @State private var loadedTexts: [String: Bool] = [:]
    @State private var files: [URL] = []
    @State private var showPicker = false

    private var row: DBRow? { table.row(id: rowID) }

    var body: some View {
        Group {
            if let row {
                content(row)
            } else {
                ContentUnavailableView("该行已被删除", systemImage: "trash")
            }
        }
    }

    private func content(_ row: DBRow) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                header(row)

                ForEach(table.orderedFields) { field in
                    VStack(spacing: 4) {
                        Label(field.name, systemImage: field.type.systemImage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        editorField(field, row: row)
                    }
                }

                if let linkField = table.linkField {
                    relatedStudents(row, linkField: linkField)
                }

                AttachmentSection(store: store, table: table, rowID: rowID) {
                    files = store.attachmentFileURLs(tableID: table.id, rowID: rowID)
                }
            }
            .padding(20)
        }
        .onAppear {
            refreshFiles()
            syncDrafts(row)
        }
    }

    private func refreshFiles() {
        files = store.attachmentFileURLs(tableID: table.id, rowID: rowID)
    }

    private func syncDrafts(_ row: DBRow) {
        for field in table.fields {
            let key = field.id.uuidString
            guard loadedTexts[key] != true else { continue }
            switch field.type {
            case .text, .address, .number, .choice, .multiChoice, .phone, .idCard:
                textDrafts[key] = row.values[key]?.displayText ?? ""
            case .boolean:
                boolDrafts[key] = row.values[key]?.displayText == "是"
            case .date, .dateTime:
                if case .date(let d)? = row.values[key] { dateDrafts[key] = d }
            case .linkStudents, .attachment:
                break
            }
            loadedTexts[key] = true
        }
    }

    private func header(_ row: DBRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: table.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(table.name)
                    .font(.title3.weight(.semibold))
                Text("行创建于 \(Fmt.dateTime.string(from: row.createdAt)) · 最近修改 \(Fmt.dateTime.string(from: row.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(role: .destructive) {
                store.deleteRows(tableID: table.id, ids: Set([row.id]))
            } label: {
                Text("删除行")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func editorField(_ field: CustomField, row: DBRow) -> some View {
        let key = field.id.uuidString
        HStack(alignment: .firstTextBaseline) {
            fieldControl(field, key: key, row: row)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
    }

    @ViewBuilder
    private func fieldControl(_ field: CustomField, key: String, row: DBRow) -> some View {
        switch field.type {
        case .text, .address, .phone, .idCard:
            TextField("未填写", text: Binding(
                get: { textDrafts[key] ?? "" },
                set: {
                    textDrafts[key] = $0
                    commit(field: field)
                }
            ))
            .textFieldStyle(.plain)
            .lineLimit(field.type == .address ? 4 : 1)
        case .number:
            TextField("未填写", text: Binding(
                get: { textDrafts[key] ?? "" },
                set: {
                    textDrafts[key] = $0
                    commitNumber(field)
                }
            ), onCommit: { commitNumber(field) })
            .textFieldStyle(.plain)
        case .boolean:
            Toggle("", isOn: Binding(
                get: { boolDrafts[key] ?? false },
                set: {
                    boolDrafts[key] = $0
                    write(key: key, value: .boolean($0))
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        case .date:
            DatePicker("", selection: Binding(
                get: { dateDrafts[key] ?? Date() },
                set: {
                    dateDrafts[key] = $0
                    write(key: key, value: .date($0))
                }
            ), displayedComponents: [.date])
            .labelsHidden()
        case .dateTime:
            DatePicker("", selection: Binding(
                get: { dateDrafts[key] ?? Date() },
                set: {
                    dateDrafts[key] = $0
                    write(key: key, value: .date($0))
                }
            ))
            .labelsHidden()
        case .choice(let options):
            Picker("", selection: Binding(
                get: { textDrafts[key] ?? "" },
                set: {
                    textDrafts[key] = $0
                    write(key: key, value: $0.isEmpty ? nil : .text($0))
                }
            )) {
                Text("（空）").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case .multiChoice(let options):
            MultiChoiceMenu(options: options, current: row.values[key]?.displayText ?? "") { text in
                textDrafts[key] = text
                write(key: key, value: text.isEmpty ? nil : .text(text))
            }
        case .linkStudents:
            StudentLinkButton(store: store, selected: Binding(
                get: { row.values[key]?.linkedStudentIDs ?? [] },
                set: { ids in
                    write(key: key, value: ids.isEmpty ? nil : .link(ids))
                }
            ))
            .labelsHidden()
        case .attachment:
            AttachmentCell(store: store, table: table, field: field, row: row)
        }
    }

    /// 关联学生区：chips + 跳转学生详情
    @ViewBuilder
    private func relatedStudents(_ row: DBRow, linkField: CustomField) -> some View {
        let ids = row.values[linkField.id.uuidString]?.linkedStudentIDs ?? []
        let students = ids.compactMap { id in store.data.students.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 8) {
            Text("关联学生（点击跳转）")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if students.isEmpty {
                Text("未关联学生")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    ForEach(students) { student in
                        Button {
                            store.switchTable(id: nil)
                            NotificationCenter.default.post(name: .jumpToStudent, object: student.id)
                        } label: {
                            HStack(spacing: 6) {
                                AvatarView(name: student.name, size: 22)
                                Text(student.name).font(.callout)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commit(field: CustomField) {
        let key = field.id.uuidString
        let raw = (textDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.type {
        case .text, .address, .phone, .idCard:
            write(key: key, value: raw.isEmpty ? nil : .text(raw))
        case .number:
            if raw.isEmpty { write(key: key, value: nil) }
            else if let n = Double(raw) { write(key: key, value: .number(n)) }
        default:
            break
        }
    }

    private func commitNumber(_ field: CustomField) {
        commit(field: field)
    }

    private func write(key: String, value: CustomValue?) {
        guard var updated = table.row(id: rowID) else { return }
        if let value {
            updated.values[key] = value
        } else {
            updated.values.removeValue(forKey: key)
        }
        store.updateRow(tableID: table.id, row: updated)
        refreshFiles()
    }
}

/// 行级附件区（拖入 / 添加 / 打开 / 删除；存项目包内）
struct AttachmentSection: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let rowID: UUID
    var reload: () -> Void

    @State private var files: [URL] = []
    @State private var showPicker = false

    private var row: DBRow? { table.row(id: rowID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("附件（随项目文件一起保存）")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showPicker = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            if let row {
                attachmentList(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true,
                      onCompletion: { result in
            if let urls = try? result.get() {
                for url in urls {
                    try? store.importAttachment(at: url, tableID: table.id, rowID: rowID)
                }
                reload()
            }
        })
    }

    @ViewBuilder
    private func attachmentList(_ row: DBRow) -> some View {
        if files.isEmpty {
            Text("还没有附件。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(files, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Menu {
                        Button("打开") { store.openAttachment(url) }
                        Button("在访达中显示") { store.revealInFinder(url) }
                        Divider()
                        Button("删除", role: .destructive) {
                            store.deleteAttachment(url)
                            reload()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                }
                .contentShape(Rectangle())
                .onTapGesture { store.openAttachment(url) }
            }
        }
    }
}

extension Notification.Name {
    static let jumpToStudent = Notification.Name("jumpToStudent")
    static let jumpToRow = Notification.Name("jumpToRow")
}

// MARK: - 新建表

/// 新建自定义表：表名 + 类型 + 若干初始字段
struct NewTableSheet: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    /// 模板：记录类表提供预设字段，自定义表完全手工
    enum Template: String, CaseIterable, Identifiable {
        case blankCustom = "自定义表"
        case qingjia = "请假记录"
        case xueqing = "学情周报"
        case yibiao = "一表多清摸排"
        case observation = "平时观察"
        case medication = "精神药品服用"
        case campusConflict = "校园矛盾排查"
        case suspendFollowup = "休学电话随访"
        case focusFollowup = "重点电话随访"
        case focusHomeVisit = "重点家访记录"
        case focusTalk = "重点谈心谈话"
        case blankRecord = "空白记录表"

        var id: String { rawValue }

        var kind: TableKind {
            switch self {
            case .blankCustom: return .custom
            case .qingjia, .xueqing, .yibiao, .observation, .medication, .campusConflict,
                 .suspendFollowup, .focusFollowup, .focusHomeVisit, .focusTalk, .blankRecord:
                return .record
            }
        }

        var defaultName: String {
            switch self {
            case .blankCustom: return ""
            case .qingjia: return "请假记录"
            case .xueqing: return "学情周报"
            case .yibiao: return "一表多清摸排"
            case .observation: return "平时观察"
            case .medication: return "精神药品服用"
            case .campusConflict: return "校园矛盾排查"
            case .suspendFollowup: return "休学学生电话随访"
            case .focusFollowup: return "重点学生电话随访"
            case .focusHomeVisit: return "重点学生家访"
            case .focusTalk: return "重点学生谈心谈话"
            case .blankRecord: return "新记录表"
            }
        }
    }

    @State private var name = ""
    @State private var selectedTemplate: Template = .blankCustom
    @State private var fields: [(name: String, type: FieldType)] = [("名称", .text)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新建数据表")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模板").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    // 网格卡片：模板多也能完整显示（替代会溢出的分段控件）
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Template.allCases) { template in
                            Button {
                                selectedTemplate = template
                            } label: {
                                Text(template.rawValue)
                                    .font(.callout.weight(selectedTemplate == template ? .semibold : .regular))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(selectedTemplate == template
                                                ? Color.accentColor.opacity(0.16)
                                                : Color(nsColor: .controlBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                                        selectedTemplate == template
                                            ? Color.accentColor.opacity(0.6)
                                            : Color(nsColor: .separatorColor).opacity(0.7)))
                                    .foregroundStyle(selectedTemplate == template ? Color.accentColor : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onChange(of: selectedTemplate) { newValue in
                        applyTemplate(newValue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("表名").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextField("如：成绩表", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("字段")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            fields.append(("", .text))
                        } label: {
                            Label("添加字段", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(fields.indices, id: \.self) { idx in
                                fieldRow(index: idx)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(18)

            Spacer()
        }
        .resizableSheet(minWidth: 460, minHeight: 400, idealWidth: 520, idealHeight: 470)
        .onAppear {
            // sheet 复用会残留 @State：每次打开强制按当前模板重置，杜绝"部分内容不显示"
            applyTemplate(selectedTemplate)
        }
    }

    @ViewBuilder
    private func fieldRow(index: Int) -> some View {
        HStack(spacing: 8) {
            TextField("字段名", text: Binding(
                get: { fields[index].name },
                set: { fields[index].name = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Picker("", selection: Binding(
                get: { fields[index].type },
                set: { fields[index].type = $0 }
            )) {
                ForEach(FieldType.selectableTypes, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
                Text("关联学生").tag(FieldType.linkStudents)
            }
            .labelsHidden()
            .frame(width: 130)

            Button(role: .destructive) {
                guard fields.count > 1 else { return }
                fields.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(fields.count <= 1)
        }
        .frame(maxWidth: .infinity)
    }

    private func applyTemplate(_ template: Template) {
        name = template.defaultName
        switch template {
        case .observation:
            fields = [("学生", .linkStudents),
                      ("日期", .date),
                      ("时间段", .choice(options: ["早自习", "第一节课", "第二节课", "第三节课", "第四节课",
                                            "午休", "第五节课", "第六节课", "第七节课", "第八节课",
                                            "晚自习", "放学后"])),
                      ("表现情况", .multiChoice(options: ["认真听讲", "积极发言", "遵守纪律", "乐于助人",
                                                   "睡觉", "吵闹", "玩手机", "与同学冲突", "顶撞老师"])),
                      ("违纪情况", .multiChoice(options: ["无", "迟到", "早退", "旷课", "上课讲话",
                                                   "玩手机", "打架", "顶撞老师", "逃课"])),
                      ("处理情况", .text),
                      ("备注", .address)]
        case .blankCustom:
            fields = [("名称", .text)]
        case .qingjia:
            fields = [("学生", .linkStudents),
                      ("请假类型", .choice(options: ["病假", "事假", "丧假", "其他"])),
                      ("开始日期", .date),
                      ("结束日期", .date),
                      ("请假天数", .number),
                      ("是否销假", .boolean),
                      ("备注", .text)]
        case .xueqing:
            fields = [("学生", .linkStudents),
                      ("周次", .number),
                      ("学业", .text),
                      ("情绪", .text),
                      ("人际关系", .text),
                      ("学生周记", .text),
                      ("行为", .text),
                      ("网络空间", .text),
                      ("亲子关系", .text),
                      ("其他观察", .text),
                      ("补充说明", .address),
                      ("家庭结构情况", .address),
                      ("家庭生活状况", .address),
                      ("特异体质", .address),
                      ("心理健康状况", .address),
                      ("分析人", .text),
                      ("填表日期", .date)]
        case .yibiao:
            fields = [("学生", .linkStudents),
                      ("孤儿或事实无人抚养", .boolean),
                      ("单亲（离异/重组/病故）", .boolean),
                      ("父母服刑", .boolean),
                      ("二胎及以上家庭", .boolean),
                      ("家庭关系紧张", .boolean),
                      ("先天性疾病/特殊体质", .boolean),
                      ("精神或心理问题", .boolean),
                      ("家族精神心理疾病史", .boolean),
                      ("内向敏感/人际紧张", .boolean),
                      ("转学生/复学生", .boolean),
                      ("家庭特困/父母在外打工", .boolean),
                      ("学习压力大/学习困难", .boolean),
                      ("违法/欺凌/网瘾/辍学等", .boolean),
                      ("后续关爱类别", .choice(options: ["日常关注", "年级关注", "重点关注"])),
                      ("备注", .address)]
        case .medication:
            // 精神药品服用情况调查
            fields = [("学生", .linkStudents),
                      ("调查日期", .date),
                      ("是否服用", .boolean),
                      ("是否按时服用", .boolean),
                      ("是否通知家长保管", .boolean),
                      ("备注", .address)]
        case .campusConflict:
            // 对照《校园矛盾风险点排查记录表》：风险类型多选打■、化解状态、责任链与签字附件
            fields = [("学生", .linkStudents),
                      ("风险类型", .multiChoice(options: ["心理问题", "家庭重大变故", "身体疾病",
                                                   "行为异常—自残自杀", "行为异常—伤人",
                                                   "行为异常—辍学旷课", "行为异常—其他",
                                                   "多次信访", "诉讼纠纷", "其他"])),
                      ("类别", .choice(options: ["学校", "教师", "学生", "家长", "员工及第三方服务"])),
                      ("姓名", .text),
                      ("身份证", .idCard),
                      ("联系电话", .phone),
                      ("矛盾发生时间", .dateTime),
                      ("风险点概述", .address),
                      ("产生原因", .address),
                      ("关心措施", .address),
                      ("化解状态", .choice(options: ["未化解", "平稳", "已化解"])),
                      ("责任部门", .text),
                      ("责任人", .text),
                      ("责任人手机", .phone),
                      ("责任人职务", .text),
                      ("上报人手机", .phone),
                      ("上报人职务", .text),
                      ("包案领导姓名", .text),
                      ("领导签字", .attachment),
                      ("附件材料", .attachment)]
        case .blankRecord:
            fields = [("学生", .linkStudents), ("日期", .date), ("内容", .address)]
        case .suspendFollowup:
            // 《休学学生家长电话随访记录（每周一次）》
            fields = [("学生", .linkStudents),
                      ("系部", .text), ("班号", .text), ("姓名", .text),
                      ("性别", .choice(options: ["男", "女"])),
                      ("家长姓名1", .text), ("家长手机1", .phone),
                      ("家长姓名2", .text), ("家长手机2", .phone),
                      ("日期", .date), ("电话随访内容", .address), ("电话效果", .text)]
        case .focusFollowup:
            // 《重点关注学生家长电话随访记录（每月一次，另加法定长假）》与休学版同构
            fields = [("学生", .linkStudents),
                      ("系部", .text), ("班号", .text), ("姓名", .text),
                      ("性别", .choice(options: ["男", "女"])),
                      ("家长姓名1", .text), ("家长手机1", .phone),
                      ("家长姓名2", .text), ("家长手机2", .phone),
                      ("日期", .date), ("电话随访内容", .address), ("电话效果", .text)]
        case .focusHomeVisit:
            // 《重点关注学生入户家访记录》：家访组、沟通内容、照片附件与后续举措
            fields = [("学生", .linkStudents),
                      ("学校名称", .text), ("姓名", .text), ("所在班级", .text),
                      ("班主任姓名", .text), ("心理辅导员", .text),
                      ("监护人姓名", .text), ("监护人联系方式", .text),
                      ("家访人1姓名", .text), ("家访人1职务", .text),
                      ("家访人2姓名", .text), ("家访人2职务", .text),
                      ("家访地址", .address), ("家访时间", .dateTime),
                      ("一生一案建档情况", .choice(options: ["已建档", "未建档"])),
                      ("家访沟通内容", .address),
                      ("家访照片", .attachment),
                      ("被访人反馈情况", .address), ("后续举措", .address)]
        case .focusTalk:
            // 《重点关注学生谈心谈话记录（每周一次）》
            fields = [("学生", .linkStudents),
                      ("系部", .text), ("班号", .text), ("姓名", .text),
                      ("性别", .choice(options: ["男", "女"])),
                      ("日期", .date), ("谈心谈话内容", .address), ("效果", .text)]
        }
    }

    private func create() {
        let visible = fields.compactMap { item -> CustomField? in
            let trimmed = item.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return CustomField(name: trimmed, type: item.type)
        }
        let finalName = name.trimmingCharacters(in: .whitespaces)
        let fallbackName = selectedTemplate.defaultName.isEmpty ? "新表" : selectedTemplate.defaultName
        store.addTable(name: finalName.isEmpty ? fallbackName : finalName,
                       kind: selectedTemplate.kind, fields: visible)
        dismiss()
    }
}

// MARK: - 表内字段管理

/// 记录表/自定义表的字段管理：内联改名、改类型、编辑选项、增删移动
struct TableFieldsSheet: View {
    @ObservedObject var store: ProjectStore
    let tableID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("字段管理").font(.headline)
                    if let created = store.data.table(id: tableID)?.createdAt {
                        Text("表创建于 \(Fmt.dateTime.string(from: created))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.data.table(id: tableID)?.fields ?? []) { field in
                        fieldRow(field)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            Divider()

            HStack {
                Button {
                    _ = store.addTableField(tableID: tableID, name: "新字段", type: .text)
                } label: {
                    Label("添加字段", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .resizableSheet(minWidth: 460, minHeight: 380, idealWidth: 520, idealHeight: 480)
    }

    @ViewBuilder
    private func fieldRow(_ field: CustomField) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("名称",
                          text: Binding(
                            get: { field.name },
                            set: { var f = field; f.name = $0; store.updateTableField(tableID: tableID, field: f) }
                          ))
                    .textFieldStyle(.roundedBorder)
                Text(field.createdAt.map { "创建于 \(Fmt.dateTime.string(from: $0))" } ?? "早期创建")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Picker("", selection: Binding(
                get: { field.type.id },
                set: { newKind in
                    guard newKind != field.type.id else { return }
                    let newType: FieldType
                    if let existing = FieldType.selectableTypes.first(where: { $0.id == newKind }) {
                        newType = existing
                    } else if newKind == "linkStudents" {
                        newType = .linkStudents
                    } else {
                        return
                    }
                    // 存量行值随类型转换（转换失败的清除、单选/多选并入选项）
                    store.changeTableFieldType(tableID: tableID, fieldID: field.id, to: newType)
                }
            )) {
                ForEach(FieldType.selectableTypes, id: \.self) { type in
                    Text(type.displayName).tag(type.id)
                }
                Text("关联学生").tag(FieldType.linkStudents.id)
            }
            .labelsHidden()
            .frame(width: 120)

            optionsEditor(field)

            Button {
                var order = store.data.table(id: tableID)?.fieldOrder ?? []
                if let i = order.firstIndex(of: field.id), i > 0 {
                    order.swapAt(i, i - 1)
                    var t = store.data.table(id: tableID) ?? DBTable(name: "")
                    t.fieldOrder = order
                    store.updateTable(t)
                }
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)

            Button {
                var order = store.data.table(id: tableID)?.fieldOrder ?? []
                if let i = order.firstIndex(of: field.id), i + 1 < order.count {
                    order.swapAt(i, i + 1)
                    var t = store.data.table(id: tableID) ?? DBTable(name: "")
                    t.fieldOrder = order
                    store.updateTable(t)
                }
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                store.deleteTableField(tableID: tableID, fieldID: field.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    /// 单选/多选选项编辑（顿号分隔、即时保存）
    @ViewBuilder
    private func optionsEditor(_ field: CustomField) -> some View {
        if case .choice(let options) = field.type {
            TextField("选项（顿号分隔）",
                      text: Binding(
                        get: { options.joined(separator: "、") },
                        set: { var f = field
                            f.type = .choice(options: $0.components(separatedBy: "、")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty })
                            store.updateTableField(tableID: tableID, field: f)
                        }
                      ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(width: 150)
        } else if case .multiChoice(let options) = field.type {
            TextField("选项（顿号分隔）",
                      text: Binding(
                        get: { options.joined(separator: "、") },
                        set: { var f = field
                            f.type = .multiChoice(options: $0.components(separatedBy: "、")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty })
                            store.updateTableField(tableID: tableID, field: f)
                        }
                      ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(width: 150)
        }
    }
}
