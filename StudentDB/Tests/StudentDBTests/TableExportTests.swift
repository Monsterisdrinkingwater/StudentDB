import XCTest
@testable import StudentDB

/// 通用表导出：每张表一个工作表，关联学生列显示姓名
@MainActor
final class TableExportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    private func makeStore() throws -> ProjectStore {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("测试库.studentproj"), name: "测试库")
        for (name, number) in [("甲", "2024001"), ("乙", "2024002")] {
            var student = Student()
            student.name = name
            student.studentNumber = number
            store.addStudent(student)
        }
        return store
    }

    func testExportTableSheets() throws {
        let store = try makeStore()
        let table = store.addTable(name: "校园矛盾排查", kind: .record, fields: [
            CustomField(name: "学生", type: .linkStudents),
            CustomField(name: "化解状态", type: .choice(options: ["未化解", "已化解"])),
            CustomField(name: "是否通知家长", type: .boolean),
            CustomField(name: "涉及金额", type: .number),
        ])
        let linkField = table.fields.first { $0.name == "学生" }!
        let statusField = table.fields.first { $0.name == "化解状态" }!
        let boolField = table.fields.first { $0.name == "是否通知家长" }!
        let amountField = table.fields.first { $0.name == "涉及金额" }!
        let ids = store.data.students.map { $0.id }

        _ = store.addRow(tableID: table.id, values: [
            linkField.id.uuidString: .link(ids),
            statusField.id.uuidString: .text("已化解"),
            boolField.id.uuidString: .boolean(true),
            amountField.id.uuidString: .number(1200),
        ])
        _ = store.addRow(tableID: table.id, values: [
            statusField.id.uuidString: .text("未化解"),
        ])

        // 只勾选这张表，其余全关
        let selection = ExportSelection(includeRoster: false, includeGuardians: false,
                                        includeRecords: false, customFieldIDs: [],
                                        guardianSlots: 1, recordTypes: [],
                                        tableIDs: [table.id])
        XCTAssertTrue(selection.includesAnything, "仅勾选数据表也应可导出")

        let file = tempDir.appendingPathComponent("导出.xlsx")
        try ExcelExporter.exportAll(data: store.data, to: file, selection: selection)

        let sheets = try XLSX.readAllSheets(from: file)
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].name, "校园矛盾排查")
        XCTAssertEqual(sheets[0].rows[0], ["学生", "化解状态", "是否通知家长", "涉及金额"])
        // 关联学生列导出为姓名（顿号分隔）；数字不带小数尾巴
        XCTAssertEqual(sheets[0].rows[1], ["甲、乙", "已化解", "是", "1200"])
        // 空值导出为空字符串（读回时行尾空单元格会被裁掉，按前缀比较）
        XCTAssertTrue(sheets[0].rows[2].starts(with: ["", "未化解"]), "实际：\(sheets[0].rows[2])")
    }

    func testAllSelectionIncludesTablesAndEmptyThrows() throws {
        let store = try makeStore()
        let table = store.addTable(name: "平时观察", kind: .record, fields: [
            CustomField(name: "学生", type: .linkStudents),
        ])
        let all = ExportSelection.all(data: store.data)
        XCTAssertTrue(all.tableIDs.contains(table.id))

        let none = ExportSelection(includeRoster: false, includeGuardians: false,
                                   includeRecords: false, customFieldIDs: [],
                                   guardianSlots: 1, recordTypes: [], tableIDs: [])
        XCTAssertFalse(none.includesAnything)
        XCTAssertThrowsError(try ExcelExporter.exportAll(
            data: store.data, to: tempDir.appendingPathComponent("x.xlsx"), selection: none))
    }

    // MARK: - 自定义导出内容

    func testExportTableWithFieldSubset() throws {
        let store = try makeStore()
        let table = store.addTable(name: "排查", kind: .record, fields: [
            CustomField(name: "学生", type: .linkStudents),
            CustomField(name: "身份证", type: .text),
            CustomField(name: "化解状态", type: .choice(options: ["未化解", "已化解"])),
        ])
        let statusField = table.fields.first { $0.name == "化解状态" }!
        let linkField = table.fields.first { $0.name == "学生" }!
        let ids = store.data.students.map { $0.id }
        _ = store.addRow(tableID: table.id, values: [
            linkField.id.uuidString: .link(ids),
            statusField.id.uuidString: .text("已化解"),
        ])

        // 只导「学生、化解状态」两列（隐藏身份证）
        let selection = ExportSelection(includeRoster: false, includeGuardians: false,
                                        includeRecords: false, customFieldIDs: [],
                                        guardianSlots: 1, recordTypes: [],
                                        tableIDs: [table.id],
                                        tableFields: [table.id: [linkField.id, statusField.id]])
        let file = tempDir.appendingPathComponent("字段子集.xlsx")
        try ExcelExporter.exportAll(data: store.data, to: file, selection: selection)
        let sheet = try XLSX.readAllSheets(from: file)[0]
        XCTAssertEqual(sheet.name, "排查")
        XCTAssertEqual(sheet.rows[0], ["学生", "化解状态"])
        XCTAssertEqual(sheet.rows[1], ["甲、乙", "已化解"])

        // 一列都不选 = 该表跳过（连同其他都未勾选时导出报错）
        let emptyFields = ExportSelection(includeRoster: false, includeGuardians: false,
                                          includeRecords: false, customFieldIDs: [],
                                          guardianSlots: 1, recordTypes: [],
                                          tableIDs: [table.id],
                                          tableFields: [table.id: []])
        XCTAssertThrowsError(try ExcelExporter.exportAll(
            data: store.data, to: tempDir.appendingPathComponent("y.xlsx"), selection: emptyFields))
    }

    func testRosterBuiltinSubsetAndNoGuardians() throws {
        let store = try makeStore()
        var student = Student()
        student.name = "王小明"
        student.studentNumber = "2024001"
        student.isBoarding = true
        student.guardians = [Guardian(name: "王建国", relation: "父", phone: "139")]
        store.addStudent(student)

        // 只导 姓名、对应派出所 两列；监护人 0 组（makeStore 已有甲、乙两名学生）
        let selection = ExportSelection(includeRoster: true, includeGuardians: false,
                                        includeRecords: false, customFieldIDs: [],
                                        guardianSlots: 0, recordTypes: [],
                                        tableIDs: [],
                                        builtinColumns: ["name", "policeStation"])
        let file = tempDir.appendingPathComponent("内置子集.xlsx")
        try ExcelExporter.exportAll(data: store.data, to: file, selection: selection)
        let sheet = try XLSX.readAllSheets(from: file)[0]
        XCTAssertEqual(sheet.rows[0], ["姓名", "对应派出所"], "不应出现监护人列")
        let wangRow = try XCTUnwrap(sheet.rows.first { $0.first == "王小明" })
        XCTAssertLessThanOrEqual(wangRow.count, 2, "只导两列；派出所为空时行尾空单元格读回被裁")

        // CSV 同一套选择
        let csv = CSVExporter.exportCSV(data: store.data, guardianSlots: 0,
                                        builtinColumns: ["name"])
        XCTAssertTrue(csv.hasPrefix("姓名\r\n"), "CSV 只导姓名一列，实际：\(csv.prefix(20))")
    }
}
