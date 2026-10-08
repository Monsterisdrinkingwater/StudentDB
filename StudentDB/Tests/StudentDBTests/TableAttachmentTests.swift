import XCTest
@testable import StudentDB

/// 表格附件：文件复制进项目包、计入行最近修改
@MainActor
final class TableAttachmentTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableAttachmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testImportAttachmentIntoField() throws {
        let store = ProjectStore()
        try store.createProject(at: tempDir.appendingPathComponent("测试库.studentproj"), name: "测试库")
        let table = store.addTable(name: "重点学生家访", kind: .record, fields: [
            CustomField(name: "学生", type: .linkStudents),
            CustomField(name: "家访照片", type: .attachment),
        ])
        let photoField = table.fields.first { $0.name == "家访照片" }!
        let row = try XCTUnwrap(store.addRow(tableID: table.id))
        let before = store.data.table(id: table.id)!.rows[0].updatedAt

        // 造一个外部文件导入
        let source = tempDir.appendingPathComponent("照片.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: source)
        Thread.sleep(forTimeInterval: 0.02)

        let dest = try store.importAttachment(at: source, tableID: table.id,
                                              rowID: row.id, fieldID: photoField.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(dest.lastPathComponent, "照片.jpg")
        XCTAssertEqual(store.attachmentFileURLs(tableID: table.id, rowID: row.id, fieldID: photoField.id),
                       [dest])

        // 附件变化计入行的最近修改（表格据此刷新）
        let after = store.data.table(id: table.id)!.rows[0].updatedAt
        XCTAssertGreaterThan(after, before)

        // 删除附件 → 文件移入废纸篓（目录里不再有）
        store.deleteAttachment(dest)
        XCTAssertTrue(store.attachmentFileURLs(tableID: table.id, rowID: row.id, fieldID: photoField.id).isEmpty)
    }
}
