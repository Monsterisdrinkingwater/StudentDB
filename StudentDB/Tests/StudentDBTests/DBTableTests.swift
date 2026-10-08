import XCTest
@testable import StudentDB

/// 通用数据表：行增删改、字段管理、关联学生、迁移
final class DBTableTests: XCTestCase {

    @MainActor
    private func makeStore() throws -> ProjectStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("表测试-\(UUID().uuidString).studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "表测试")
        return store
    }

    @MainActor
    func testNewProjectHasDefaultRecordTables() throws {
        let store = try makeStore()
        XCTAssertEqual(store.data.tables.count, 4)
        XCTAssertEqual(store.data.tables.map { $0.kind }, Array(repeating: .record, count: 4))
        XCTAssertTrue(store.data.recordMigrationDone)
    }

    @MainActor
    func testRowCRUD() throws {
        let store = try makeStore()
        let table = store.data.tables[0]
        // 新增
        let linkField = table.linkField!
        let row = store.addRow(tableID: table.id, values: [
            "内容": .text("测试记录"), linkField.id.uuidString: .link([])
        ])
        XCTAssertNotNil(row)
        XCTAssertEqual(store.data.rows(tableID: table.id).last?.values["内容"]?.displayText, "测试记录")
        let savedRowID = row!.id
        // 更新
        var updated = store.data.rows(tableID: table.id).last!
        var key = ""
        if let field = table.fields.first(where: { $0.type == .address }) { key = field.id.uuidString }
        updated.values[key] = .text("新内容")
        store.updateRow(tableID: table.id, row: updated)
        // 删除
        store.deleteRows(tableID: table.id, ids: Set([savedRowID]))
        XCTAssertEqual(store.data.rows(tableID: table.id).count, 0)
    }

    @MainActor
    func testTableFieldManagement() throws {
        let store = try makeStore()
        let tableID = store.data.tables[0].id
        let newField = store.addTableField(tableID: tableID, name: "金额", type: .number)
        guard let field = newField else { return XCTFail("添加字段失败") }
        XCTAssertEqual(store.data.table(id: tableID)?.orderedFields.last?.name, "金额")
        // 删除字段后行值一并清除
        let row0 = DBRow(values: [field.id.uuidString: .number(9.5)])
        store.updateRow(tableID: tableID, row: row0)
        store.deleteTableField(tableID: tableID, fieldID: field.id)
        let row1 = store.data.rows(tableID: tableID).last ?? DBRow()
        XCTAssertNil(row1.values[field.id.uuidString], "删字段不应残留行值")
    }

    @MainActor
    func testDeleteUserTable() throws {
        let store = try makeStore()
        _ = store.addTable(name: "成绩表", kind: .custom,
                           fields: [CustomField(name: "科目", type: .text)])
        XCTAssertEqual(store.data.tables.count, 5)
        XCTAssertEqual(store.data.currentTableID, store.data.tables.last?.id)
        let customID = store.data.tables.last!.id
        store.deleteTable(id: customID)
        XCTAssertEqual(store.data.tables.count, 4)
        XCTAssertNil(store.data.currentTableID)
    }

    @MainActor
    func testRemoveStudentLinksOnStudentDeletion() throws {
        let store = try makeStore()
        let table = store.data.tables[0]
        var student = Student(); student.name = "王小明"; student.studentNumber = "1"
        store.addStudent(student)
        guard let linkField = table.linkField else { return XCTFail("记录表必须有关联学生字段") }
        _ = store.addRow(tableID: table.id, values: [
            linkField.id.uuidString: .link([student.id])
        ])
        // 删除学生后，记录表里的关联应清空而不是悬挂
        store.deleteStudent(id: student.id)
        let row = store.data.rows(tableID: table.id).first
        XCTAssertEqual(row?.values[linkField.id.uuidString]?.linkedStudentIDs ?? [], [])
    }

    @MainActor
    func testRemoveStudentLinksOnBatchStudentDeletion() throws {
        let store = try makeStore()
        let table = store.data.tables[0]
        var a = Student(); a.name = "王小明"; a.studentNumber = "1"
        var b = Student(); b.name = "李小红"; b.studentNumber = "2"
        store.addStudent(a)
        store.addStudent(b)
        guard let linkField = table.linkField else { return XCTFail("记录表必须有关联学生字段") }
        _ = store.addRow(tableID: table.id, values: [
            linkField.id.uuidString: .link([a.id, b.id])
        ])
        // 批量删除与单个删除同样要清理记录表里的关联
        store.deleteStudents(ids: [a.id, b.id])
        XCTAssertTrue(store.data.students.isEmpty)
        let row = store.data.rows(tableID: table.id).first
        XCTAssertEqual(row?.values[linkField.id.uuidString]?.linkedStudentIDs ?? [], [])
    }

    @MainActor
    func testLinkRowLookup() throws {
        let store = try makeStore()
        var student = Student(); student.name = "李小红"
        store.addStudent(student)
        let table = store.data.tables[0]
        guard let linkField = table.linkField else { return XCTFail() }
        _ = store.addRow(tableID: table.id, values: [linkField.id.uuidString: .link([student.id])])
        let linked = store.rowsLinking(toStudent: student.id)
        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(linked.first?.row.values[linkField.id.uuidString], .link([student.id]))
    }
}

extension ProjectData {
    /// 便捷读取某表的行（测试用）
    func rows(tableID: UUID) -> [DBRow] {
        table(id: tableID)?.rows ?? []
    }
}
