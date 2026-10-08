import XCTest
@testable import StudentDB

/// 通用表导入：非标准表格（乱序列/多余列/缺列/新建字段/类型转换）+ 查重覆盖（跳过/覆盖/保留）
@MainActor
final class TableImporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableImporterTests-\(UUID().uuidString)")
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
        for (name, number) in [("王小明", "2024001"), ("李小红", "2024002"), ("张小虎", "")] {
            var student = Student()
            student.name = name
            student.studentNumber = number
            store.addStudent(student)
        }
        return store
    }

    /// 建一张含各种字段类型的表，返回 (table, 各字段按名字取)
    private func makeConflictTable(_ store: ProjectStore) throws -> DBTable {
        try XCTUnwrap(store.addTable(name: "校园矛盾排查", kind: .record, fields: [
            CustomField(name: "学生", type: .linkStudents),
            CustomField(name: "矛盾发生时间", type: .dateTime),
            CustomField(name: "风险类型", type: .multiChoice(options: ["心理问题", "身体疾病"])),
            CustomField(name: "化解状态", type: .choice(options: ["未化解", "已化解"])),
            CustomField(name: "是否通知家长", type: .boolean),
            CustomField(name: "涉及金额", type: .number),
            CustomField(name: "关心措施", type: .address),
        ]))
    }

    private func field(_ table: DBTable, _ name: String) -> CustomField {
        table.fields.first { $0.name == name }!
    }

    private func rows(_ store: ProjectStore, _ tableID: UUID) -> [DBRow] {
        store.data.table(id: tableID)!.rows
    }

    // MARK: - 自动映射

    func testAutoGuessMapsExactFieldNamesOnly() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)
        // 非标准表头：只有「化解状态」与字段名完全一致；「学生姓名」「发生时间」属于非标准叫法
        let mapping = TableImporter.autoGuessMapping(
            header: ["学生姓名", "化解状态", "发生时间", "班主任备注"],
            fields: table.fields
        )
        XCTAssertEqual(mapping[1], .field(id: field(table, "化解状态").id))
        XCTAssertNil(mapping[0], "「学生姓名」与字段「学生」名不一致，不应自动映射")
        XCTAssertNil(mapping[2])
        XCTAssertNil(mapping[3])
    }

    // MARK: - 非标准表格导入（乱序列 + 多余列 + 缺列 + 新建字段）

    func testNonStandardImportWithMappingAndNewField() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)
        let studentField = field(table, "学生")

        // 列顺序与表字段完全不同；含多余列「班主任备注」；缺「关心措施」列；「排查人」是表里没有的字段
        let grid: [[String]] = [
            ["班主任备注", "学生姓名", "化解状态", "风险类型", "矛盾发生时间", "是否通知家长", "涉及金额", "排查人"],
            ["初一（3）班", "王小明", "平稳", "心理问题、多次信访", "2026-3-14 10:30", "√", "1,200", "陈老师"],
            ["", "2024002", "未化解", "身体疾病", "2026/3/15", "×", "300", "刘主任"],
        ]
        let mapping: [Int: TableImportTarget] = [
            0: .ignore,
            1: .field(id: studentField.id),
            2: .field(id: field(table, "化解状态").id),
            3: .field(id: field(table, "风险类型").id),
            4: .field(id: field(table, "矛盾发生时间").id),
            5: .field(id: field(table, "是否通知家长").id),
            6: .field(id: field(table, "涉及金额").id),
            7: .newField,
        ]

        // 新建字段先落地，再解析映射（与界面流程一致）
        TableImporter.createFieldsIfNeeded(grid: grid, header: grid[0], headerRowIndex: 0,
                                           mapping: mapping, store: store, tableID: table.id)
        let fields = store.data.table(id: table.id)!.fields
        let newField = try XCTUnwrap(fields.first { $0.name == "排查人" }, "「排查人」应被创建为新字段")
        XCTAssertEqual(newField.type, .text)
        let resolved = TableImporter.resolveNewFieldMappings(mapping, header: grid[0], fields: fields)
        XCTAssertEqual(resolved[7], .field(id: newField.id))

        let report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: resolved,
            keyField: studentField, store: store, tableID: table.id, updateExisting: false
        )
        XCTAssertEqual(report.imported, 2)
        XCTAssertTrue(report.skipped.isEmpty, "不应有任何提示：\(report.skipped)")

        let imported = rows(store, table.id)
        XCTAssertEqual(imported.count, 2)

        // 第 1 行：姓名匹配学生；多选拆分并自动补选项；日期时间解析；√ → true；带千分位数字
        let r1 = imported[0]
        XCTAssertEqual(r1.values[studentField.id.uuidString]?.linkedStudentIDs,
                       [store.data.students.first { $0.name == "王小明" }!.id])
        XCTAssertEqual(r1.values[field(table, "风险类型").id.uuidString]?.displayText, "心理问题、多次信访")
        XCTAssertEqual(r1.values[field(table, "化解状态").id.uuidString]?.displayText, "平稳")
        XCTAssertEqual(r1.values[field(table, "是否通知家长").id.uuidString]?.displayText, "是")
        XCTAssertEqual(r1.values[field(table, "涉及金额").id.uuidString]?.displayText, "1200")
        XCTAssertEqual(r1.values[newField.id.uuidString]?.displayText, "陈老师")
        XCTAssertNil(r1.values[field(table, "关心措施").id.uuidString], "文件里缺「关心措施」列，不应有值")

        var comps = DateComponents(); comps.year = 2026; comps.month = 3; comps.day = 14
        comps.hour = 10; comps.minute = 30
        let expected = Calendar.current.date(from: comps)!.timeIntervalSince1970
        XCTAssertEqual(r1.values[field(table, "矛盾发生时间").id.uuidString],
                       .date(Date(timeIntervalSince1970: expected)))

        // 第 2 行：学号同样能匹配学生；斜杠日期；× → false
        let r2 = imported[1]
        XCTAssertEqual(r2.values[studentField.id.uuidString]?.linkedStudentIDs,
                       [store.data.students.first { $0.name == "李小红" }!.id])
        XCTAssertEqual(r2.values[field(table, "是否通知家长").id.uuidString]?.displayText, "否")

        // 多选缺失选项「多次信访」已自动补进字段
        let updatedOptions = (store.data.table(id: table.id)!.fields
            .first { $0.id == field(table, "风险类型").id }!.type)
        if case .multiChoice(let options) = updatedOptions {
            XCTAssertTrue(options.contains("多次信访"))
        } else {
            XCTFail("风险类型应仍是多选字段")
        }
        // 单选新值「平稳」自动补进选项
        let statusType = store.data.table(id: table.id)!.fields
            .first { $0.id == field(table, "化解状态").id }!.type
        if case .choice(let options) = statusType {
            XCTAssertTrue(options.contains("平稳"))
        } else {
            XCTFail("化解状态应仍是单选字段")
        }
    }

    func testUnmatchedStudentAndBadValuesProduceNotes() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)
        let studentField = field(table, "学生")
        let amountField = field(table, "涉及金额")
        let dateField = field(table, "矛盾发生时间")
        let boolField = field(table, "是否通知家长")

        let grid: [[String]] = [
            ["学生", "涉及金额", "矛盾发生时间", "是否通知家长"],
            ["不存在的人", "三百元", "下周一", "也许"],
            ["王小明", "", "", ""],
        ]
        let mapping: [Int: TableImportTarget] = [
            0: .field(id: studentField.id),
            1: .field(id: amountField.id),
            2: .field(id: dateField.id),
            3: .field(id: boolField.id),
        ]
        let report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: studentField, store: store, tableID: table.id, updateExisting: false
        )
        // 两行都照常导入（行不因个别值失败而丢弃），但给出提示（字典遍历顺序不定，按内容断言）
        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(report.skipped.count, 4)
        XCTAssertTrue(report.skipped.contains { $0.contains("未匹配到学生") })
        XCTAssertTrue(report.skipped.contains { $0.contains("不是数字") })
        XCTAssertTrue(report.skipped.contains { $0.contains("无法识别为日期") })
        XCTAssertTrue(report.skipped.contains { $0.contains("是/否") })

        let r1 = rows(store, table.id)[0]
        XCTAssertNil(r1.values[studentField.id.uuidString], "匹配不到学生的行不写关联值")
        XCTAssertNil(r1.values[amountField.id.uuidString])
        XCTAssertNil(r1.values[dateField.id.uuidString])
        XCTAssertNil(r1.values[boolField.id.uuidString])
    }

    // MARK: - 查重与覆盖

    private func seedRow(_ store: ProjectStore, _ table: DBTable,
                         student: String, status: String, note: String) {
        let ids = TableImporter.matchStudents(student, store: store).ids
        _ = store.addRow(tableID: table.id, values: [
            field(table, "学生").id.uuidString: .link(ids),
            field(table, "化解状态").id.uuidString: .text(status),
            field(table, "关心措施").id.uuidString: .text(note),
        ])
    }

    func testDuplicateDefaultSkip() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)
        seedRow(store, table, student: "王小明", status: "未化解", note: "原有措施")

        let grid: [[String]] = [
            ["学生", "化解状态"],
            ["王小明", "已化解"],
            ["张小虎", "未化解"],
        ]
        let mapping: [Int: TableImportTarget] = [
            0: .field(id: field(table, "学生").id),
            1: .field(id: field(table, "化解状态").id),
        ]
        let keyField = field(table, "学生")
        // 预检：只有第 2 行（Excel 行号）与已有记录冲突
        let dups = TableImporter.detectDuplicateRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: keyField, store: store, tableID: table.id
        )
        XCTAssertEqual(dups.map(\.rowNumber), [2])
        XCTAssertEqual(dups[0].keyDisplay, "王小明")

        let report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: keyField, store: store, tableID: table.id, updateExisting: false
        )
        XCTAssertEqual(report.imported, 1, "只有张小虎是新行")
        XCTAssertEqual(report.skipped, ["第 2 行：关键字「王小明」已存在"])
        XCTAssertEqual(rows(store, table.id).count, 2, "已有行未被改动，只新增一行")
    }

    func testOverwriteUpdatesMappedFieldsOnly() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)
        seedRow(store, table, student: "王小明", status: "未化解", note: "原有措施")

        // 文件只有 学生 + 化解状态 两列（缺「关心措施」列）
        let grid: [[String]] = [
            ["学生", "化解状态"],
            ["王小明", "已化解"],
        ]
        let mapping: [Int: TableImportTarget] = [
            0: .field(id: field(table, "学生").id),
            1: .field(id: field(table, "化解状态").id),
        ]
        let report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: field(table, "学生"), store: store, tableID: table.id, updateExisting: true
        )
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.imported, 0)

        let row = rows(store, table.id)[0]
        XCTAssertEqual(row.values[field(table, "化解状态").id.uuidString]?.displayText, "已化解")
        XCTAssertEqual(row.values[field(table, "关心措施").id.uuidString]?.displayText, "原有措施",
                       "覆盖只改文件里出现的列，未映射字段保持原值")
    }

    func testPerRowPolicies() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)
        seedRow(store, table, student: "王小明", status: "未化解", note: "")
        seedRow(store, table, student: "李小红", status: "未化解", note: "")

        let grid: [[String]] = [
            ["学生", "化解状态"],
            ["王小明", "已化解"],   // 行 2 → 覆盖
            ["李小红", "已化解"],   // 行 3 → 保留两条
        ]
        let mapping: [Int: TableImportTarget] = [
            0: .field(id: field(table, "学生").id),
            1: .field(id: field(table, "化解状态").id),
        ]
        let report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: field(table, "学生"), store: store, tableID: table.id,
            updateExisting: false,
            duplicateActions: [2: .overwrite, 3: .keepBoth]
        )
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.imported, 1, "保留两条 = 新增一行")

        let all = rows(store, table.id)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].values[field(table, "化解状态").id.uuidString]?.displayText, "已化解", "王小明被覆盖")
        XCTAssertEqual(all[1].values[field(table, "化解状态").id.uuidString]?.displayText, "未化解", "李小红原行不动")
        XCTAssertEqual(all[2].values[field(table, "化解状态").id.uuidString]?.displayText, "已化解", "李小红新行")
    }

    func testInFileDuplicateSkipped() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)
        let grid: [[String]] = [
            ["学生", "化解状态"],
            ["王小明", "未化解"],
            ["王小明", "已化解"],
        ]
        let mapping: [Int: TableImportTarget] = [
            0: .field(id: field(table, "学生").id),
            1: .field(id: field(table, "化解状态").id),
        ]
        let report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: field(table, "学生"), store: store, tableID: table.id, updateExisting: false
        )
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.skipped, ["第 3 行：关键字「王小明」在文件中重复"])
    }

    func testLinkKeyMatchesOrderInsensitive() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)
        // 已有行关联 王小明、李小红；文件里写「李小红、王小明」顺序不同也应判重并覆盖
        seedRow(store, table, student: "王小明、李小红", status: "未化解", note: "")

        let grid: [[String]] = [
            ["学生", "化解状态"],
            ["李小红、王小明", "已化解"],
        ]
        let mapping: [Int: TableImportTarget] = [
            0: .field(id: field(table, "学生").id),
            1: .field(id: field(table, "化解状态").id),
        ]
        let dups = TableImporter.detectDuplicateRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: field(table, "学生"), store: store, tableID: table.id
        )
        XCTAssertEqual(dups.map(\.rowNumber), [2], "学生集合相同（顺序无关）应判为重复")

        let report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: field(table, "学生"), store: store, tableID: table.id, updateExisting: true
        )
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(rows(store, table.id).count, 1)
    }

    // MARK: - 真实 xlsx 文件全链路

    func testFullXLSXFilePath() throws {
        let store = try makeStore()
        let table = try makeConflictTable(store)

        // 模拟学校下发的非标准表格：列序乱、带多余列
        let file = tempDir.appendingPathComponent("非标准排查表.xlsx")
        try XLSX.write(sheets: [
            (name: "排查", rows: [
                [.text("化解状态"), .text("学生姓名"), .text("风险类型"), .text("备注")],
                [.text("未化解"), .text("王小明"), .text("心理问题"), .text("班主任填写")],
            ])
        ], to: file)

        let grid = try XLSX.readFirstSheet(from: file).rows
        XCTAssertEqual(grid.count, 2)
        let mapping: [Int: TableImportTarget] = [
            0: .field(id: field(table, "化解状态").id),
            1: .field(id: field(table, "学生").id),
            2: .field(id: field(table, "风险类型").id),
            3: .ignore,
        ]
        let report = TableImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping,
            keyField: field(table, "学生"), store: store, tableID: table.id, updateExisting: false
        )
        XCTAssertEqual(report.imported, 1)
        let row = rows(store, table.id)[0]
        XCTAssertEqual(row.values[field(table, "学生").id.uuidString]?.linkedStudentIDs.count, 1)
        XCTAssertEqual(row.values[field(table, "化解状态").id.uuidString]?.displayText, "未化解")
    }

    // MARK: - 值解析单元

    func testParseDateTextVariants() {
        var comps = DateComponents(); comps.year = 2026; comps.month = 3; comps.day = 14
        let expected = Calendar.current.date(from: comps)!.timeIntervalSince1970
        for text in ["2026-3-14", "2026/3/14", "2026.3.14", "2026年3月14日"] {
            let parsed = TableImporter.parseDateText(text)?.timeIntervalSince1970
            XCTAssertEqual(parsed, expected, "「\(text)」应解析为 2026-03-14")
        }
        XCTAssertNil(TableImporter.parseDateText("下周一"))
        // Excel 序列号
        XCTAssertNotNil(TableImporter.parseDateText("46000"))
    }

    func testParseBoolText() {
        XCTAssertEqual(TableImporter.parseBoolText("是"), true)
        XCTAssertEqual(TableImporter.parseBoolText("√"), true)
        XCTAssertEqual(TableImporter.parseBoolText("1"), true)
        XCTAssertEqual(TableImporter.parseBoolText("否"), false)
        XCTAssertEqual(TableImporter.parseBoolText("×"), false)
        XCTAssertEqual(TableImporter.parseBoolText("0"), false)
        XCTAssertNil(TableImporter.parseBoolText("也许"))
    }
}
