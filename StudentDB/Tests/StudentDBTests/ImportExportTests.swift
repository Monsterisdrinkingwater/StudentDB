import XCTest
@testable import StudentDB

@MainActor
final class ImportExportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportExportTests-\(UUID().uuidString)")
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
        return store
    }

    // MARK: xlsx 读写往返

    func testXLSXRoundTrip() throws {
        let file = tempDir.appendingPathComponent("roundtrip.xlsx")
        try XLSX.write(
            sheets: [
                (name: "学生总表", rows: [
                    [.text("姓名"), .text("学号"), .text("是否住宿")],
                    [.text("王小明"), .text("2024001"), .text("住宿")],
                    [.text("李,小红"), .text("2024002"), .text("走读")],
                    [.text("含<引号>\"的\"&名字"), .number(3.5), .text("")],
                    [.text("三（2）班"), .text("000123"), .text("是")]
                ]),
                (name: "监护人明细", rows: [
                    [.text("学生"), .text("电话")],
                    [.text("王小明"), .text("13812345678")]
                ])
            ],
            to: file
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let sheets = try XLSX.readAllSheets(from: file)
        XCTAssertEqual(sheets.count, 2)
        XCTAssertEqual(sheets[0].name, "学生总表")
        XCTAssertEqual(sheets[0].rows.count, 5)
        XCTAssertEqual(sheets[0].rows[1], ["王小明", "2024001", "住宿"])
        XCTAssertEqual(sheets[0].rows[2], ["李,小红", "2024002", "走读"])
        XCTAssertEqual(sheets[0].rows[3][0], "含<引号>\"的\"&名字")
        XCTAssertEqual(sheets[0].rows[3][1], "3.5")
        XCTAssertEqual(sheets[1].name, "监护人明细")
        XCTAssertEqual(sheets[1].rows[1], ["王小明", "13812345678"])
    }

    func testColumnLetters() {
        XCTAssertEqual(XLSX.columnLetter(0), "A")
        XCTAssertEqual(XLSX.columnLetter(25), "Z")
        XCTAssertEqual(XLSX.columnLetter(26), "AA")
        XCTAssertEqual(XLSX.columnLetter(27), "AB")
        XCTAssertEqual(XLSX.columnIndex("A"), 0)
        XCTAssertEqual(XLSX.columnIndex("AA"), 26)
        XCTAssertEqual(XLSX.columnIndex("AB"), 27)
    }

    // MARK: 自动识别列映射

    func testAutoGuessMapping() {
        let fields = [CustomField(name: "班级", type: .text)]
        let header = ["姓名", "学号", "是否住宿", "家长姓名", "家长电话", "住宿地址", "派出所", "班级", "备注"]
        let mapping = StudentImporter.autoGuessMapping(header: header, fields: fields)

        XCTAssertEqual(mapping[0], .name)
        XCTAssertEqual(mapping[1], .studentNumber)
        XCTAssertEqual(mapping[2], .isBoarding)
        XCTAssertEqual(mapping[3], .guardian(slot: 0, part: .name))
        XCTAssertEqual(mapping[4], .guardian(slot: 0, part: .phone))
        XCTAssertEqual(mapping[5], .boardingAddress)
        XCTAssertEqual(mapping[6], .policeStation)
        XCTAssertEqual(mapping[7], .customField(id: fields[0].id))
        XCTAssertNil(mapping[8])
    }

    // MARK: 完整导入流程

    func testImportStudents() throws {
        let store = try makeStore()
        store.addField(name: "班级", type: .text)

        let grid: [[String]] = [
            ["姓名", "学号", "住宿情况", "监护人电话", "班级", "其他"],
            ["王小明", "2024001", "住宿", "13800000001", "三（2）班", "忽略我"],
            ["李小红", "2024002", "走读", "", "三（2）班", ""],
            ["王小明", "2024001", "走读", "", "", ""],                       // 文件内重复（学号）→ 跳过
            ["", "", "", "", "", ""],                                        // 空行 → 静默
            ["张三丰", "", "住宿", "", "", ""]                                // 学号选填 → 正常导入
        ]
        var mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: store.data.fieldDefinitions)
        mapping[3] = .guardian(slot: 0, part: .phone)
        mapping[4] = .customField(id: store.data.fieldDefinitions[0].id)
        mapping[5] = .ignore

        let report = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store, updateExisting: false
        )

        XCTAssertEqual(report.imported, 3)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped.count, 1)

        XCTAssertEqual(store.data.students.count, 3)
        let wang = store.data.students.first { $0.name == "王小明" }
        XCTAssertEqual(wang?.isBoarding, true)
        XCTAssertEqual(wang?.guardians.first?.phone, "13800000001")
        XCTAssertEqual(wang?.guardians.first?.name, "")
        let li = store.data.students.first { $0.name == "李小红" }
        XCTAssertEqual(li?.isBoarding, false)
        let zhang = store.data.students.first { $0.name == "张三丰" }
        XCTAssertEqual(zhang?.studentNumber, "")
        XCTAssertEqual(zhang?.isBoarding, true)
    }

    // MARK: 学号选填（姓名是唯一必填项）

    func testImportWithoutStudentNumberColumn() throws {
        let store = try makeStore()
        let grid: [[String]] = [
            ["姓名", "是否住宿"],
            ["王小明", "住宿"],
            ["李小红", "走读"],
            ["王小明", "走读"]        // 无学号列：文件内按姓名查重 → 跳过
        ]
        let mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: [])
        let report = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store, updateExisting: false
        )
        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(report.skipped.first?.contains("姓名 王小明 在文件中重复") ?? false)
        XCTAssertEqual(store.data.students.count, 2)
        XCTAssertNil(store.data.students.first { $0.name == "王小明" && $0.isBoarding == false })
    }

    func testImportUpdateByNameKeepsExistingNumber() throws {
        let store = try makeStore()
        var existing = Student()
        existing.name = "王小明"
        existing.studentNumber = "2024001"
        store.addStudent(existing)

        let grid: [[String]] = [
            ["姓名", "联系电话"],
            ["王小明", "13800000001"]
        ]
        let mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: [])
        let report = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store, updateExisting: true
        )
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(store.data.students.count, 1)
        // 无学号列的更新不应清掉已有学号
        XCTAssertEqual(store.data.students.first?.studentNumber, "2024001")
        XCTAssertEqual(store.data.students.first?.phone, "13800000001")
    }

    // MARK: 新建字段导入

    func testImportCreatesNewFields() throws {
        let store = try makeStore()
        let grid: [[String]] = [
            ["姓名", "学号", "民族"],
            ["王小明", "2024001", "汉族"]
        ]
        var mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: [])
        mapping[2] = .newField

        StudentImporter.createFieldsIfNeeded(
            grid: grid, header: grid[0], headerRowIndex: 0, mapping: mapping, store: store
        )
        XCTAssertEqual(store.data.fieldDefinitions.count, 1)
        XCTAssertEqual(store.data.fieldDefinitions.first?.name, "民族")

        guard let field = store.data.fieldDefinitions.first else { return XCTFail() }
        mapping[2] = .customField(id: field.id)
        _ = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store, updateExisting: false
        )
        XCTAssertEqual(store.data.students.first?.customValues[field.id.uuidString], .text("汉族"))
    }

    // MARK: 更新已有学生

    func testImportUpdateExisting() throws {
        let store = try makeStore()
        var existing = Student()
        existing.name = "王小明"
        existing.studentNumber = "2024001"
        existing.phone = "旧号码"
        existing.isBoarding = false
        store.addStudent(existing)

        let grid: [[String]] = [
            ["姓名", "学号", "是否住宿", "联系电话"],
            ["王小明", "2024001", "住宿", "13911112222"]
        ]
        let mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: [])

        // 不更新 → 跳过
        let skipped = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store, updateExisting: false
        )
        XCTAssertEqual(skipped.imported, 0)
        XCTAssertEqual(skipped.skipped.count, 1)

        // 更新 → 覆盖
        let updated = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store, updateExisting: true
        )
        XCTAssertEqual(updated.updated, 1)
        let student = store.data.students.first { $0.studentNumber == "2024001" }
        XCTAssertEqual(student?.isBoarding, true)
        XCTAssertEqual(student?.phone, "13911112222")
        XCTAssertEqual(store.data.students.count, 1)
    }

    // MARK: Excel 全量导出

    func testExcelExportAll() throws {
        let store = try makeStore()
        store.addField(name: "班级", type: .text)
        let fieldID = store.data.fieldDefinitions[0].id

        var student = Student()
        student.name = "王小明"
        student.studentNumber = "2024001"
        student.isBoarding = true
        student.phone = "13812345678"
        student.boardingAddress = "幸福路12号"
        student.policeStation = "城南派出所"
        student.customValues[fieldID.uuidString] = .text("三（2）班")
        student.guardians = [Guardian(name: "王建国", relation: "父", phone: "13998765432")]
        var record = CareRecord()
        record.type = "家访"
        record.content = "与家长面谈"
        student.records = [record]
        store.addStudent(student)
        try store.saveNow()

        let file = tempDir.appendingPathComponent("导出测试.xlsx")
        try ExcelExporter.exportAll(data: store.data, to: file)

        let sheets = try XLSX.readAllSheets(from: file)
        // 学生三张 + 项目默认的 4 张记录表（空表也导出表头）
        XCTAssertEqual(sheets.count, 7)
        XCTAssertEqual(sheets.map { $0.name },
                       ["学生总表", "监护人明细", "记录明细",
                        "关心关爱记录", "谈话记录", "家校沟通记录", "违纪记录"])

        let roster = sheets[0].rows
        XCTAssertEqual(roster[0].prefix(6), ["姓名", "学号", "是否住宿", "联系电话", "住宿地址", "对应派出所"])
        // 监护人扁平列（默认 1 组）
        XCTAssertEqual(roster[0][6...8], ["监护人1姓名", "监护人1关系", "监护人1电话"])
        XCTAssertTrue(roster[0].contains("班级"))
        let wangRow = roster[1]
        XCTAssertEqual(wangRow[0], "王小明")
        XCTAssertTrue(wangRow.contains("住宿"))
        XCTAssertTrue(wangRow.contains("三（2）班"))
        // 监护人槽位数据
        XCTAssertEqual(wangRow[6], "王建国")
        XCTAssertEqual(wangRow[7], "父")
        XCTAssertEqual(wangRow[8], "13998765432")

        XCTAssertEqual(sheets[1].rows.count, 2) // 表头 + 1 位监护人
        XCTAssertEqual(sheets[2].rows.count, 2) // 表头 + 1 条记录
        XCTAssertEqual(sheets[2].rows[1][3], "家访")
    }

    // MARK: 按选择导出

    func testExcelExportSelection() throws {
        let store = try makeStore()
        store.addField(name: "班级", type: .text)
        let fieldID = store.data.fieldDefinitions[0].id

        var student = Student()
        student.name = "王小明"
        student.studentNumber = "2024001"
        student.isBoarding = true
        student.customValues[fieldID.uuidString] = .text("三（2）班")
        student.guardians = [Guardian(name: "王建国", relation: "父", phone: "13998765432")]
        var record = CareRecord()
        record.type = "家访"
        record.content = "与家长面谈"
        student.records = [record]
        store.addStudent(student)

        // 只导出记录
        var recordsOnly = ExportSelection()
        recordsOnly.includeRoster = false
        recordsOnly.includeGuardians = false
        recordsOnly.includeRecords = true
        recordsOnly.recordTypes = ["家访"]
        let file1 = tempDir.appendingPathComponent("仅记录.xlsx")
        try ExcelExporter.exportAll(data: store.data, to: file1, selection: recordsOnly)
        XCTAssertEqual(try XLSX.readAllSheets(from: file1).map { $0.name }, ["记录明细"])

        // 类别过滤：只选"违纪记录"时，"家访"记录不导出
        var violationOnly = ExportSelection()
        violationOnly.includeRoster = false
        violationOnly.includeGuardians = false
        violationOnly.includeRecords = true
        violationOnly.recordTypes = ["违纪记录"]
        let file1b = tempDir.appendingPathComponent("仅违纪.xlsx")
        try ExcelExporter.exportAll(data: store.data, to: file1b, selection: violationOnly)
        XCTAssertEqual(try XLSX.readAllSheets(from: file1b).first?.rows.count, 1) // 仅表头

        // 总表不含任何自定义字段，其余全导（数据表不勾选，专注学生部分）
        var noFields = ExportSelection.all(data: store.data)
        noFields.customFieldIDs = []
        noFields.tableIDs = []
        let file2 = tempDir.appendingPathComponent("无自定义列.xlsx")
        try ExcelExporter.exportAll(data: store.data, to: file2, selection: noFields)
        let sheets = try XLSX.readAllSheets(from: file2)
        XCTAssertEqual(sheets.map { $0.name }, ["学生总表", "监护人明细", "记录明细"])
        XCTAssertFalse(sheets[0].rows[0].contains("班级"))
        XCTAssertTrue(sheets[0].rows[0].contains("监护人1姓名"))

        // 什么都不选应报错
        let file3 = tempDir.appendingPathComponent("空选择.xlsx")
        XCTAssertThrowsError(try ExcelExporter.exportAll(
            data: store.data, to: file3,
            selection: ExportSelection(includeRoster: false, includeGuardians: false,
                                       includeRecords: false, customFieldIDs: [])
        ))
    }

    func testCSVExportFieldSelection() throws {
        let store = try makeStore()
        store.addField(name: "班级", type: .text)
        let fieldID = store.data.fieldDefinitions[0].id
        var student = Student()
        student.name = "王小明"
        student.studentNumber = "2024001"
        student.customValues[fieldID.uuidString] = .text("三（2）班")
        store.addStudent(student)

        // 全部字段
        let all = CSVExporter.exportCSV(data: store.data, selectedFieldIDs: [fieldID])
        XCTAssertTrue(all.contains("班级"))
        XCTAssertTrue(all.contains("三（2）班"))

        // 不含自定义字段
        let none = CSVExporter.exportCSV(data: store.data, selectedFieldIDs: [])
        XCTAssertFalse(none.contains("班级"))
        XCTAssertTrue(none.contains("姓名"))
    }

    // MARK: CSV 解析

    func testCSVParser() {
        let csv = "姓名,学号,备注\r\n\"王,小明\",\"2024001\",\"多行\n备注\"\r\n李小红,2024002,\"引\"\"号\"\"\"\r\n"
        let rows = CSVParser.parse(data: Data(csv.utf8))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["姓名", "学号", "备注"])
        XCTAssertEqual(rows[1], ["王,小明", "2024001", "多行\n备注"])
        XCTAssertEqual(rows[2], ["李小红", "2024002", "引\"号\""])
    }

    func testCSVGBKDecode() {
        // “姓名,王小明” 的 GBK 编码字节
        let bytes: [UInt8] = [0xD0, 0xD5, 0xC3, 0xFB, 0x2C, 0xCD, 0xF5, 0xD0, 0xA1, 0xC3, 0xF7]
        let rows = CSVParser.parse(data: Data(bytes))
        XCTAssertEqual(rows.first?.first, "姓名")
        XCTAssertEqual(rows.first?.last, "王小明")
    }
}

