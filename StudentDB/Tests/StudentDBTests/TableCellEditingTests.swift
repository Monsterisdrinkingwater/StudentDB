import XCTest
import SwiftUI
@testable import StudentDB

/// 表格内全字段类型编辑端到端：驱动真实 NSTableView，逐类型断言提交后数据正确。
/// 菜单/弹层类控件的“条目提交路径”即真实点击最终调用的处理函数。
@MainActor
final class TableCellEditingTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableCellEditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// 钉住测试创建的窗口：AppKit 对象在测试进程 teardown 阶段析构会段错误
    static var pinnedWindows: [NSWindow] = []

    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = findTableView(in: sub) { return found }
        }
        return nil
    }

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: 通用表：文本/数字/勾选/单选/多选/关联学生/附件

    func testGenericTableEveryFieldTypeEditable() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("测试库.studentproj"), name: "测试库")
        for (name, number) in [("王小明", "2024001"), ("李小红", "2024002")] {
            var s = Student(); s.name = name; s.studentNumber = number
            store.addStudent(s)
        }
        let table = store.addTable(name: "全类型", kind: .record, fields: [
            CustomField(name: "事项", type: .text),
            CustomField(name: "天数", type: .number),
            CustomField(name: "完成", type: .boolean),
            CustomField(name: "日期", type: .date),
            CustomField(name: "状态", type: .choice(options: ["未化解", "已化解"])),
            CustomField(name: "类型", type: .multiChoice(options: ["心理问题", "家庭变故"])),
            CustomField(name: "学生", type: .linkStudents),
            CustomField(name: "附件", type: .attachment),
        ])
        func field(_ name: String) -> CustomField {
            table.fields.first { $0.name == name }!
        }
        let row = try XCTUnwrap(store.addRow(tableID: table.id))

        var selection = Set<UUID>()
        func commit(rowID: UUID, f: CustomField, value: CustomValue?) {
            var updated = store.data.table(id: table.id)!.row(id: rowID) ?? DBRow()
            updated.id = rowID
            if let value {
                updated.values[f.id.uuidString] = value
            } else {
                updated.values.removeValue(forKey: f.id.uuidString)
            }
            store.updateRow(tableID: table.id, row: updated)
        }
        func buildView() -> some View {
            let current = store.data.table(id: table.id)!
            return EditableGenericTable(
                store: store, table: current, rows: current.rows, fields: current.orderedFields,
                sortFieldID: nil, sortAscending: true,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                onCommit: { rowID, f, value in commit(rowID: rowID, f: f, value: value) },
                onSortChange: { _, _ in }, onHideField: { _ in }, onDeleteField: { _ in },
                onMoveFields: { _ in }, onFilterField: { _ in }
            )
            .frame(width: 900, height: 200)
        }
        let hosting = NSHostingView(rootView: buildView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump()
        defer { window.orderOut(nil); Self.pinnedWindows.append(window) }

        let tableView = try XCTUnwrap(findTableView(in: hosting))
        let coordinator = try XCTUnwrap(tableView.delegate as? EditableGenericTable.Coordinator)
        func cellView(_ name: String) -> NSView? {
            guard let idx = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == field(name).id.uuidString
            }) else { return nil }
            return tableView.view(atColumn: idx, row: 0, makeIfNecessary: true)
        }
        func stored(_ name: String) -> CustomValue? {
            store.data.table(id: table.id)!.row(id: row.id)!.values[field(name).id.uuidString]
        }

        // 1) 文本：字段编辑器结束编辑的提交路径
        coordinator.editingContext = (row.id, field("事项"))
        let editor = NSTextField(string: "首次谈心")
        coordinator.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: editor))
        XCTAssertEqual(stored("事项"), .text("首次谈心"))

        // 2) 数字：同样路径，非法数字被拒（蜂鸣不清空）
        coordinator.editingContext = (row.id, field("天数"))
        coordinator.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification,
                                                          object: NSTextField(string: "3.5")))
        XCTAssertEqual(stored("天数"), .number(3.5))
        coordinator.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification,
                                                          object: NSTextField(string: "三点半")))
        XCTAssertEqual(stored("天数"), .number(3.5), "非法数字不应覆盖已有值")

        // 3) 勾选：第一次点击只选中行（状态被还原）；第二次点击提交
        let checkbox = try XCTUnwrap(cellView("完成") as? StudentCheckboxCellView)
        checkbox.button.state = .on
        coordinator.checkboxToggled(checkbox.button)
        XCTAssertEqual(selection, [row.id], "第一次点击只选中行")
        XCTAssertNil(stored("完成"))
        checkbox.button.state = .on   // 用户第二次点击的视觉状态
        coordinator.checkboxToggled(checkbox.button)
        XCTAssertEqual(stored("完成"), .boolean(true))

        // 4) 单选：下拉选择提交
        let popup = try XCTUnwrap(cellView("状态") as? StudentChoiceCellView)
        popup.popup.selectItem(withTitle: "已化解")
        coordinator.choiceSelected(popup.popup)
        XCTAssertEqual(stored("状态"), .text("已化解"))

        // 5) 多选：菜单条目提交路径（点击菜单项最终调用）
        let multiItem = NSMenuItem(title: "心理问题", action: nil, keyEquivalent: "")
        multiItem.representedObject = [
            "rowID": row.id.uuidString,
            "fieldID": field("类型").id.uuidString,
            "value": "心理问题、家庭变故"
        ] as [String: Any]
        coordinator.multiChoiceItemToggled(multiItem)
        XCTAssertEqual(stored("类型"), .text("心理问题、家庭变故"))

        // 6) 关联学生：菜单条目提交路径（按姓名/学号匹配后的 id 集）
        let ids = store.data.students.map { $0.id }
        let linkItem = NSMenuItem(title: "王小明", action: nil, keyEquivalent: "")
        linkItem.representedObject = [
            "rowID": row.id.uuidString,
            "fieldID": field("学生").id.uuidString,
            "ids": ids.map { $0.uuidString }
        ] as [String: Any]
        coordinator.studentLinkItemToggled(linkItem)
        XCTAssertEqual(stored("学生"), .link(ids))

        // 7) 日期：按钮 + 弹出日历（详见 DateCellPopoverTests，这里验证按钮与日历动作）
        let dateButton = try XCTUnwrap(cellView("日期") as? TableDateButton)
        coordinator.dateButtonTapped(dateButton)   // 行已选中 → 直接弹日历
        let picker = try XCTUnwrap(coordinator.datePopover?.contentViewController?.view.subviews.first as? TableGraphicalDatePicker)
        picker.dateValue = Date(timeIntervalSince1970: 1_800_000_000)
        coordinator.popoverDateChanged(picker)
        XCTAssertEqual(stored("日期"), .date(Date(timeIntervalSince1970: 1_800_000_000)))

        // 8) 附件：按钮格存在且挂了上下文；菜单动作提交路径（删除）
        let attachButton = try XCTUnwrap(cellView("附件") as? TableAttachmentButton)
        XCTAssertEqual(attachButton.context?.rowID, row.id)
        XCTAssertEqual(attachButton.context?.fieldID, field("附件").id)
        XCTAssertEqual(attachButton.title, "＋ 添加", "无附件时显示添加入口")
    }

    // MARK: 双击文本格 → 就地编辑（字段编辑器挂载 + 提交后还原静态显示）

    /// 通用表：双击文本格就地编辑；非文本格（如日期）不进入就地编辑（维持打开行编辑器）
    func testGenericTableDoubleClickTextEditsInPlace() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("测试库3.studentproj"), name: "测试库3")
        let table = store.addTable(name: "谈心", kind: .record, fields: [
            CustomField(name: "事项", type: .text),
            CustomField(name: "日期", type: .date),
        ])
        let textField = table.fields.first { $0.name == "事项" }!
        let dateField = table.fields.first { $0.name == "日期" }!
        let row = try XCTUnwrap(store.addRow(tableID: table.id))

        var selection = Set<UUID>()
        var openedRowIDs = [UUID]()
        func commit(rowID: UUID, f: CustomField, value: CustomValue?) {
            var updated = store.data.table(id: table.id)!.row(id: rowID) ?? DBRow()
            updated.id = rowID
            if let value {
                updated.values[f.id.uuidString] = value
            } else {
                updated.values.removeValue(forKey: f.id.uuidString)
            }
            store.updateRow(tableID: table.id, row: updated)
        }
        func buildView() -> some View {
            let current = store.data.table(id: table.id)!
            return EditableGenericTable(
                store: store, table: current, rows: current.rows, fields: current.orderedFields,
                sortFieldID: nil, sortAscending: true,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                onOpenRow: { openedRowIDs.append($0) },
                onCommit: { rowID, f, value in commit(rowID: rowID, f: f, value: value) },
                onSortChange: { _, _ in }, onHideField: { _ in }, onDeleteField: { _ in },
                onMoveFields: { _ in }, onFilterField: { _ in }
            )
            .frame(width: 600, height: 200)
        }
        let hosting = NSHostingView(rootView: buildView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump()
        defer { window.orderOut(nil); Self.pinnedWindows.append(window) }

        let tableView = try XCTUnwrap(findTableView(in: hosting))
        let coordinator = try XCTUnwrap(tableView.delegate as? EditableGenericTable.Coordinator)
        func columnIndex(_ field: CustomField) -> Int {
            tableView.tableColumns.firstIndex { $0.identifier.rawValue == field.id.uuidString }!
        }

        // 非文本格（日期）不进入就地编辑：双击分流会落到打开行编辑器
        XCTAssertFalse(coordinator.beginTextEdit(row: 0, columnIndex: columnIndex(dateField), rowID: row.id),
                       "日期格双击不应进入就地编辑")
        XCTAssertTrue(openedRowIDs.isEmpty, "beginTextEdit 只判断分流，不应自己打开行编辑器")

        // 文本格：进入就地编辑，临时打开可编辑/可选
        let textIdx = columnIndex(textField)
        let cell = try XCTUnwrap(tableView.view(atColumn: textIdx, row: 0, makeIfNecessary: true)
            as? StudentTextCellView)
        XCTAssertTrue(coordinator.beginTextEdit(row: 0, columnIndex: textIdx, rowID: row.id))
        XCTAssertEqual(cell.textField?.isEditable, true)
        XCTAssertEqual(cell.textField?.isSelectable, true, "isSelectable 必须临时打开，字段编辑器才能挂载")
        pump()
        let editor = try XCTUnwrap(cell.textField?.currentEditor(),
                                   "双击后应挂上字段编辑器开始就地编辑")

        // 在字段编辑器里输入并结束（回车/失焦路径）：走真实 controlTextDidEndEditing 提交
        editor.string = "第一次谈心"
        window.endEditing(for: editor)
        XCTAssertEqual(store.data.table(id: table.id)!.row(id: row.id)!.values[textField.id.uuidString],
                       .text("第一次谈心"))
        XCTAssertEqual(cell.textField?.isEditable, false, "提交后应还原为静态显示")
        XCTAssertEqual(cell.textField?.isSelectable, false, "提交后应还原 isSelectable，单击继续落在行上")
    }

    /// 学生表：双击文本格（姓名）就地编辑；非文本格（勾选）不进入就地编辑
    func testStudentTableDoubleClickTextEditsInPlace() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("测试库4.studentproj"), name: "测试库4")
        _ = store.addField(name: "是否团员", type: .boolean)
        let boolField = store.data.fieldDefinitions[0]
        var student = Student()
        student.name = "王小明"
        student.studentNumber = "2024001"
        store.addStudent(student)
        let sid = store.data.students[0].id

        var selection = Set<UUID>()
        let columns = StudentColumnSpec.allColumns(fields: store.data.orderedFields, guardianSlots: 1)
        func buildView() -> some View {
            EditableStudentTable(
                students: store.data.students,
                columns: columns,
                sortKey: .name,
                sortAscending: true,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                onSortChange: { _, _ in },
                onCommit: { studentID, spec, edit in
                    guard let target = store.data.students.first(where: { $0.id == studentID }) else { return }
                    let updated = spec.applying(edit, to: target)
                    store.updateStudent(updated)
                }
            )
            .frame(width: 900, height: 200)
        }
        let hosting = NSHostingView(rootView: buildView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump()
        defer { window.orderOut(nil); Self.pinnedWindows.append(window) }

        let tableView = try XCTUnwrap(findTableView(in: hosting))
        let coordinator = try XCTUnwrap(tableView.delegate as? EditableStudentTable.Coordinator)
        func columnIndex(_ columnID: String) -> Int {
            tableView.tableColumns.firstIndex { $0.identifier.rawValue == columnID }!
        }

        // 非文本格（勾选）不进入就地编辑
        XCTAssertFalse(coordinator.beginTextEdit(row: 0, columnIndex: columnIndex(boolField.id.uuidString)))

        // 姓名列：进入就地编辑并提交
        let nameIdx = columnIndex("name")
        let cell = try XCTUnwrap(tableView.view(atColumn: nameIdx, row: 0, makeIfNecessary: true)
            as? StudentTextCellView)
        XCTAssertTrue(coordinator.beginTextEdit(row: 0, columnIndex: nameIdx))
        XCTAssertEqual(cell.textField?.isSelectable, true, "isSelectable 必须临时打开，字段编辑器才能挂载")
        pump()
        let editor = try XCTUnwrap(cell.textField?.currentEditor(),
                                   "双击后应挂上字段编辑器开始就地编辑")
        editor.string = "李小小"
        window.endEditing(for: editor)
        XCTAssertEqual(store.data.students.first { $0.id == sid }?.name, "李小小")
        XCTAssertEqual(cell.textField?.isEditable, false, "提交后应还原为静态显示")
        XCTAssertEqual(cell.textField?.isSelectable, false, "提交后应还原 isSelectable，单击继续落在行上")
    }

    func testStudentTableDatePopoverAndControls() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("测试库2.studentproj"), name: "测试库2")
        _ = store.addField(name: "体检日期", type: .date)
        _ = store.addField(name: "是否团员", type: .boolean)
        let dateField = store.data.fieldDefinitions[0]
        let boolField = store.data.fieldDefinitions[1]
        var student = Student()
        student.name = "王小明"
        student.studentNumber = "2024001"
        store.addStudent(student)
        let sid = store.data.students[0].id

        var selection = Set<UUID>()
        let columns = StudentColumnSpec.allColumns(fields: store.data.orderedFields, guardianSlots: 1)
        func buildView() -> some View {
            EditableStudentTable(
                students: store.data.students,
                columns: columns,
                sortKey: .name,
                sortAscending: true,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                onSortChange: { _, _ in },
                onCommit: { studentID, spec, edit in
                    guard let target = store.data.students.first(where: { $0.id == studentID }) else { return }
                    let updated = spec.applying(edit, to: target)
                    store.updateStudent(updated)
                }
            )
            .frame(width: 900, height: 200)
        }
        let hosting = NSHostingView(rootView: buildView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump()
        defer { window.orderOut(nil); Self.pinnedWindows.append(window) }

        let tableView = try XCTUnwrap(findTableView(in: hosting))
        let coordinator = try XCTUnwrap(tableView.delegate as? EditableStudentTable.Coordinator)
        func cellView(_ columnID: String) -> NSView? {
            guard let idx = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == columnID })
            else { return nil }
            return tableView.view(atColumn: idx, row: 0, makeIfNecessary: true)
        }

        // 日期：首击选中行 → 二击弹日历 → 选日期提交
        let dateButton = try XCTUnwrap(cellView(dateField.id.uuidString) as? StudentDateCellView).button
        XCTAssertEqual(dateButton.title, "设置日期")
        coordinator.dateButtonTapped(dateButton)
        XCTAssertEqual(selection, [sid])
        XCTAssertNil(coordinator.datePopover)
        coordinator.dateButtonTapped(dateButton)
        let picker = try XCTUnwrap(coordinator.datePopover?.contentViewController?.view.subviews.first
            as? StudentGraphicalDatePicker)
        picker.dateValue = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.popoverDateChanged(picker)
        XCTAssertEqual(store.data.students[0].customValues[dateField.id.uuidString],
                       .date(Date(timeIntervalSince1970: 1_700_000_000)))

        // 勾选：首击选中行、二击提交（日期测试里行已被选中过，先清空选择验证首击语义）
        selection = []
        pump()
        let checkbox = try XCTUnwrap(cellView(boolField.id.uuidString) as? StudentCheckboxCellView)
        checkbox.button.state = .on
        coordinator.checkboxToggled(checkbox.button)
        XCTAssertEqual(selection, [sid], "首次点击只选中行")
        XCTAssertNil(store.data.students[0].customValues[boolField.id.uuidString])
        checkbox.button.state = .on
        coordinator.checkboxToggled(checkbox.button)
        XCTAssertEqual(store.data.students[0].customValues[boolField.id.uuidString], .boolean(true))
    }
}
