import XCTest
import SwiftUI
@testable import StudentDB

/// 表格日期格端到端：按钮 → 弹出日历 → 改值 → 数据与单元格实时更新
/// 驱动真实的 NSTableView（NSHostingView + NSWindow），不 mock。
@MainActor
final class DateCellPopoverTests: XCTestCase {

    /// 钉住测试里创建的窗口：AppKit 对象若在测试进程 teardown 阶段析构会段错误
    static var pinnedWindows: [NSWindow] = []

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DateCellPopoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// 深度遍历找到 NSTableView
    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = findTableView(in: sub) { return found }
        }
        return nil
    }

    private func pump(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testGenericTableDateCellPopoverFlow() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("测试库.studentproj"), name: "测试库")
        var student = Student(); student.name = "甲"; store.addStudent(student)
        let table = store.addTable(name: "随访", kind: .record, fields: [
            CustomField(name: "学生", type: .linkStudents),
            CustomField(name: "日期", type: .date),
            CustomField(name: "时间", type: .dateTime),
        ])
        let dateField = table.fields.first { $0.name == "日期" }!
        let row = try XCTUnwrap(store.addRow(tableID: table.id))

        var selection = Set<UUID>()

        // 模拟真实界面：store 变化后视图用最新数据重建（App 里由 @ObservedObject 驱动）
        func commit(rowID: UUID, field: CustomField, value: CustomValue?) {
            var updated = store.data.table(id: table.id)!.row(id: rowID) ?? DBRow()
            updated.id = rowID
            if let value {
                updated.values[field.id.uuidString] = value
            } else {
                updated.values.removeValue(forKey: field.id.uuidString)
            }
            store.updateRow(tableID: table.id, row: updated)
            try? store.saveNow()
        }

        func buildView() -> some View {
            let current = store.data.table(id: table.id)!
            return EditableGenericTable(
                store: store,
                table: current,
                rows: current.rows,
                fields: current.orderedFields,
                sortFieldID: nil,
                sortAscending: true,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                onCommit: { rowID, field, value in commit(rowID: rowID, field: field, value: value) },
                onSortChange: { _, _ in },
                onHideField: { _ in },
                onDeleteField: { _ in },
                onMoveFields: { _ in },
                onFilterField: { _ in }
            )
            .frame(width: 600, height: 200)
        }

        let hosting = NSHostingView(rootView: buildView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump(0.3)

        let tableView = try XCTUnwrap(findTableView(in: hosting), "应能找到 NSTableView")
        let coordinator = try XCTUnwrap(tableView.delegate as? EditableGenericTable.Coordinator)
        let columnIndex = try XCTUnwrap(
            tableView.tableColumns.firstIndex { $0.identifier.rawValue == dateField.id.uuidString },
            "日期列应已创建")
        let button = try XCTUnwrap(
            tableView.view(atColumn: columnIndex, row: 0, makeIfNecessary: true) as? TableDateButton,
            "日期格应是 TableDateButton")
        XCTAssertEqual(button.title, "设置日期", "空值显示占位文案")

        // 第一次点击：只选中行，不弹日历
        coordinator.dateButtonTapped(button)
        XCTAssertEqual(selection, [row.id])
        XCTAssertNil(coordinator.datePopover)

        // 第二次点击：弹出日历（尺寸应与日历固有尺寸一致）
        coordinator.dateButtonTapped(button)
        let popover = try XCTUnwrap(coordinator.datePopover, "应弹出日历")
        let container = try XCTUnwrap(popover.contentViewController?.view)
        let picker = try XCTUnwrap(container.subviews.first as? TableGraphicalDatePicker)
        XCTAssertEqual(picker.datePickerStyle, .clockAndCalendar)
        // 弹层与日历固有尺寸一致（允许半点取整误差）
        XCTAssertLessThanOrEqual(abs(popover.contentSize.width - picker.fittingSize.width), 1)
        XCTAssertLessThanOrEqual(abs(popover.contentSize.height - picker.fittingSize.height), 1)

        // 用户在日历上选一个日期 → 提交
        var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 20
        let target = Calendar.current.date(from: comps)!
        picker.dateValue = target
        coordinator.popoverDateChanged(picker)

        // 数据已实时写入
        guard case .date(let storedDate)? = store.data.table(id: table.id)!.row(id: row.id)?
            .values[dateField.id.uuidString] else {
            return XCTFail("选择器改值应实时写入数据")
        }
        XCTAssertEqual(storedDate.timeIntervalSince1970, target.timeIntervalSince1970)

        // 界面重渲染后单元格文字刷新
        pump(0.2)
        hosting.rootView = buildView()
        pump(0.4)
        let refreshed = try XCTUnwrap(
            tableView.view(atColumn: columnIndex, row: 0, makeIfNecessary: true) as? TableDateButton)
        XCTAssertEqual(refreshed.title, "2026年9月20日", "按钮应显示新日期，实际：\(refreshed.title)")

        // 再次点开日历：初始值应为已保存的日期
        coordinator.dateButtonTapped(refreshed)
        let picker2 = try XCTUnwrap(coordinator.datePopover?.contentViewController?.view.subviews.first as? TableGraphicalDatePicker)
        XCTAssertEqual(Calendar.current.startOfDay(for: picker2.dateValue),
                       Calendar.current.startOfDay(for: target))
        coordinator.datePopover?.close()
        window.orderOut(nil)
        Self.pinnedWindows.append(window)
    }
}
