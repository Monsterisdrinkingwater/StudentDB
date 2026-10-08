import XCTest
@testable import StudentDB

/// 列筛选排除空值：取消勾选「（空）」后，该列为空的行必须被筛掉
@MainActor
final class EmptyValueFilterTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyValueFilterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// 通用表：selectedValues 含全部非空值但不含 ""（即用户取消勾选「（空）」）→ 空行被排除
    func testGenericTableExcludesEmptyWhenUnchecked() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("库.studentproj"), name: "库")
        let table = store.addTable(name: "T", kind: .custom, fields: [
            CustomField(name: "状态", type: .choice(options: ["未化解", "已化解"])),
        ])
        let f = table.fields[0]
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("未化解")])
        _ = store.addRow(tableID: table.id)   // 该列为空

        // 模拟弹层「取消勾选（空）」后的 apply() 结果：非空值全选、不含 ""
        var filter = ColumnFilter()
        filter.selectedValues = ["未化解"]
        var view = table.currentView
        view.columnFilters[f.id.uuidString] = filter

        // 与真实界面一致：TableViews.tableVisibleRows 的两步链路
        let base = TableQuery.apply(view: view, rows: store.data.table(id: table.id)!.rows,
                                    fields: table.orderedFields) { _ in "" }
        let rows = TableQuery.applyColumnFilters(base, fields: table.orderedFields,
                                                 filters: view.columnFilters) { _ in "" }
        XCTAssertEqual(rows.count, 1, "空值行应被筛掉")
        XCTAssertEqual(rows.first?.values[f.id.uuidString], .text("未化解"))
    }

    /// 学生表：selectedValues 不含 "" → 该列为空的学生被筛掉
    func testStudentTableExcludesEmptyWhenUnchecked() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("库2.studentproj"), name: "库2")
        var a = Student(); a.name = "甲"; a.policeStation = "城南所"
        var b = Student(); b.name = "乙"   // 派出所为空
        store.addStudent(a)
        store.addStudent(b)

        var filter = ColumnFilter()
        filter.selectedValues = ["城南所"]
        var view = store.currentView
        view.columnFilters["policeStation"] = filter

        // 与真实界面一致：基础筛选后叠加列筛选（MainWindow.filteredStudents 的调用路径）
        let columns = StudentColumnSpec.allColumns(fields: [], guardianSlots: 1)
        let base = StudentQuery.apply(view: view, students: store.data.students, fields: [])
        let result = StudentQuery.applyColumnFilters(base, columns: columns,
                                                     filters: view.columnFilters)
        XCTAssertEqual(result.map(\.name), ["甲"], "空值学生应被筛掉")
    }
}
