import XCTest
import SQLite3
@testable import StudentDB

/// SQLite 数据库导出往返验证：导出后用 sqlite3 打开读回，逐表逐值核对
@MainActor
final class SQLiteExportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// 打开导出的库并执行查询，返回首行首列（TEXT）
    private func query(_ path: String, _ sql: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = db else {
            XCTFail("无法打开导出的数据库")
            return nil
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            XCTFail("查询失败: \(sql) — \(String(cString: sqlite3_errmsg(handle)))")
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let text = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        return text
    }

    func testExportRoundTrip() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("库.studentproj"), name: "库")
        var a = Student()
        a.name = "王小明"; a.studentNumber = "2024001"; a.isBoarding = true
        a.phone = "13812345678"; a.policeStation = "城南所"
        a.guardians = [Guardian(name: "王建国", relation: "父", phone: "13998765432")]
        store.addStudent(a)
        var b = Student()
        b.name = "李小红"; b.studentNumber = "2024002"; b.isBoarding = false
        store.addStudent(b)
        _ = store.addField(name: "班级", type: .text)
        a = store.data.students[0]
        a.customValues[store.data.fieldDefinitions[0].id.uuidString] = .text("三（2）班")
        store.updateStudent(a)

        let table = store.addTable(name: "校园矛盾排查", kind: .record, fields: [
            CustomField(name: "学生", type: .linkStudents),
            CustomField(name: "化解状态", type: .choice(options: ["未化解", "已化解"])),
            CustomField(name: "是否通知家长", type: .boolean),
            CustomField(name: "涉及金额", type: .number),
            CustomField(name: "发生时间", type: .dateTime),
        ])
        let ids = store.data.students.map { $0.id }
        var date = DateComponents(); date.year = 2026; date.month = 9; date.day = 20; date.hour = 10
        _ = store.addRow(tableID: table.id, values: [
            table.fields[0].id.uuidString: .link(ids),
            table.fields[1].id.uuidString: .text("已化解"),
            table.fields[2].id.uuidString: .boolean(true),
            table.fields[3].id.uuidString: .number(1200),
            table.fields[4].id.uuidString: .date(Calendar.current.date(from: date)!),
        ])

        let file = tempDir.appendingPathComponent("导出.sqlite")
        try SQLiteExporter.export(data: store.data, to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        // 不应留下 wal/shm 附属文件
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-wal"))

        let path = file.path
        // 表清单：学生总表 + 默认记录表 + 校园矛盾排查
        XCTAssertEqual(query(path, "SELECT count(*) FROM sqlite_master WHERE type='table'"),
                       String(1 + store.data.tables.count))
        // 学生总表内容
        XCTAssertEqual(query(path, "SELECT 学号 FROM 学生总表 WHERE 姓名='王小明'"), "2024001")
        XCTAssertEqual(query(path, "SELECT 是否住宿 FROM 学生总表 WHERE 姓名='王小明'"), "1")
        XCTAssertEqual(query(path, "SELECT 是否住宿 FROM 学生总表 WHERE 姓名='李小红'"), "0")
        XCTAssertEqual(query(path, "SELECT 监护人1姓名 FROM 学生总表 WHERE 姓名='王小明'"), "王建国")
        XCTAssertEqual(query(path, "SELECT 班级 FROM 学生总表 WHERE 姓名='王小明'"), "三（2）班")
        XCTAssertEqual(query(path, "SELECT count(*) FROM 学生总表"), "2")
        // 排查表：关联学生姓名化、布尔 1、数字、日期时间 ISO
        XCTAssertEqual(query(path, "SELECT 学生 FROM 校园矛盾排查"), "王小明、李小红")
        XCTAssertEqual(query(path, "SELECT 化解状态 FROM 校园矛盾排查"), "已化解")
        XCTAssertEqual(query(path, "SELECT 是否通知家长 FROM 校园矛盾排查"), "1")
        XCTAssertEqual(query(path, "SELECT 涉及金额 FROM 校园矛盾排查"), "1200.0")
        XCTAssertEqual(query(path, "SELECT 发生时间 FROM 校园矛盾排查"), "2026-09-20 10:00:00")
        // 空表也有表结构
        XCTAssertEqual(query(path, "SELECT count(*) FROM 关心关爱记录"), "0")
    }

    func testDuplicateFieldNamesDeduplicated() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("库2.studentproj"), name: "库2")
        let table = store.addTable(name: "T", kind: .custom, fields: [
            CustomField(name: "备注", type: .text),
            CustomField(name: "备注", type: .number),   // 同名列
        ])
        _ = store.addRow(tableID: table.id, values: [
            table.fields[0].id.uuidString: .text("甲"),
            table.fields[1].id.uuidString: .number(3),
        ])
        let file = tempDir.appendingPathComponent("导出2.sqlite")
        try SQLiteExporter.export(data: store.data, to: file)
        // 建表成功（同名列被自动改名）
        XCTAssertEqual(query(file.path, "SELECT 备注 FROM T"), "甲")
        XCTAssertEqual(query(file.path, "SELECT \"备注(2)\" FROM T"), "3.0")
    }
}
