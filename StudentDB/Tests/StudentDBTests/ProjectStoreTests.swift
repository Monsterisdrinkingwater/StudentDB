import XCTest
@testable import StudentDB

@MainActor
final class ProjectStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudentDBTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    private func makeProjectURL() -> URL {
        tempDir.appendingPathComponent("测试学生库.studentproj")
    }

    private func makeStudent(name: String, number: String) -> Student {
        var s = Student()
        s.name = name
        s.studentNumber = number
        s.isBoarding = true
        s.phone = "13800000000"
        s.boardingAddress = "幸福路 1 号"
        s.policeStation = "城南派出所"
        s.guardians = [Guardian(name: "张父", relation: "父", phone: "13900000000")]
        return s
    }

    // MARK: 编解码

    /// 日期按毫秒量化，比较时允许亚毫秒误差
    private func assertDatesClose(_ a: Date, _ b: Date, accuracy: TimeInterval = 0.002,
                                  _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: accuracy, message, file: file, line: line)
    }

    private func assertStudentsClose(_ a: Student, _ b: Student, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.id, b.id, file: file, line: line)
        XCTAssertEqual(a.name, b.name, file: file, line: line)
        XCTAssertEqual(a.studentNumber, b.studentNumber, file: file, line: line)
        XCTAssertEqual(a.isBoarding, b.isBoarding, file: file, line: line)
        XCTAssertEqual(a.phone, b.phone, file: file, line: line)
        XCTAssertEqual(a.boardingAddress, b.boardingAddress, file: file, line: line)
        XCTAssertEqual(a.policeStation, b.policeStation, file: file, line: line)
        XCTAssertEqual(a.customValues, b.customValues, file: file, line: line)
        XCTAssertEqual(a.guardians, b.guardians, file: file, line: line)
        XCTAssertEqual(a.records.count, b.records.count, file: file, line: line)
        assertDatesClose(a.createdAt, b.createdAt, "createdAt", file: file, line: line)
        assertDatesClose(a.updatedAt, b.updatedAt, "updatedAt", file: file, line: line)
        for (r1, r2) in zip(a.records, b.records) {
            XCTAssertEqual(r1.id, r2.id, file: file, line: line)
            XCTAssertEqual(r1.type, r2.type, file: file, line: line)
            XCTAssertEqual(r1.content, r2.content, file: file, line: line)
            assertDatesClose(r1.date, r2.date, "record.date", file: file, line: line)
            assertDatesClose(r1.createdAt, r2.createdAt, "record.createdAt", file: file, line: line)
        }
    }

    func testProjectDataRoundTrip() throws {
        var data = ProjectData()
        data.fieldDefinitions = [CustomField(name: "班级", type: .text),
                                 CustomField(name: "出生日期", type: .date)]
        var student = makeStudent(name: "王小明", number: "2024001")
        student.customValues[data.fieldDefinitions[0].id.uuidString] = .text("三年级二班")
        student.customValues[data.fieldDefinitions[1].id.uuidString] = .date(Date(timeIntervalSince1970: 1_000_000))
        student.records = [CareRecord(type: "家访", content: "与家长面谈")]
        data.students = [student]

        let raw = try ProjectStore.encoder.encode(data)
        let decoded = try ProjectStore.decoder.decode(ProjectData.self, from: raw)

        XCTAssertEqual(decoded.formatVersion, data.formatVersion)
        XCTAssertEqual(decoded.recordTypes, data.recordTypes)
        XCTAssertEqual(decoded.fieldDefinitions, data.fieldDefinitions)
        assertDatesClose(decoded.createdAt, data.createdAt)
        assertDatesClose(decoded.updatedAt, data.updatedAt)
        XCTAssertEqual(decoded.students.count, data.students.count)
        if let original = data.students.first, let roundTripped = decoded.students.first {
            assertStudentsClose(roundTripped, original)
        }
    }

    // MARK: 新建 / 打开 / 保存

    func testCreateOpenSaveRoundTrip() throws {
        let url = makeProjectURL()
        let store = ProjectStore()
        try store.createProject(at: url, name: "测试学生库")
        store.addStudent(makeStudent(name: "王小明", number: "2024001"))
        try store.saveNow()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("students.json").path))
        XCTAssertTrue(url.pathExtension == "studentproj")

        let reopened = ProjectStore()
        try reopened.openProject(at: url)
        XCTAssertEqual(reopened.data.students.count, 1)
        XCTAssertEqual(reopened.data.students.first?.name, "王小明")
        XCTAssertEqual(reopened.data.students.first?.guardians.first?.name, "张父")
        XCTAssertNil(reopened.recoveryNotice)
    }

    // MARK: 损坏自动恢复

    func testCorruptDataFallsBackToBackup() throws {
        let url = makeProjectURL()
        let store = ProjectStore()
        try store.createProject(at: url, name: "测试学生库")
        store.addStudent(makeStudent(name: "王小明", number: "2024001"))
        try store.backupNow()
        store.addStudent(makeStudent(name: "李小红", number: "2024002"))
        try store.saveNow()

        // 破坏数据文件
        try Data("{{{ 不是合法 JSON".utf8).write(to: url.appendingPathComponent("students.json"))

        let reopened = ProjectStore()
        try reopened.openProject(at: url)
        // students.json 是最后一次保存（2 人）——备份发生在 1 人时，所以应恢复到备份并给出提示
        XCTAssertNotNil(reopened.recoveryNotice)
        XCTAssertEqual(reopened.data.students.count, 1)
        XCTAssertEqual(reopened.data.students.first?.name, "王小明")
    }

    // MARK: 备份清理

    func testBackupPruning() throws {
        let url = makeProjectURL()
        let store = ProjectStore()
        try store.createProject(at: url, name: "测试学生库")

        for i in 0..<15 {
            store.addStudent(makeStudent(name: "学生\(i)", number: "2024\(String(format: "%03d", i))"))
            try store.backupNow()
        }

        let backups = store.listBackups()
        XCTAssertEqual(backups.count, ProjectStore.maxBackups)
    }

    // MARK: 学号查重

    func testDuplicateStudentNumber() throws {
        let url = makeProjectURL()
        let store = ProjectStore()
        try store.createProject(at: url, name: "测试学生库")
        store.addStudent(makeStudent(name: "王小明", number: "2024001"))

        XCTAssertTrue(store.isStudentNumberTaken("2024001"))
        XCTAssertTrue(store.isStudentNumberTaken(" 2024001 ")) // 忽略空白
        XCTAssertFalse(store.isStudentNumberTaken("2024002"))
        XCTAssertFalse(store.isStudentNumberTaken("", excluding: nil))
    }

    // MARK: 字段删除应清除所有学生的值

    func testDeleteFieldRemovesValues() throws {
        let url = makeProjectURL()
        let store = ProjectStore()
        try store.createProject(at: url, name: "测试学生库")

        store.addField(name: "班级", type: .text)
        guard let field = store.data.fieldDefinitions.first else {
            return XCTFail("字段未添加")
        }

        var student = makeStudent(name: "王小明", number: "2024001")
        student.customValues[field.id.uuidString] = .text("三（2）班")
        store.addStudent(student)

        store.deleteField(id: field.id)

        XCTAssertTrue(store.data.fieldDefinitions.isEmpty)
        XCTAssertTrue(store.data.students.first?.customValues.isEmpty ?? false)
    }

    // MARK: 删除记录不影响其他记录

    func testDeleteRecord() throws {
        let url = makeProjectURL()
        let store = ProjectStore()
        try store.createProject(at: url, name: "测试学生库")

        let student = makeStudent(name: "王小明", number: "2024001")
        store.addStudent(student)
        let sid = store.data.students[0].id

        var r1 = CareRecord(); r1.content = "第一次家访"
        var r2 = CareRecord(); r2.content = "电话回访"
        store.addRecord(r1, to: sid)
        store.addRecord(r2, to: sid)

        let id1 = store.data.students[0].records[0].id
        store.deleteRecord(id: id1, studentID: sid)

        XCTAssertEqual(store.data.students[0].records.count, 1)
        XCTAssertEqual(store.data.students[0].records.first?.content, "电话回访")
    }

    // MARK: CSV

    func testCSVExport() {
        var data = ProjectData()
        data.fieldDefinitions = [CustomField(name: "班级", type: .text)]
        var student = makeStudent(name: "王小明", number: "2024001")
        student.customValues[data.fieldDefinitions[0].id.uuidString] = .text("三（2）班")
        student.records = [CareRecord(), CareRecord()]
        data.students = [student]

        let csv = CSVExporter.exportCSV(data: data)
        XCTAssertTrue(csv.contains("姓名"))
        XCTAssertTrue(csv.contains("王小明"))
        XCTAssertTrue(csv.contains("三（2）班"))
        XCTAssertTrue(csv.contains("张父"))
        XCTAssertTrue(csv.contains("2")) // 记录数
    }

    // MARK: 密码锁

    func testAppLock() {
        let existed = AppLock.isEnabled
        defer {
            if !existed { AppLock.disable() }
        }

        AppLock.enable(password: "1234")
        XCTAssertTrue(AppLock.isEnabled)
        XCTAssertTrue(AppLock.verify(password: "1234"))
        XCTAssertFalse(AppLock.verify(password: "4321"))

        AppLock.disable()
        XCTAssertFalse(AppLock.isEnabled)
        XCTAssertFalse(AppLock.verify(password: "1234"))
    }
}

// MARK: 全字段搜索

final class SearchTests: XCTestCase {

    func testSearchableTextCoversAllFields() {
        var data = ProjectData()
        data.fieldDefinitions = [CustomField(name: "班级", type: .text)]
        var student = Student()
        student.name = "王小明"
        student.studentNumber = "2024001"
        student.phone = "13812345678"
        student.policeStation = "城南派出所"
        student.boardingAddress = "幸福路12号"
        student.guardians = [Guardian(name: "张父", relation: "父", phone: "13998765432")]
        student.customValues[data.fieldDefinitions[0].id.uuidString] = .text("三（2）班")

        let text = SearchKit.searchableText(of: student, fields: data.fieldDefinitions)
        for keyword in ["王小明", "2024001", "13812345678", "城南派出所", "幸福路", "张父", "13998765432", "三（2）班"] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(keyword), "搜索应覆盖: \(keyword)")
        }
        XCTAssertFalse(text.localizedCaseInsensitiveContains("李小红"))
    }
}
