import XCTest
@testable import StudentDB

/// 电话/身份证专用字段：校验算法与编辑/导入行为
@MainActor
final class PhoneIDCardTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneIDCardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: 校验算法

    func testIDCardChecksum() {
        // 有效 18 位（校验码正确）
        XCTAssertTrue(FieldFormat.isValidIDCard("11010519491231002X"))
        XCTAssertTrue(FieldFormat.isValidIDCard("440524188001010014"))  // 末位数字
        // 校验码错误
        XCTAssertFalse(FieldFormat.isValidIDCard("110105194912310022"))
        XCTAssertFalse(FieldFormat.isValidIDCard("110105194912310020"))
        // 位数不对
        XCTAssertFalse(FieldFormat.isValidIDCard("1101051949123100"))
        XCTAssertFalse(FieldFormat.isValidIDCard("1101051949123100211"))
        // 前缀非数字
        XCTAssertFalse(FieldFormat.isValidIDCard("a1010519491231002X"))
        // 15 位旧证
        XCTAssertTrue(FieldFormat.isValidIDCard("110105491231002"))
        // 空与乱
        XCTAssertFalse(FieldFormat.isValidIDCard(""))
        XCTAssertFalse(FieldFormat.isValidIDCard("身份证号"))
    }

    func testPhoneValidation() {
        XCTAssertTrue(FieldFormat.isValidPhone("13812345678"))
        XCTAssertTrue(FieldFormat.isValidPhone("0510-8888888"))
        XCTAssertTrue(FieldFormat.isValidPhone("+8613812345678"))
        XCTAssertFalse(FieldFormat.isValidPhone("12345"))       // 太短
        XCTAssertFalse(FieldFormat.isValidPhone("13812345678901234"))  // 太长
        XCTAssertFalse(FieldFormat.isValidPhone("电话"))
    }

    // MARK: 导入校验

    func testGenericTableImportValidates() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("库.studentproj"), name: "库")
        var s = Student(); s.name = "甲"; store.addStudent(s)
        let table = store.addTable(name: "排查", kind: .record, fields: [
            CustomField(name: "身份证", type: .idCard),
            CustomField(name: "电话", type: .phone),
        ])
        let idField = table.fields[0], phoneField = table.fields[1]

        // 合法值导入成功；非法值跳过并给提示
        let good = TableImporter.convert(text: "11010519491231002X", field: idField, store: store, tableID: table.id)
        XCTAssertEqual(good.value, .text("11010519491231002X"))
        XCTAssertNil(good.note)

        let bad = TableImporter.convert(text: "12345", field: idField, store: store, tableID: table.id)
        XCTAssertNil(bad.value)
        XCTAssertTrue(bad.note?.contains("身份证") == true)

        let badPhone = TableImporter.convert(text: "abc", field: phoneField, store: store, tableID: table.id)
        XCTAssertNil(badPhone.value)
        XCTAssertTrue(badPhone.note?.contains("电话") == true)
        let okPhone = TableImporter.convert(text: "13812345678", field: phoneField, store: store, tableID: table.id)
        XCTAssertEqual(okPhone.value, .text("13812345678"))
    }

    // MARK: 类型切换兼容

    func testTypeSwitchKeepsText() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("库2.studentproj"), name: "库2")
        let table = store.addTable(name: "T", kind: .custom, fields: [
            CustomField(name: "证件", type: .text),
        ])
        let f = table.fields[0]
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("11010519491231002X")])
        // 文本 → 身份证：值原样保留（显示层负责标红校验）
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .idCard)
        let row = store.data.table(id: table.id)!.rows[0]
        XCTAssertEqual(row.values[f.id.uuidString], .text("11010519491231002X"))
    }
}