// MARK: 选项自动追加（导入不存在的词条）

final class ImportChoiceOptionTests: XCTestCase {

    @MainActor
    private func makeStoreWithChoiceField(options: [String]) throws -> (ProjectStore, CustomField) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("导入测试-\(UUID().uuidString).studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "导入测试")
        var field = CustomField(name: "民族", type: .choice(options: options))
        field.id = UUID()
        store.addField(name: field.name, type: field.type)
        field = store.data.fieldDefinitions[0]
        return (store, field)
    }

    @MainActor
    func testImportAutoAppendsMissingChoiceOption() throws {
        let (store, field) = try makeStoreWithChoiceField(options: ["汉族"])
        let grid = [["姓名", "民族"], ["王小明", "回族"]]
        var mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: store.data.fieldDefinitions)
        mapping[1] = .customField(id: field.id)

        let report = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store, updateExisting: false
        )
        XCTAssertEqual(report.imported, 1)
        // 选项自动追加
        XCTAssertEqual(store.data.fieldDefinitions[0].type,
                       .choice(options: ["汉族", "回族"]))
        // 值正常写入
        XCTAssertEqual(store.data.students.first?.customValues[field.id.uuidString], .text("回族"))
    }

    @MainActor
    func testImportAutoAppendsMissingMultiChoiceOptions() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("导入测试-\(UUID().uuidString).studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "导入测试")
        store.addField(name: "兴趣", type: .multiChoice(options: ["阅读"]))
        let field = store.data.fieldDefinitions[0]

        let grid = [["姓名", "兴趣"], ["王小明", "阅读、游泳、绘画"]]
        var mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: store.data.fieldDefinitions)
        mapping[1] = .customField(id: field.id)

        _ = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store, updateExisting: false
        )
        XCTAssertEqual(store.data.fieldDefinitions[0].type,
                       .multiChoice(options: ["阅读", "游泳", "绘画"]))
        XCTAssertEqual(store.data.students.first?.customValues[field.id.uuidString],
                       .text("阅读、游泳、绘画"))
    }
}

