import SwiftUI

/// 主窗口：无项目 → 欢迎页；有项目 → 分栏界面；锁定 → 锁屏覆盖层
struct MainWindow: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ZStack {
            if let store = appModel.store {
                MainSplitView(store: store)
            } else {
                WelcomeView()
            }

            if appModel.isLocked {
                LockScreenView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appModel.isLocked)
        .alert(appModel.alert?.title ?? "提示",
               isPresented: Binding(
                   get: { appModel.alert != nil },
                   set: { if !$0 { appModel.alert = nil } }
               ),
               presenting: appModel.alert) { _ in
            Button("好", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

// MARK: - 分栏主界面

struct MainSplitView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var store: ProjectStore

    @State private var selectedStudentIDs: Set<UUID> = []
    @State private var showAddStudent = false
    @State private var showFieldManager = false
    @State private var showTypeManager = false
    @State private var importFile: ImportFile?
    @State private var showExportSelection = false
    @State private var pendingBatchDelete = false
    @State private var showSidebarBatchEdit = false
    /// 通用数据表的行选集（每表独立）
    @State private var tableRowSelection: Set<UUID> = []
    /// 学分管理独立面板（不占用 store.switchTable 状态机）
    @State private var showCreditPanel = false

    private var currentView: ListView {
        store.currentView
    }

    private var filteredStudents: [Student] {
        let base = StudentQuery.apply(
            view: currentView,
            students: store.data.students,
            fields: store.data.fieldDefinitions,
            builtinOrder: store.data.builtinOrder,
            deletedBuiltin: store.data.deletedBuiltinFields
        )
        // 叠加 Excel 式列筛选（表格列头的漏斗）
        return StudentQuery.applyColumnFilters(base, columns: tableColumns,
                                               filters: currentView.columnFilters)
    }

    /// 会话内是否处于筛选态（关键字 / 快捷筛选条件 / 列筛选任一生效）
    private var isFilterActive: Bool {
        !currentView.keyword.isEmpty || currentView.condition != .all || !currentView.columnFilters.isEmpty
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                view: currentView,
                selection: selectedStudentIDs,
                onSelectionChange: { ids in
                    selectedStudentIDs = ids
                },
                students: filteredStudents,
                onAddStudent: { showAddStudent = true },
                onManageFields: { showFieldManager = true },
                onManageTypes: { showTypeManager = true },
                onImport: { startImport() },
                onExport: { showExportSelection = true },
                onBatchDelete: {
                    pendingBatchDelete = true
                },
                isCreditPanelActive: showCreditPanel,
                onShowCredit: { showCreditPanel = true },
                onLeaveCredit: { showCreditPanel = false }
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .navigationTitle(store.projectName)
        .confirmationDialog(
            "删除选中的 \(selectedStudentIDs.count) 名学生？",
            isPresented: $pendingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedStudentIDs.count) 人", role: .destructive) {
                store.deleteStudents(ids: selectedStudentIDs)
                selectedStudentIDs.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(batchDeleteMessage)
        }
        .sheet(isPresented: $showAddStudent) {
            StudentFormSheet(store: store, mode: .add) { newStudent in
                if selectedStudentIDs.isEmpty {
                    selectedStudentIDs = [newStudent.id]
                }
            }
            .frame(width: 560)
        }
        .sheet(isPresented: $showFieldManager) {
            FieldsManagerSheet(store: store)
        }
        .sheet(isPresented: $showTypeManager) {
            RecordTypesSheet(store: store)
        }
        .sheet(item: $importFile) { file in
            ImportSheet(store: store, fileURL: file.url)
        }
        .sheet(isPresented: $showExportSelection) {
            ExportSelectionSheet(store: store)
        }
        .onChange(of: store.data.currentTableID) { _ in
            // 切表后两边的选集语义不同，分别清空
            tableRowSelection.removeAll()
            selectedStudentIDs.removeAll()
            showCreditPanel = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToStudent)) { note in
            // 从通用表行详情跳回学生
            guard let id = note.object as? UUID else { return }
            store.switchTable(id: nil)
            selectedStudentIDs = [id]
            showCreditPanel = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToRow)) { note in
            // 从学生详情记录 tab 跳到某表的某一行
            guard let info = note.object as? (idList: [AnyHashable], anchor: UUID),
                  let tableID = info.idList[0] as? UUID else { return }
            store.switchTable(id: tableID)
            tableRowSelection = [info.anchor]
            showCreditPanel = false
        }
        .onChange(of: appModel.importRequestToken) { _ in
            startImport()
        }
        .onChange(of: appModel.exportRequestToken) { _ in
            showExportSelection = true
        }
    }

    private func startImport() {
        guard appModel.store != nil else { return }
        if let url = appModel.promptImportFile() {
            importFile = ImportFile(url: url)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if showCreditPanel {
            // 学分管理独立面板（分支链最前，不侵入 store.switchTable 状态机）
            CreditPanelView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            dataArea
        }
    }

    /// 数据区（学分面板以外的原有内容）：顶部共用栏 + 表 / 学生视图分支
    private var dataArea: some View {
        VStack(spacing: 0) {
            // 数据区顶部共用栏：仅学生表激活时显示（通用表有自己的共用栏）
            if store.currentTable == nil {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        // 单视图语义：不再展示视图名（旧项目收敛保留的视图可能带有旧名字且无法重命名），
                        // 按是否处于筛选态显示固定标题
                        Text(isFilterActive ? "筛选结果" : "全部学生")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text("· \(filteredStudents.count) 名学生")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !currentView.columnFilters.isEmpty {
                        Button {
                            store.clearColumnFilters()
                        } label: {
                            Label("列筛选 \(currentView.columnFilters.count) 项",
                                  systemImage: "line.3.horizontal.decrease.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .help("表格列上已设置筛选，点击全部清除")
                    }
                    Spacer()
                    ViewLayoutSwitcher(layout: currentView.layout) { newValue in
                        var v = currentView
                        v.layout = newValue
                        store.updateView(v)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                Divider()
            }

            if let activeTable = store.currentTable {
                GenericTableArea(store: store, table: activeTable,
                                 selection: $tableRowSelection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentView.layout == .table {
                StudentTableView(store: store, students: filteredStudents,
                                 columns: tableColumns,
                                 guardianSlots: currentView.guardianColumnCount,
                                 selection: $selectedStudentIDs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedStudentIDs.count > 1 {
                sidebarMultiSelectionView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let studentID = selectedStudentIDs.first,
                      let student = store.data.students.first(where: { $0.id == studentID }) {
                StudentDetailView(store: store, student: student)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 空状态占满剩余空间，保证顶部共用栏固定在数据区顶部
                emptyDetailMessage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 显式铺满详情列并顶部对齐：否则内容会被居中，顶部出现大片空白
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }


    private var batchDeleteMessage: String {
        let names = store.data.students
            .filter { selectedStudentIDs.contains($0.id) }
            .prefix(5).map { $0.name }.joined(separator: "、")
        let extra = selectedStudentIDs.count > 5 ? " 等 \(selectedStudentIDs.count) 人" : ""
        return "将删除「\(names)」\(extra)的全部信息、记录和附件。此操作不可撤销（可从项目备份恢复）。"
    }

    /// 侧栏多选时右侧的批量操作视图
    private var sidebarMultiSelectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("已选 \(selectedStudentIDs.count) 名学生")
                .font(.title3.weight(.semibold))
            Text("在左侧列表 ⌘ 点选 / ⇧ 连选，可批量修改或删除；也可切换到表格模式操作。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    showSidebarBatchEdit = true
                } label: {
                    Label("批量修改…", systemImage: "square.and.pencil.on.square")
                }
                .controlSize(.large)

                Button(role: .destructive) {
                    pendingBatchDelete = true
                } label: {
                    Label("删除 \(selectedStudentIDs.count) 人…", systemImage: "trash")
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSidebarBatchEdit) {
            BatchEditSheet(store: store, studentIDs: selectedStudentIDs)
        }
    }

    private var tableColumns: [StudentColumnSpec] {
        StudentColumnSpec.columns(
            fields: store.data.orderedFields,
            hidden: currentView.hiddenColumnIDs,
            guardianSlots: currentView.guardianColumnCount,
            builtinOrder: store.data.builtinOrder,
            deletedBuiltin: store.data.deletedBuiltinFields,
            layout: store.data.columnLayout
        )
    }

    @ViewBuilder
    private var emptyDetailMessage: some View {
        if store.data.students.isEmpty {
            ContentUnavailableView(
                "还没有学生",
                systemImage: "person.2",
                description: Text("点击左上角的 + 添加第一位学生。")
            )
        } else if !selectedStudentIDs.isEmpty {
            ContentUnavailableView(
                "学生不在当前列表中",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("该学生被当前筛选条件隐藏，可清除筛选后查看。")
            )
        } else {
            ContentUnavailableView(
                "选择一位学生",
                systemImage: "person.crop.square.on.square.angled",
                description: Text("从左侧列表选择学生查看详情，或切换为表格方式查看全部。")
            )
        }
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @ObservedObject var store: ProjectStore
    /// 当前视图（筛选为会话内状态；排序/布局/列显隐随视图保存）
    let view: ListView
    /// 当前选中集合（用于外部清空时同步到侧栏）
    let selection: Set<UUID>
    var onSelectionChange: (Set<UUID>) -> Void = { _ in }
    let students: [Student]
    let onAddStudent: () -> Void
    let onManageFields: () -> Void
    let onManageTypes: () -> Void
    let onImport: () -> Void
    let onExport: () -> Void
    /// 侧栏右键删除选中（含多选）
    var onBatchDelete: () -> Void = { }
    /// 学分管理面板是否激活（表树「学分管理」行高亮用）
    var isCreditPanelActive: Bool = false
    /// 点击表树「学分管理」
    var onShowCredit: () -> Void = {}
    /// 点学生行 / 切到数据表时回到数据区（关掉学分面板）
    var onLeaveCredit: () -> Void = {}


    private var policeStations: [String] {
        StudentQuery.policeStations(in: store.data.students)
    }

    var body: some View {
        VStack(spacing: 0) {
            tableTree
                .padding(.horizontal, 12)
                .padding(.top, 10)
            if isStudentTableActive {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                quickFilterTabs
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // 侧栏支持 ⌘/⇧ 多选（与表格一致），多选后可批量删除。
                // 注意：.sidebar 样式的 List 不支持 Set 多选，必须用 .inset
                // 列表本体及其修饰符拆出，避免 body 类型检查超时
                sidebarList
            } else {
                genericHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            footer
        }
        // 监视器与窗口引用挂在侧栏最外层：无论当前是学生表还是数据表都始终生效
        .background(WindowAccessor { rowRegistry.window = $0 })
        .onAppear(perform: installClickMonitor)
        .onDisappear {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }
        .sheet(isPresented: $showBatchEdit) {
            BatchEditSheet(store: store, studentIDs: localSelection)
                .frame(width: 440)
        }
        .confirmationDialog(
            "删除选中的 \(localSelection.count) 名学生？",
            isPresented: $pendingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("删除 \(localSelection.count) 人", role: .destructive) {
                store.deleteStudents(ids: localSelection)
                localSelection.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            let names = store.data.students
                .filter { localSelection.contains($0.id) }
                .prefix(5).map { $0.name }.joined(separator: "、")
            let extra = localSelection.count > 5 ? " 等 \(localSelection.count) 人" : ""
            Text("将删除「\(names)」\(extra)的全部信息、记录和附件。此操作不可撤销（可从项目备份恢复）。")
        }
        .sheet(isPresented: $showQuickFilterManager) {
            QuickFilterManagerSheet(store: store)
                .frame(width: 470, height: 430)
        }
        .sheet(isPresented: $showNewTableSheet) {
            NewTableSheet(store: store)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    onAddStudent()
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加学生")

                Menu {
                    Button("导入学生（Excel / CSV）…", action: onImport)
                    Divider()
                    Button("管理自定义字段…", action: onManageFields)
                    Button("管理记录类型…", action: onManageTypes)
                    Divider()
                    Button("导出数据（选择内容）…", action: onExport)
                    Button("在访达中显示项目") {
                        if let url = store.projectURL {
                            store.revealInFinder(url)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("更多")
            }
        }
    }

    /// 列表本体（拆出以降低 body 复杂度）：多选点击由事件监视器统一处理
    private var sidebarList: some View {
            List(selection: $localSelection) {
                ForEach(students) { student in
                    sidebarRow(for: student)
                }
            }
            .listStyle(.inset)
            .overlay(alignment: .bottom) {
                batchBar
            }
            .animation(.easeOut(duration: 0.15), value: localSelection.count > 1)
            // 双向同步均带等值保护，避免乒乓刷新
            .onChange(of: localSelection) { newValue in
                if newValue != selection {
                    onSelectionChange(newValue)
                }
            }
            .onChange(of: selection) { newValue in
                if newValue != localSelection {
                    localSelection = newValue
                }
            }
            .overlay {
                if students.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: isViewFiltered
                              ? "line.3.horizontal.decrease.circle" : "person.2")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(isViewFiltered ? "没有匹配的学生" : "暂无学生")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
    }
    /// 批量操作条（悬浮于列表底部）：拆出以降低 sidebarList 复杂度
    @ViewBuilder
    private var batchBar: some View {
        if localSelection.count > 1 {
            HStack(spacing: 10) {
                Text("已选 \(localSelection.count) 人")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showBatchEdit = true
                } label: {
                    Text("批量修改")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.22), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    pendingBatchDelete = true
                } label: {
                    Text("删除")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.22), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .background(
                // 登记悬浮条区域（AppKit 窗口坐标）：点击交给条上的按钮
                WindowFrameReporter { rect, _ in
                    batchBarFrame = rect
                } onRemove: {
                    batchBarFrame = .zero
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 安装本地鼠标监视器：SwiftUI List 容器会拦截行内事件，
    /// 因此在事件分发前捕获，统一实现 单击/⌘/⇧/拖拽划选。
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            guard let hostWindow = rowRegistry.window,
                  event.window === hostWindow else { return event }
            // 关键：locationInWindow 与行登记的 .window 坐标同一坐标系
            // （此前误用 NSEvent.mouseLocation，与 SwiftUI .global 的 Y 轴方向相反，命中永远落空）
            let point = event.locationInWindow
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            switch event.type {
            case .leftMouseDown:
                // 悬浮批量条在上层，点击应交给条上的按钮
                if batchBarFrame != .zero, batchBarFrame.insetBy(dx: -4, dy: -4).contains(point) {
                    return event
                }
                // 表树行：⌘/⇧/普通 + 开启拖选
                if let hit = treeRegistry.hit(at: point) {
                    handleTreeClick(hit.key, tableID: hit.tableID, flags: flags)
                    treeDragActive = true
                    treeDragAnchorKey = hit.key
                    return nil
                }
                // 学生行
                if let id = rowRegistry.row(at: point) {
                    handleRowClick(id, flags: flags)
                    return nil
                }
                return event

            case .leftMouseDragged:
                guard treeDragActive else { return event }
                if let hit = treeRegistry.hit(at: point) {
                    selectTreeRange(from: treeDragAnchorKey, to: hit.key, additive: flags.contains(.command) || flags.contains(.shift))
                }
                return nil

            case .leftMouseUp:
                if treeDragActive {
                    treeDragActive = false
                    // 拖选结束后打开最后划到的那张表
                    if let last = treeRegistry.hit(at: point) {
                        activate(last.tableID)
                    }
                    return nil
                }
                return event

            default:
                return event
            }
        }
    }

    /// 表树点击：普通=单选并打开；⌘=切换；⇧=锚点范围
    private func handleTreeClick(_ rowKey: String, tableID: UUID?, flags: NSEvent.ModifierFlags) {
        let orderedKeys = ["students"] + store.data.tables.map { $0.id.uuidString }
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let resolved = SidebarSelection.resolveKeys(
            current: selectedTableKeys, anchor: treeAnchorKey, clicked: rowKey,
            orderedKeys: orderedKeys, command: command, shift: shift)
        selectedTableKeys = resolved.selection
        treeAnchorKey = resolved.anchor
        // 单击（无 ⌘/⇧）直接打开该表；多选时只做选择
        if !command && !shift {
            activate(tableID)
        }
        if command || shift {
            // ⌘/⇧ 点时以最后点击行作为主表打开
            activate(tableID)
        }
    }

    /// 拖拽划选：从锚点行到当前行整段选中（⌘/⇧ 时为累加）
    private func selectTreeRange(from anchorKey: String?, to key: String, additive: Bool) {
        let orderedKeys = ["students"] + store.data.tables.map { $0.id.uuidString }
        selectedTableKeys = SidebarSelection.resolveDragRange(
            anchor: anchorKey, to: key, orderedKeys: orderedKeys,
            additive: additive, current: selectedTableKeys)
    }

    /// 处理侧栏行点击：普通=单选；⌘=切换；⇧=从锚点范围选择（Finder 语义）
    private func handleRowClick(_ studentID: UUID, flags: NSEvent.ModifierFlags) {
        // 点学生行回到数据区（关掉学分面板）
        onLeaveCredit()
        let (selection, anchor) = SidebarSelection.resolve(
            current: localSelection,
            anchor: selectionAnchor,
            clicked: studentID,
            orderedIDs: students.map(\.id),
            command: flags.contains(.command),
            shift: flags.contains(.shift)
        )
        localSelection = selection
        selectionAnchor = anchor
    }

    private func sidebarRow(for student: Student) -> some View {
        let isMultiSelected = localSelection.contains(student.id) && localSelection.count > 1
        return StudentRow(student: student)
            .tag(student.id)
            .background(
                // 登记每行坐标（AppKit 窗口坐标）
                WindowFrameReporter { rect, window in
                    if let window { rowRegistry.window = window }
                    rowRegistry.set(student.id, rect)
                } onRemove: {
                    rowRegistry.remove(student.id)
                }
            )
            .contextMenu {
                if isMultiSelected {
                    Button("删除选中的 \(localSelection.count) 名学生…", role: .destructive) {
                        store.deleteStudents(ids: localSelection)
                        localSelection.removeAll()
                    }
                } else {
                    Button("删除「\(student.name)」…", role: .destructive) {
                        localSelection = [student.id]
                        store.deleteStudents(ids: localSelection)
                        localSelection.removeAll()
                    }
                }
            }
    }

    private var isViewFiltered: Bool {
        view.condition != .all || !view.keyword.isEmpty
    }

    /// 本地多选状态（父视图刷新不会重置它）
    @State private var localSelection: Set<UUID> = []
    /// ⇧ 范围选择的起点（上次普通/⌘点击的行）
    @State private var selectionAnchor: UUID?
    /// 行坐标登记表 + 本地点击监视器（List 容器会拦截行内覆盖层的事件，
    /// 因此在事件分发前用监视器捕获点击并读取修饰键，统一计算选择）
    @State private var rowRegistry = SidebarRowRegistry()
    @State private var clickMonitor: Any?
    @State private var batchBarFrame: NSRect = .zero
    /// 侧栏表树的多选（"students" 代表学生表）与拖选会话
    @State private var selectedTableKeys: Set<String> = ["students"]
    @State private var treeAnchorKey: String?
    @State private var treeRegistry = TreeRowRegistry()
    @State private var treeDragActive = false
    @State private var treeDragAnchorKey: String?
    @State private var showBatchEdit = false
    @State private var pendingBatchDelete = false

    @State private var showQuickFilterManager = false

    /// 当前显示的是不是学生表
    var isStudentTableActive: Bool {
        store.data.currentTableID == nil || store.currentTable == nil
    }

    // MARK: Notion 式表导航树（学生 + 各数据表）

    private var tableTree: some View {
        VStack(spacing: 2) {
            // 外部切表（如行详情跳转）时同步高亮
            Color.clear.frame(height: 0)
                .onChange(of: store.data.currentTableID) { newID in
                    let rowKey = newID?.uuidString ?? "students"
                    if !selectedTableKeys.contains(rowKey) {
                        selectedTableKeys = [rowKey]
                        treeAnchorKey = rowKey
                    }
                }
            // 学生表（固定第一项）
            treeRow(icon: "square.grid.2x2",
                    name: "学生",
                    count: store.data.students.count,
                    tableID: nil)
            if isStudentTableActive {
                quickFiltersInTree
                    .padding(.leading, 24)
            }
            // 学分管理（固定第二项：独立面板，不参与表多选/删除）
            creditTreeRow
            ForEach(store.data.tables) { table in
                treeRow(icon: table.systemImage,
                        name: table.name,
                        count: table.rows.count,
                        tableID: table.id,
                        onDelete: {
                            store.deleteTable(id: table.id)
                        })
            }
            Button {
                showNewTableSheet = true
            } label: {
                Label("新建表", systemImage: "plus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.top, 2)
        }
    }

    /// 表树里学生行下方的快捷筛选标签（原视图切换位置，多视图移除后只保留筛选标签）
    private var quickFiltersInTree: some View {
        VStack(spacing: 4) {
            quickFilterTabs.padding(.top, 2).padding(.bottom, 0)
        }
    }

    /// 表树的「学分管理」固定行：独立面板入口。
    /// 不登记进 treeRegistry（不参与 ⌘/⇧ 表多选），点击交给 SwiftUI 按钮本体。
    private var creditTreeRow: some View {
        let rowKey = "credit"
        let isSelected = selectedTableKeys.contains(rowKey)
        let isActive = isCreditPanelActive
        return Button {
            selectedTableKeys = [rowKey]
            treeAnchorKey = rowKey
            onShowCredit()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "star.circle")
                    .font(.callout)
                    .foregroundStyle(isSelected || isActive ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text("学分管理")
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.85))
                Spacer()
                Text("\(store.data.creditRecords.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected
                        ? Color.accentColor.opacity(0.18)
                        : (isActive ? Color.accentColor.opacity(0.08) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("加减学分、比赛获奖与违纪扣分（按学期记录）")
    }

    private var genericHint: some View {
        Text("该数据表的列选择、排序、筛选都在表格里；点击行可进详情。")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .multilineTextAlignment(.center)
    }

    /// 侧栏表行的稳定标识（"students" 或表 UUID）
    private func key(for tableID: UUID?) -> String {
        tableID?.uuidString ?? "students"
    }

    /// Notion 式表行：图标 + 名称 + 行数；支持 ⌘/⇧/拖拽划选多选与右键批量删除
    private func treeRow(icon: String, name: String, count: Int, tableID: UUID?,
                         onDelete: (() -> Void)? = nil) -> some View {
        let rowKey = key(for: tableID)
        let isSelected = selectedTableKeys.contains(rowKey)
        let isActive = isStudentTableActive ? tableID == nil : store.data.currentTableID == tableID
        return Button {
            // 单击：选中该行（清掉其它选择）并切换到该表
            selectedTableKeys = [rowKey]
            treeAnchorKey = rowKey
            activate(tableID)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(isSelected || isActive ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(name)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.85))
                Spacer()
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected
                        ? Color.accentColor.opacity(0.18)
                        : (isActive ? Color.accentColor.opacity(0.08) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // 登记行坐标（AppKit 窗口坐标，与 locationInWindow 同系）：供监视器命中判断
            WindowFrameReporter { rect, window in
                if let window { rowRegistry.window = window }
                treeRegistry.set(rowKey, rect, tableID: tableID)
            } onRemove: {
                treeRegistry.remove(rowKey)
            }
        )
        .contextMenu {
            if selectedTableKeys.count > 1, selectedTableKeys.contains(rowKey) {
                // "students" 与 "credit"（学分管理固定项）不是数据表，不参与删除
                let deletable = selectedTableKeys.filter { $0 != "students" && $0 != "credit" }
                if !deletable.isEmpty {
                    Button("删除选中的 \(deletable.count) 张表…", role: .destructive) {
                        for idString in deletable {
                            if let id = UUID(uuidString: idString) {
                                store.deleteTable(id: id)
                            }
                        }
                        selectedTableKeys = ["students"]
                    }
                }
                Button("取消多选") { selectedTableKeys = ["students"] }
            } else if let onDelete {
                Button("删除此表…", role: .destructive) { onDelete() }
            } else {
                Button("学生表不可删除") {}.disabled(true)
            }
        }
    }

    private func activate(_ tableID: UUID?) {
        // 从学分面板切回数据区（点任意表树行都离开面板）
        onLeaveCredit()
        if tableID == nil {
            if store.data.currentTableID != nil { store.switchTable(id: nil) }
        } else if store.data.currentTableID != tableID {
            store.switchTable(id: tableID)
        }
    }

    @State private var showNewTableSheet = false

    // MARK: 快捷筛选标签（全部 + 自定义，可增删）

    private var quickFilterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabChip(title: "全部", isActive: view.condition == .all) {
                    updateView { $0.condition = .all }
                }

                ForEach(store.data.quickFilters) { filter in
                    tabChip(title: filter.name, isActive: view.condition == filter.condition) {
                        updateView { $0.condition = filter.condition }
                    }
                    .contextMenu {
                        Button("删除「\(filter.name)」…", role: .destructive) {
                            store.deleteQuickFilter(id: filter.id)
                        }
                    }
                }

                Button {
                    showQuickFilterManager = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("添加或管理快捷筛选")
            }
            .padding(.horizontal, 2)
        }
    }

    private func tabChip(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor),
                            in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.6)
                    )
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    // MARK: 搜索框（会话内关键字筛选）

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("筛选姓名、学号、家长、派出所…", text: keywordBinding)
                .textFieldStyle(.plain)
            if !view.keyword.isEmpty {
                Button {
                    updateView { $0.keyword = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        )
    }

    private var keywordBinding: Binding<String> {
        Binding(
            get: { view.keyword },
            set: { newValue in updateView { $0.keyword = newValue } }
        )
    }

    private func updateView(_ mutate: (inout ListView) -> Void) {
        var v = view
        mutate(&v)
        store.updateView(v)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            HStack {
                let boarding = store.data.students.filter { $0.isBoarding }.count
                Text("共 \(store.data.students.count) 名学生 · 住宿 \(boarding) 人")
                Spacer()
                if let saved = store.lastSavedAt {
                    Text("已保存 \(Fmt.dateTime.string(from: saved))")
                        .foregroundStyle(.tertiary)
                } else {
                    Text("未修改")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StudentRow: View {
    let student: Student

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: student.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(student.name.isEmpty ? "（未命名）" : student.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(student.studentNumber.isEmpty ? "未填学号" : "学号 \(student.studentNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            BoardingBadge(isBoarding: student.isBoarding)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 侧栏选择逻辑（纯函数，便于单元测试）
//
// SwiftUI List 的 Set 多选原生不支持 ⇧ 范围扩展（会被当成普通点击替换选择），
// 因此点击统一由 ModifierClickDetector 捕获后在此计算：
// 普通点击=单选；⌘=切换选中；⇧=从锚点（上次普通/⌘点击行）到当前行范围选择，锚点保持不变。

enum SidebarSelection {
    /// 字符串键版（侧栏表树）：普通=单选；⌘=切换；⇧=锚点范围
    static func resolveKeys(current: Set<String>, anchor: String?, clicked: String,
                            orderedKeys: [String], command: Bool, shift: Bool) -> (selection: Set<String>, anchor: String) {
        if shift, let anchor,
           let a = orderedKeys.firstIndex(of: anchor),
           let b = orderedKeys.firstIndex(of: clicked) {
            let range = a <= b ? a...b : b...a
            return (Set(orderedKeys[range]), anchor)
        }
        if command {
            var next = current
            if next.contains(clicked) { next.remove(clicked) } else { next.insert(clicked) }
            return (next, clicked)
        }
        return ([clicked], clicked)
    }

    /// 拖拽划选（从锚点到当前行整段；additive 时并入现有选择）
    static func resolveDragRange(anchor: String?, to key: String,
                                 orderedKeys: [String], additive: Bool,
                                 current: Set<String>) -> Set<String> {
        guard let anchor,
              let a = orderedKeys.firstIndex(of: anchor),
              let b = orderedKeys.firstIndex(of: key) else { return current }
        let range = a <= b ? a...b : b...a
        let rangeSet = Set(orderedKeys[range])
        return additive ? current.union(rangeSet) : rangeSet
    }

    static func resolve(current: Set<UUID>,
                        anchor: UUID?,
                        clicked: UUID,
                        orderedIDs: [UUID],
                        command: Bool,
                        shift: Bool) -> (selection: Set<UUID>, anchor: UUID) {
        if shift,
           let anchor,
           let a = orderedIDs.firstIndex(of: anchor),
           let b = orderedIDs.firstIndex(of: clicked) {
            let range = a <= b ? a...b : b...a
            return (Set(orderedIDs[range]), anchor)
        }
        if command {
            var next = current
            if next.contains(clicked) {
                next.remove(clicked)
            } else {
                next.insert(clicked)
            }
            return (next, clicked)
        }
        return ([clicked], clicked)
    }
}

// MARK: - 侧栏行坐标登记表 + 窗口捕获

/// 记录每行在窗口中的坐标，配合本地事件监视器判定点击落在哪一行
final class SidebarRowRegistry {
    var window: NSWindow?
    var frames: [UUID: NSRect] = [:]

    func set(_ id: UUID, _ rect: NSRect) { frames[id] = rect }
    func remove(_ id: UUID) { frames.removeValue(forKey: id) }
    func row(at point: NSPoint) -> UUID? {
        frames.first(where: { $0.value.contains(point) })?.key
    }
}

/// 侧栏表树的行坐标登记表（支持 ⌘/⇧/拖拽划选）
final class TreeRowRegistry {
    private var frames: [String: (rect: NSRect, tableID: UUID?)] = [:]

    func set(_ key: String, _ rect: NSRect, tableID: UUID?) {
        frames[key] = (rect, tableID)
    }

    func remove(_ key: String) {
        frames.removeValue(forKey: key)
    }

    func hit(at point: NSPoint) -> (key: String, tableID: UUID?)? {
        frames.first(where: { $0.value.rect.contains(point) }).map { ($0.key, $0.value.tableID) }
    }

    var debugCount: Int { frames.count }

    var debugDescription: String {
        frames.sorted { $0.value.rect.minY < $1.value.rect.minY }
            .map { "\($0.key.prefix(8))=\(NSStringFromRect($0.value.rect))" }
            .joined(separator: " ")
    }
}

/// 上报自身在窗口中的坐标（AppKit 坐标系，与 NSEvent.locationInWindow 一致）
struct WindowFrameReporter: NSViewRepresentable {
    var onFrame: (NSRect, NSWindow?) -> Void
    var onRemove: () -> Void = {}

    func makeNSView(context: Context) -> ReportView {
        let v = ReportView()
        v.onFrame = onFrame
        v.onRemove = onRemove
        return v
    }

    func updateNSView(_ nsView: ReportView, context: Context) {
        nsView.onFrame = onFrame
        nsView.onRemove = onRemove
    }

    final class ReportView: NSView {
        var onFrame: (NSRect, NSWindow?) -> Void = { _, _ in }
        var onRemove: () -> Void = {}

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                onRemove()
            } else {
                report()
            }
        }

        // 行视图仅平移（上方行高变化/列表滚动/行回收复用）时 AppKit 不触发 layout()，
        // 只靠 layout 上报会让注册坐标过期——点击错位且偏差逐行累积。
        // 因此在任意 frame 变化时都重新上报。
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        private func report() {
            if let window {
                onFrame(convert(bounds, to: nil), window)
            }
        }
    }
}

/// 捕获所在的主窗口（事件监视器用它过滤事件来源，避免误吞弹窗里的事件）
struct WindowAccessor: NSViewRepresentable {
    let onUpdate: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onUpdate(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onUpdate(nsView.window) }
    }
}
