import XCTest
@testable import StudentDB

/// 字段类型任意切换：存量值随类型转换
@MainActor
final class FieldTypeChangeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldTypeChangeTests-\(UUID().uuidString)")
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
        for (name, number) in [("王小明", "2024001"), ("李小红", "2024002")] {
            var s = Student(); s.name = name; s.studentNumber = number
            store.addStudent(s)
        }
        return store
    }

    private func values(_ store: ProjectStore, _ table: DBTable, _ field: CustomField) -> [CustomValue?] {
        store.data.table(id: table.id)!.rows.map { $0.values[field.id.uuidString] }
    }

    func testTextToNumberDateBoolean() throws {
        let store = try makeStore()
        let table = store.addTable(name: "T", kind: .custom, fields: [CustomField(name: "F", type: .text)])
        let f = table.fields[0]
        let ming = store.data.students[0].id
        let hong = store.data.students[1].id
        // 文本 → 数字：能转的转，不能的清除
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("1200")])
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("三百")])
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .number)
        XCTAssertEqual(values(store, table, f), [.number(1200), nil])

        // 数字 → 文本
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .text)
        XCTAssertEqual(values(store, table, f)[0], .text("1200"))

        // 文本 → 日期（支持 2026-9-20 写法）
        store.updateRow(tableID: table.id, row: {
            var r = store.data.table(id: table.id)!.rows[0]
            r.values[f.id.uuidString] = .text("2026-9-20")
            return r
        }())
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .date)
        var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 20
        let target = Calendar.current.date(from: comps)!
        if case .date(let d)? = values(store, table, f)[0] {
            XCTAssertEqual(d.timeIntervalSince1970, target.timeIntervalSince1970)
        } else {
            XCTFail("应为日期值")
        }

        // 文本 → 是/否
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .text)
        store.updateRow(tableID: table.id, row: {
            var r = store.data.table(id: table.id)!.rows[0]
            r.values[f.id.uuidString] = .text("是")
            return r
        }())
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .boolean)
        XCTAssertEqual(values(store, table, f)[0], .boolean(true))
    }

    func testTextToChoiceMergesOptionsAndValues() throws {
        let store = try makeStore()
        let table = store.addTable(name: "T", kind: .custom, fields: [CustomField(name: "F", type: .text)])
        let f = table.fields[0]
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("团员")])
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("班干部")])

        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .choice(options: ["团员"]))
        // 现有取值并入选项；值保留
        let field = store.data.table(id: table.id)!.fields[0]
        guard case .choice(let options) = field.type else { return XCTFail("应为单选") }
        XCTAssertEqual(options, ["团员", "班干部"])
        XCTAssertEqual(values(store, table, f), [.text("团员"), .text("班干部")])

        // 单选 → 多选：值原样保留（顿号值拆并入选项）
        store.updateRow(tableID: table.id, row: {
            var r = store.data.table(id: table.id)!.rows[0]
            r.values[f.id.uuidString] = .text("团员、班干部")
            return r
        }())
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .multiChoice(options: []))
        let field2 = store.data.table(id: table.id)!.fields[0]
        guard case .multiChoice(let options2) = field2.type else { return XCTFail("应为多选") }
        XCTAssertEqual(Set(options2), Set(["团员", "班干部"]))
        XCTAssertEqual(values(store, table, f)[0], .text("团员、班干部"))
    }

    func testTextToLinkStudentsAndBack() throws {
        let store = try makeStore()
        let ming = store.data.students[0]
        let table = store.addTable(name: "T", kind: .custom, fields: [CustomField(name: "F", type: .text)])
        let f = table.fields[0]
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("王小明、2024002")])
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("查无此人")])

        // 文本 → 关联学生：姓名和学号都能匹配；匹配不上的清除
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .linkStudents)
        XCTAssertEqual(values(store, table, f)[0], .link([ming.id, store.data.students[1].id]))
        XCTAssertNil(values(store, table, f)[1])

        // 关联学生 → 文本：导出为姓名（顿号分隔）
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .text)
        XCTAssertEqual(values(store, table, f)[0], .text("王小明、李小红"))
    }

    func testAnythingToAttachmentClearsValues() throws {
        let store = try makeStore()
        let table = store.addTable(name: "T", kind: .custom, fields: [CustomField(name: "F", type: .text)])
        let f = table.fields[0]
        _ = store.addRow(tableID: table.id, values: [f.id.uuidString: .text("内容")])
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .attachment)
        XCTAssertNil(values(store, table, f)[0], "附件类型单元格不存值")

        // 附件 → 文本：无值
        store.changeTableFieldType(tableID: table.id, fieldID: f.id, to: .text)
        XCTAssertNil(values(store, table, f)[0])
    }

    func testStudentTableFieldTypeChange() throws {
        let store = try makeStore()
        _ = store.addField(name: "班级", type: .text)
        let f = store.data.fieldDefinitions[0]
        var a = store.data.students[0]
        a.customValues[f.id.uuidString] = .text("三（2）班")
        store.updateStudent(a)
        var b = store.data.students[1]
        b.customValues[f.id.uuidString] = .text("三（1）班")
        store.updateStudent(b)

        // 文本 → 单选：取值并入选项
        store.changeFieldType(fieldID: f.id, to: .choice(options: []))
        guard case .choice(let options)? = store.data.fieldDefinitions.first(where: { $0.id == f.id })?.type
        else { return XCTFail("应为单选") }
        XCTAssertEqual(Set(options), Set(["三（2）班", "三（1）班"]))

        // 单选 → 数字：转不了的清除
        store.changeFieldType(fieldID: f.id, to: .number)
        for student in store.data.students {
            XCTAssertNil(student.customValues[f.id.uuidString])
        }
    }
}