// MARK: 重复行处理策略（覆盖 / 保留两条 / 跳过）

final class ImportDuplicatePolicyTests: XCTestCase {

    @MainActor
    private func makeStoreWithExisting() throws -> ProjectStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("导入测试-\(UUID().uuidString).studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "导入测试")
        var existing = Student()
        existing.name = "王小明"
        existing.studentNumber = "2024001"
        store.addStudent(existing)
        return store
    }

    @MainActor
    func testDetectDuplicateRowsMatchesImportNumbering() throws {
        let store = try makeStoreWithExisting()
        let grid = [
            ["姓名", "学号"],
            ["李小红", "2024002"],   // 行 2：新学生
            ["王小明", "2024001"]    // 行 3：与已有学号重复
        ]
        let mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: [])
        let conflicts = StudentImporter.detectDuplicateRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store
        )
        XCTAssertEqual(conflicts.map { $0.rowNumber }, [3])
        XCTAssertEqual(conflicts.first?.keyDescription, "学号 2024001")
    }

    @MainActor
    func testDuplicatePolicyOverwrite() throws {
        let store = try makeStoreWithExisting()
        let grid = [["姓名", "联系电话"], ["王小明", "13800000001"]]
        let mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: [])
        let report = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store,
            updateExisting: false, duplicateActions: [2: .overwrite]
        )
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(store.data.students.count, 1)
        XCTAssertEqual(store.data.students.first?.phone, "13800000001")
    }

    @MainActor
    func testDuplicatePolicyKeepBoth() throws {
        let store = try makeStoreWithExisting()
        let grid = [["姓名", "学号"], ["王小明", "2024001"]]
        let mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: [])
        let report = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store,
            updateExisting: false, duplicateActions: [2: .keepBoth]
        )
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(store.data.students.count, 2)
    }

    @MainActor
    func testDuplicatePolicySkip() throws {
        let store = try makeStoreWithExisting()
        let grid = [["姓名", "学号"], ["王小明", "2024001"]]
        let mapping = StudentImporter.autoGuessMapping(header: grid[0], fields: [])
        let report = StudentImporter.importRows(
            grid: grid, headerRowIndex: 0, mapping: mapping, store: store,
            updateExisting: true, duplicateActions: [2: .skip]
        )
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(store.data.students.count, 1)
    }
}