/// 内置列 → 自定义字段并改类型（值迁移、软删除、必备列保护）
@MainActor
final class BuiltinFieldTypeChangeTests: XCTestCase {

    func testConvertPhoneToChoiceAndBoardingToDate() throws {
        let store = ProjectStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin-\(UUID().uuidString).studentproj")
        try store.createProject(at: dir, name: "库")
        var a = Student(); a.name = "甲"; a.phone = "13812345678"; a.isBoarding = true
        var b = Student(); b.name = "乙"; b.phone = ""; b.isBoarding = false
        store.addStudent(a)
        store.addStudent(b)

        // 电话 → 单选：现有号码并入选项，值保留；内置电话列软删除
        store.convertBuiltinField(key: "phone", to: .choice(options: []))
        let field = try XCTUnwrap(store.data.fieldDefinitions.first { $0.name == "联系电话" })
        guard case .choice(let options) = field.type else { return XCTFail("应为单选") }
        XCTAssertTrue(options.contains("13812345678"), "现有电话应并入选项")
        XCTAssertEqual(store.data.students[0].customValues[field.id.uuidString], .text("13812345678"))
        XCTAssertTrue(store.data.deletedBuiltinFields.contains("phone"), "内置电话列应软删除")
        // 原值保留（恢复内置列时数据不丢）
        XCTAssertEqual(store.data.students[0].phone, "13812345678")

        // 住宿 → 日期：布尔转不了日期，清除；内置列软删除
        store.convertBuiltinField(key: "boarding", to: .date)
        let dateField = try XCTUnwrap(store.data.fieldDefinitions.first { $0.name == "住宿" })
        XCTAssertNil(store.data.students[0].customValues[dateField.id.uuidString], "布尔→日期应清除")
        XCTAssertTrue(store.data.deletedBuiltinFields.contains("boarding"))

        // 必备列不可转换
        store.convertBuiltinField(key: "name", to: .date)
        XCTAssertFalse(store.data.deletedBuiltinFields.contains("name"))
        XCTAssertTrue(store.data.fieldDefinitions.allSatisfy { $0.name != "姓名" })
    }
}
