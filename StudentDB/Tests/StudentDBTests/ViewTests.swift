import XCTest
@testable import StudentDB

@MainActor
final class ViewTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    private func makeStudent(name: String, number: String, boarding: Bool, station: String) -> Student {
        var s = Student()
        s.name = name
        s.studentNumber = number
        s.isBoarding = boarding
        s.policeStation = station
        return s
    }

    private func sampleStudents() -> [Student] {
        [
            makeStudent(name: "王小明", number: "2024002", boarding: true, station: "城南派出所"),
            makeStudent(name: "李小红", number: "2024001", boarding: false, station: "城北派出所"),
            makeStudent(name: "张小虎", number: "2024003", boarding: true, station: "城南派出所")
        ]
    }

    // MARK: 筛选与排序

    func testViewFilterAndSort() {
        let students = sampleStudents()

        // 按住宿筛选 + 姓名升序
        var view = ListView(name: "住宿生")
        view.condition = .boarding(true)
        var result = StudentQuery.apply(view: view, students: students, fields: [])
        XCTAssertEqual(result.map { $0.name }, ["张小虎", "王小明"])

        // 学号升序（全部）
        view.condition = .all
        view.sortKey = .studentNumber
        result = StudentQuery.apply(view: view, students: students, fields: [])
        XCTAssertEqual(result.map { $0.name }, ["李小红", "王小明", "张小虎"])

        // 降序
        view.sortAscending = false
        result = StudentQuery.apply(view: view, students: students, fields: [])
        XCTAssertEqual(result.map { $0.name }, ["张小虎", "王小明", "李小红"])

        // 派出所筛选
        view.condition = .policeStation("城南派出所")
        view.sortKey = .name
        view.sortAscending = true
        result = StudentQuery.apply(view: view, students: students, fields: [])
        XCTAssertEqual(result.map { $0.name }.sorted(), ["张小虎", "王小明"])

        // 关键字筛选（命中监护人之外的字段：派出所文字）
        view.condition = .all
        view.keyword = "城北"
        result = StudentQuery.apply(view: view, students: students, fields: [])
        XCTAssertEqual(result.map { $0.name }, ["李小红"])

        // 派出所去重列表
        XCTAssertEqual(StudentQuery.policeStations(in: students), ["城北派出所", "城南派出所"])
    }

    // MARK: 快捷筛选标签

    func testQuickFilters() throws {
        let url = tempDir.appendingPathComponent("快捷筛选.studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "快捷筛选")

        // 默认标签：住宿、走读
        XCTAssertEqual(store.data.quickFilters.map { $0.name }, ["住宿", "走读"])
        store.addStudent(makeStudent(name: "王小明", number: "2024001", boarding: true, station: "城南派出所"))
        store.addStudent(makeStudent(name: "李小红", number: "2024002", boarding: false, station: "城北派出所"))

        // 应用住宿标签
        let boardingTab = store.data.quickFilters.first { $0.name == "住宿" }!
        var view = store.currentView
        view.condition = boardingTab.condition
        let result = StudentQuery.apply(view: view, students: store.data.students, fields: [])
        XCTAssertEqual(result.map { $0.name }, ["王小明"])

        // 添加自定义字段标签
        store.addField(name: "班级", type: .text)
        let fieldID = store.data.fieldDefinitions[0].id
        var student = makeStudent(name: "张小虎", number: "2024003", boarding: true, station: "城南派出所")
        student.customValues[fieldID.uuidString] = .text("三（2）班")
        store.addStudent(student)

        store.addQuickFilter(QuickFilter(name: "三（2）班", condition: .customField(fieldID: fieldID, value: "三（2）班")))
        view.condition = .customField(fieldID: fieldID, value: "三（2）班")
        let classResult = StudentQuery.apply(view: view, students: store.data.students, fields: store.data.fieldDefinitions)
        XCTAssertEqual(classResult.map { $0.name }, ["张小虎"])

        // 重名标签不重复添加；删除标签
        store.addQuickFilter(QuickFilter(name: "三（2）班", condition: .all))
        XCTAssertEqual(store.data.quickFilters.count, 3)
        let added = store.data.quickFilters.first { $0.name == "三（2）班" }!
        store.deleteQuickFilter(id: added.id)
        XCTAssertEqual(store.data.quickFilters.count, 2)

        // 持久化
        try store.saveNow()
        let reopened = ProjectStore()
        try reopened.openProject(at: url)
        XCTAssertEqual(reopened.data.quickFilters.map { $0.name }, ["住宿", "走读"])

        // 删除字段时清理引用它的标签
        reopened.deleteField(id: fieldID)
        XCTAssertTrue(reopened.data.quickFilters.allSatisfy {
            if case .customField = $0.condition { return false }
            return true
        })
    }

    // MARK: 单视图语义（筛选不持久化；排序/布局保留）

    func testViewCRUDAndPersistence() throws {
        let url = tempDir.appendingPathComponent("视图测试.studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "视图测试")
        for s in sampleStudents() {
            store.addStudent(s)
        }

        // 默认单个视图，无新建/删除入口
        XCTAssertEqual(store.data.views.count, 1)
        XCTAssertEqual(store.currentView.name, "全部学生")

        // 会话内设置筛选三项 + 个性化设置（排序/布局）
        var view = store.currentView
        view.condition = .boarding(true)
        view.keyword = "王"
        view.columnFilters["name"] = ColumnFilter(searchText: "王")
        view.sortKey = .studentNumber
        view.sortAscending = false
        view.layout = .table
        store.updateView(view)
        XCTAssertEqual(StudentQuery.apply(view: store.currentView,
                                          students: store.data.students, fields: []).count, 1)

        // 保存重开：视图仍收敛为 1 个；筛选三项为空（显示全部学生），排序/布局保留
        try store.saveNow()
        let reopened = ProjectStore()
        try reopened.openProject(at: url)
        XCTAssertEqual(reopened.data.views.count, 1)
        XCTAssertEqual(reopened.currentView.condition, .all)
        XCTAssertEqual(reopened.currentView.keyword, "")
        XCTAssertTrue(reopened.currentView.columnFilters.isEmpty)
        XCTAssertEqual(reopened.currentView.sortKey, .studentNumber)
        XCTAssertFalse(reopened.currentView.sortAscending)
        XCTAssertEqual(reopened.currentView.layout, .table)
        let all = StudentQuery.apply(view: reopened.currentView,
                                     students: reopened.data.students, fields: [])
        XCTAssertEqual(all.count, 3, "重开后应显示全部学生")
    }

    /// 旧项目的多视图数据：打开时收敛为单个（保留 currentViewID 指向的，含其排序/布局/列显隐）
    func testOldMultiViewsCollapseToSingle() throws {
        let url = tempDir.appendingPathComponent("多视图收敛.studentproj")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        var data = ProjectData()
        let first = ListView(name: "全部学生")
        var second = ListView(name: "住宿生")
        second.sortKey = .studentNumber
        second.layout = .table
        data.views = [first, second]
        data.currentViewID = second.id

        var table = DBTable.recordTable(name: "关心关爱记录", recordTypes: ProjectData.defaultRecordTypes)
        let tableFirst = ListView(name: "全部")
        var tableSecond = ListView(name: "备用")
        tableSecond.hiddenColumnIDs = [table.fields[0].id.uuidString]
        table.views = [tableFirst, tableSecond]
        table.currentViewID = tableSecond.id
        data.tables = [table]
        data.recordMigrationDone = true

        try ProjectStore.encoder.encode(data)
            .write(to: url.appendingPathComponent(ProjectStore.dataFileName))

        let store = ProjectStore()
        try store.openProject(at: url)

        // 学生表视图收敛：保留 currentViewID 指向的那个，其余丢弃
        XCTAssertEqual(store.data.views.count, 1)
        XCTAssertEqual(store.currentView.id, second.id)
        XCTAssertEqual(store.currentView.sortKey, .studentNumber)
        XCTAssertEqual(store.currentView.layout, .table)
        XCTAssertEqual(store.currentView.keyword, "")
        XCTAssertEqual(store.currentView.condition, .all)
        XCTAssertTrue(store.currentView.columnFilters.isEmpty)

        // 通用表视图同样收敛，列显隐保留
        XCTAssertEqual(store.data.tables[0].views.count, 1)
        XCTAssertEqual(store.data.tables[0].currentViewID, tableSecond.id)
        XCTAssertEqual(store.data.tables[0].currentView.hiddenColumnIDs, tableSecond.hiddenColumnIDs)
    }

    /// 恢复备份与打开项目走同一套单视图收敛：旧版多视图备份恢复后不复活、保留 currentViewID 指向的视图
    func testRestoreBackupCollapsesMultiViews() throws {
        let url = tempDir.appendingPathComponent("恢复备份.studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "恢复备份")

        // 手工构造一份旧版多视图备份文件并恢复
        var data = ProjectData()
        let first = ListView(name: "全部学生")
        var second = ListView(name: "住宿生")
        second.sortKey = .studentNumber
        second.layout = .table
        data.views = [first, second]
        data.currentViewID = second.id
        data.recordMigrationDone = true
        let backupURL = url.appendingPathComponent(ProjectStore.backupFolderName, isDirectory: true)
            .appendingPathComponent("students-old.json")
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectStore.encoder.encode(data).write(to: backupURL)

        try store.restore(from: BackupInfo(url: backupURL, modifiedAt: Date(), size: 1))

        XCTAssertEqual(store.data.views.count, 1, "恢复备份后多视图不应复活")
        XCTAssertEqual(store.currentView.id, second.id, "应保留 currentViewID 指向的视图")
        XCTAssertEqual(store.currentView.sortKey, .studentNumber)
        XCTAssertEqual(store.currentView.layout, .table)
        XCTAssertEqual(store.currentView.condition, .all)
        XCTAssertEqual(store.currentView.keyword, "")
        XCTAssertTrue(store.currentView.columnFilters.isEmpty)

        // 收敛结果已写回 students.json（重启后保持单视图）
        let raw = try Data(contentsOf: url.appendingPathComponent(ProjectStore.dataFileName))
        let saved = try ProjectStore.decoder.decode(ProjectData.self, from: raw)
        XCTAssertEqual(saved.views.count, 1)
        XCTAssertEqual(saved.views.first?.id, second.id)
    }

    // MARK: 视图 layout 字段兼容

    func testViewLayoutMigration() throws {
        // 旧视图 JSON 没有 layout 字段 → 默认详情
        let json = """
        {"id": "622E5632-340E-482D-BA5B-54FF8CC4CBDE", "name": "旧视图"}
        """
        let decoded = try JSONDecoder().decode(ListView.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.layout, .detail)
        XCTAssertEqual(decoded.name, "旧视图")

        // 表格视图往返
        var table = ListView(name: "表格视图")
        table.layout = .table
        let raw = try JSONEncoder().encode(table)
        let roundTrip = try JSONDecoder().decode(ListView.self, from: raw)
        XCTAssertEqual(roundTrip, table)
    }

    // MARK: 表格列规格（显隐与编辑）

    func testColumnSpecsAndEditing() {
        let fields = [CustomField(name: "班级", type: .text)]
        let hidden: Set<String> = [StudentTableField.phone.rawValue, fields[0].id.uuidString]

        // 隐藏列（联系电话、班级）被过滤；监护人列按槽位展开
        let columns = StudentColumnSpec.columns(fields: fields, hidden: hidden, guardianSlots: 1)
        XCTAssertEqual(columns.map { $0.title },
                       ["姓名", "学号", "住宿", "住宿地址", "派出所", "记录",
                        "监护人1姓名", "监护人1关系", "监护人1电话"])

        // 全部列（含隐藏）供显隐菜单使用
        let all = StudentColumnSpec.allColumns(fields: fields, guardianSlots: 2)
        XCTAssertEqual(all.count, StudentTableField.allCases.count + 6 + 1)

        // 单元格编辑写入
        var s = Student()
        s.name = "王小明"
        s.isBoarding = false

        let nameSpec = all.first { $0.title == "姓名" }!
        XCTAssertEqual(nameSpec.applying(CellEdit.text("王二明"), to: s).name, "王二明")
        // 姓名 NOT NULL：清空被拒绝
        XCTAssertEqual(nameSpec.applying(CellEdit.text("  "), to: s).name, "王小明")

        let boardingSpec = all.first { $0.title == "住宿" }!
        XCTAssertTrue(boardingSpec.applying(.boolean(true), to: s).isBoarding)
        XCTAssertFalse(boardingSpec.applying(.boolean(false), to: s).isBoarding)
        XCTAssertFalse(boardingSpec.applying(.text("随便输入"), to: s).isBoarding) // 无法识别不改动

        // 记录列只读
        let recordSpec = all.first { $0.title == "记录" }!
        XCTAssertEqual(recordSpec.cellKind, .readonly)
        XCTAssertEqual(recordSpec.applying(.text("改不动"), to: s), s)

        // 监护人槽位列：写入姓名/关系/电话
        let gSpecs = StudentColumnSpec.guardianColumns(slot: 2)
        var gStudent = Student()
        for spec in gSpecs {
            let text = [ "李大伟", "父", "13811112222" ][gSpecs.firstIndex(of: spec) ?? 0]
            gStudent = spec.applying(CellEdit.text(text), to: gStudent)
        }
        XCTAssertEqual(gStudent.guardians.count, 2)
        XCTAssertEqual(gStudent.guardians[1].name, "李大伟")
        XCTAssertEqual(gStudent.guardians[1].relation, "父")
        XCTAssertEqual(gStudent.guardians[1].phone, "13811112222")

        // 监护人电话列：非法格式不写入
        let gPhoneSpec = gSpecs.first { $0.guardianPart == .phone }!
        XCTAssertEqual(gPhoneSpec.applying(CellEdit.text("abc"), to: gStudent).guardians[1].phone,
                       "13811112222")

        // 自定义字段：数字列非法输入不改动
        let numberField = CustomField(name: "身高", type: .number)
        let heightSpec = StudentColumnSpec(id: numberField.id.uuidString, title: "身高",
                                           field: nil, customField: numberField)
        let edited = heightSpec.applying(.text("172.5"), to: s)
        XCTAssertEqual(edited.customValues[numberField.id.uuidString], .number(172.5))
        XCTAssertEqual(heightSpec.applying(.text("abc"), to: s), s)

        // 显示文本
        XCTAssertEqual(heightSpec.displayText(of: edited), "172.5")
        XCTAssertEqual(heightSpec.displayText(of: s), "")
    }

    func testHiddenColumnsMigration() throws {
        let json = """
        {"id": "622E5632-340E-482D-BA5B-54FF8CC4CBDE", "name": "旧视图"}
        """
        let decoded = try JSONDecoder().decode(ListView.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.hiddenColumnIDs.isEmpty)
    }

    // MARK: 旧版数据文件兼容（无 views 字段）

    func testOldProjectFileMigration() throws {
        // 手工构造 v1.2 时代的 students.json（无 views / currentViewID）
        let json = """
        {
          "createdAt" : 0,
          "fieldDefinitions" : [

          ],
          "formatVersion" : 1,
          "recordTypes" : [
            "关心关爱"
          ],
          "students" : [
            {
              "boardingAddress" : "",
              "createdAt" : 0,
              "customValues" : {

              },
              "guardians" : [

              ],
              "id" : "F0CFA0D9-F205-47E6-8DF4-9D1228982DF8",
              "isBoarding" : true,
              "name" : "王小明",
              "phone" : "",
              "policeStation" : "",
              "records" : [

              ],
              "studentNumber" : "2024001",
              "updatedAt" : 0
            }
          ],
          "updatedAt" : 0
        }
        """
        let url = tempDir.appendingPathComponent("旧版.studentproj")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url.appendingPathComponent("students.json"))

        let store = ProjectStore()
        try store.openProject(at: url)

        XCTAssertEqual(store.data.students.count, 1)
        XCTAssertEqual(store.data.views.count, 1)
        XCTAssertEqual(store.currentView.name, "全部学生")
        XCTAssertNil(store.recoveryNotice) // 属于正常兼容，不应提示恢复
    }

    // MARK: 按视图范围导出

    func testExportWithViewScope() throws {
        let url = tempDir.appendingPathComponent("导出视图.studentproj")
        let store = ProjectStore()
        try store.createProject(at: url, name: "导出视图")
        for s in sampleStudents() {
            store.addStudent(s)
        }

        var view = ListView(name: "住宿生")
        view.condition = .boarding(true)
        let scoped = StudentQuery.apply(view: view, students: store.data.students, fields: [])
        XCTAssertEqual(scoped.count, 2)

        let file = tempDir.appendingPathComponent("视图导出.xlsx")
        try ExcelExporter.exportAll(data: store.data, to: file, selection: ExportSelection.all(data: store.data),
                                    students: scoped)
        let sheets = try XLSX.readAllSheets(from: file)
        XCTAssertEqual(sheets[0].rows.count, 3) // 表头 + 2 名住宿生
        let names = sheets[0].rows.dropFirst().map { $0[0] }
        XCTAssertEqual(Set(names), ["王小明", "张小虎"])

        let csv = CSVExporter.exportCSV(data: store.data, students: scoped)
        XCTAssertFalse(csv.contains("李小红"))
        XCTAssertTrue(csv.contains("王小明"))
    }
}

// MARK: 类型化单元格（Notion 式）

final class CellEditTests: XCTestCase {

    private func makeAll() -> (text: StudentColumnSpec, checkbox: StudentColumnSpec, date: StudentColumnSpec, field: CustomField) {
        let dateField = CustomField(name: "出生日期", type: .date)
        let checkbox = StudentColumnSpec(id: StudentTableField.boarding.rawValue, title: "住宿",
                                         field: .boarding, customField: nil)
        let date = StudentColumnSpec(id: dateField.id.uuidString, title: dateField.name,
                                     field: nil, customField: dateField)
        let text = StudentColumnSpec(id: StudentTableField.name.rawValue, title: "姓名",
                                     field: .name, customField: nil)
        return (text, checkbox, date, dateField)
    }

    func testCellKindMapping() {
        let (text, checkbox, date, _) = makeAll()
        XCTAssertEqual(text.cellKind, .text(editable: true))
        XCTAssertEqual(checkbox.cellKind, .checkbox)
        XCTAssertEqual(date.cellKind, .datePicker)

        let record = StudentColumnSpec(id: "record", title: "记录", field: .recordCount, customField: nil)
        XCTAssertEqual(record.cellKind, .readonly)

        let gName = StudentColumnSpec.guardianColumns(slot: 1).first { $0.guardianPart == .name }!
        XCTAssertEqual(gName.cellKind, .text(editable: true))

        let numberField = CustomField(name: "身高", type: .number)
        let numberSpec = StudentColumnSpec(id: numberField.id.uuidString, title: "身高",
                                           field: nil, customField: numberField)
        XCTAssertEqual(numberSpec.cellKind, .text(editable: true))

        let boolField = CustomField(name: "是否读过", type: .boolean)
        let boolSpec = StudentColumnSpec(id: boolField.id.uuidString, title: boolField.name,
                                         field: nil, customField: boolField)
        XCTAssertEqual(boolSpec.cellKind, .checkbox)
    }

    func testBooleanCellEdit() {
        let (_, checkbox, _, dateField) = makeAll()
        var s = Student()
        s.isBoarding = false

        // 勾选框切换内置住宿字段
        let boarding = checkbox.applying(.boolean(true), to: s)
        XCTAssertTrue(boarding.isBoarding)
        XCTAssertNil(boarding.customValues[dateField.id.uuidString])

        // 勾选框切换自定义是否字段
        let boolField = CustomField(name: "是否读过", type: .boolean)
        let boolSpec = StudentColumnSpec(id: boolField.id.uuidString, title: boolField.name,
                                         field: nil, customField: boolField)
        let checked = boolSpec.applying(.boolean(true), to: s)
        XCTAssertEqual(checked.customValues[boolField.id.uuidString], .boolean(true))
    }

    func testDateCellEdit() {
        let (_, _, dateSpec, dateField) = makeAll()
        var s = Student()
        s.name = "王小明"

        let date = Date(timeIntervalSince1970: 900_000_000)
        let edited = dateSpec.applying(.date(date), to: s)
        XCTAssertEqual(edited.customValues[dateField.id.uuidString], .date(date))
        XCTAssertEqual(edited.name, "王小明") // 其他字段不受影响
    }
}

// MARK: 字段格式标准

final class FieldFormatTests: XCTestCase {

    func testPhoneValidation() {
        XCTAssertTrue(FieldFormat.isValidPhone(""))            // 选填
        XCTAssertTrue(FieldFormat.isValidPhone("13812345678"))
        XCTAssertTrue(FieldFormat.isValidPhone("+86 138 1234 5678"))
        XCTAssertTrue(FieldFormat.isValidPhone("0510-8888 6666"))
        XCTAssertFalse(FieldFormat.isValidPhone("abc"))
        XCTAssertFalse(FieldFormat.isValidPhone("138123"))     // 过短
        XCTAssertFalse(FieldFormat.isValidPhone("电话不详"))     // 常见的非标准填写
        XCTAssertFalse(FieldFormat.isValidPhone("1381234567890123456")) // 过长
    }

    func testTablePhoneEnforcement() {
        let phoneSpec = StudentColumnSpec.builtins(order: [], deleted: []).first { $0.field == .phone }!
        var s = Student()
        s.name = "王小明"

        let ok = phoneSpec.applying(CellEdit.text("13812345678"), to: s)
        XCTAssertEqual(ok.phone, "13812345678")

        let rejected = phoneSpec.applying(CellEdit.text("电话不详"), to: s)
        XCTAssertEqual(rejected.phone, "", "非法电话应不写入")

        let cleared = phoneSpec.applying(CellEdit.text(""), to: s)
        XCTAssertEqual(cleared.phone, "") // 清空允许
    }
}

// MARK: 记录类别

final class RecordCategoryTests: XCTestCase {

    @MainActor

    func testDefaultRecordTypes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordCategoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectStore()
        try store.createProject(at: dir.appendingPathComponent("分类测试.studentproj"), name: "分类测试")

        // 新项目默认四类
        XCTAssertEqual(store.data.recordTypes,
                       ["关心关爱记录", "谈话记录", "家校沟通记录", "违纪记录"])

        // 恢复默认分类（替换自定义类型）
        store.addRecordType("自定义类型")
        store.setRecordTypes(ProjectData.defaultRecordTypes)
        XCTAssertEqual(store.data.recordTypes, ProjectData.defaultRecordTypes)
    }
}

// MARK: 任意字段查询（类 SQL WHERE）

final class ColumnQueryTests: XCTestCase {

    @MainActor
    func testColumnContainsFilter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColumnQueryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectStore()
        try store.createProject(at: dir.appendingPathComponent("查询测试.studentproj"), name: "查询测试")
        store.addField(name: "班级", type: .text)

        var a = Student(); a.name = "王小明"; a.studentNumber = "1"; a.isBoarding = true
        a.policeStation = "城南派出所"
        a.customValues[store.data.fieldDefinitions[0].id.uuidString] = .text("三（2）班")
        a.guardians = [Guardian(name: "王建国", relation: "父", phone: "13900000001")]
        var b = Student(); b.name = "李小红"; b.studentNumber = "2"; b.isBoarding = false
        b.customValues[store.data.fieldDefinitions[0].id.uuidString] = .text("三（3）班")
        store.addStudent(a)
        store.addStudent(b)

        // 按姓名列查询
        var view = ListView(name: "查姓名")
        view.condition = .columnContains(columnID: StudentTableField.name.rawValue, value: "王小")
        XCTAssertEqual(StudentQuery.apply(view: view, students: store.data.students, fields: store.data.fieldDefinitions).map { $0.name },
                       ["王小明"])

        // 按监护人姓名列查询（扁平列）
        view.condition = .columnContains(columnID: "guardian1-name", value: "王建国")
        XCTAssertEqual(StudentQuery.apply(view: view, students: store.data.students, fields: store.data.fieldDefinitions).map { $0.name },
                       ["王小明"])

        // 按自定义字段列查询（不区分大小写）
        view.condition = .columnContains(columnID: store.data.fieldDefinitions[0].id.uuidString, value: "三（3）班")
        XCTAssertEqual(StudentQuery.apply(view: view, students: store.data.students, fields: store.data.fieldDefinitions).map { $0.name },
                       ["李小红"])

        // 列被删除后查询条件不崩溃（返回全部）
        view.condition = .columnContains(columnID: "不存在的列", value: "x")
        XCTAssertEqual(StudentQuery.apply(view: view, students: store.data.students, fields: store.data.fieldDefinitions).count, 2)
    }

    @MainActor
    func testFieldRename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectStore()
        try store.createProject(at: dir.appendingPathComponent("重命名.studentproj"), name: "重命名")
        store.addField(name: "班级", type: .text)

        var field = store.data.fieldDefinitions[0]
        field.name = "就读班级"
        store.updateField(field)
        XCTAssertEqual(store.data.fieldDefinitions[0].name, "就读班级")

        // 重命名后列规格同步更新，学生已填的值保留
        var s = Student(); s.name = "王小明"; s.studentNumber = "1"
        s.customValues[field.id.uuidString] = .text("三（2）班")
        store.addStudent(s)
        let spec = StudentColumnSpec.allColumns(fields: store.data.fieldDefinitions, guardianSlots: 1).first { $0.customField?.id == field.id }
        XCTAssertEqual(spec?.title, "就读班级")
        XCTAssertEqual(spec?.displayText(of: store.data.students[0]), "三（2）班")
    }
}

// MARK: 字段顺序 / 内置字段软删除 / 下拉类型

final class FieldManagementTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldMgmtTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    @MainActor
    private func makeStore() throws -> ProjectStore {
        let store = ProjectStore()
        try store.createProject(at: dir.appendingPathComponent("字段管理.studentproj"), name: "字段管理")
        return store
    }

    @MainActor
    func testFieldOrdering() throws {
        let store = try makeStore()
        store.addField(name: "班级", type: .text)
        store.addField(name: "性别", type: .choice(options: ["男", "女"]))
        store.addField(name: "身高", type: .number)

        // 列顺序默认为添加顺序
        XCTAssertEqual(store.data.orderedFields.map { $0.name }, ["班级", "性别", "身高"])

        // 上移“身高”（统一布局）
        let heightID = store.data.orderedFields[2].id
        store.moveField(id: heightID, offset: -1)
        var cols = StudentColumnSpec.columns(fields: store.data.orderedFields, hidden: [],
                                             guardianSlots: 1, layout: store.data.columnLayout)
        XCTAssertTrue(cols.firstIndex { $0.customField?.id == heightID }! <
                      cols.firstIndex { $0.title == "性别" }!, "身高应在性别之前")

        // 持久化后布局保留
        try store.saveNow()
        let reopened = ProjectStore()
        try reopened.openProject(at: dir.appendingPathComponent("字段管理.studentproj"))
        let reopenedCols = StudentColumnSpec.columns(fields: reopened.data.orderedFields, hidden: [],
                                                     guardianSlots: 1, layout: reopened.data.columnLayout)
        XCTAssertTrue(reopenedCols.firstIndex { $0.customField?.id == heightID }! <
                      reopenedCols.firstIndex { $0.title == "性别" }!)

        // 删除字段后布局清理
        reopened.deleteField(id: heightID)
        XCTAssertFalse(reopened.data.columnLayout.contains(heightID.uuidString))
    }

    @MainActor
    func testBuiltinOrderAndSoftDelete() throws {
        let store = try makeStore()

        // 移动内置字段：姓名下移一位（统一布局）
        store.moveBuiltinField(key: "name", offset: 1)
        let cols = StudentColumnSpec.builtins(order: store.data.builtinOrder, deleted: [],
                                              layout: store.data.columnLayout)
        XCTAssertEqual(Array(cols.map { $0.id }.prefix(2)), ["studentNumber", "name"])

        // 真删除电话字段：列消失、数据清空、搜索跳过
        var s = Student()
        s.name = "王小明"; s.studentNumber = "1"; s.phone = "13812345678"
        store.addStudent(s)
        store.hardDeleteBuiltinField(key: "phone")
        XCTAssertFalse(StudentColumnSpec.builtins(order: store.data.builtinOrder,
                                                  deleted: store.data.deletedBuiltinFields)
            .contains { $0.field == .phone })
        XCTAssertEqual(store.data.students[0].phone, "") // 数据被清除
        XCTAssertFalse(SearchKit.searchableText(of: s, fields: [],
                                                deletedBuiltin: store.data.deletedBuiltinFields)
            .contains("13812345678"))

        // 恢复后字段重新出现（数据为空）
        store.restoreBuiltinField(key: "phone")
        XCTAssertTrue(StudentColumnSpec.builtins(order: store.data.builtinOrder,
                                                 deleted: store.data.deletedBuiltinFields)
            .contains { $0.field == .phone })

        // 姓名、学号为必备字段：真删除被拒绝
        store.hardDeleteBuiltinField(key: "name")
        store.hardDeleteBuiltinField(key: "studentNumber")
        XCTAssertTrue(StudentColumnSpec.builtins(order: store.data.builtinOrder,
                                                 deleted: store.data.deletedBuiltinFields)
            .contains { $0.field == .name })
        XCTAssertTrue(StudentColumnSpec.builtins(order: store.data.builtinOrder,
                                                 deleted: store.data.deletedBuiltinFields)
            .contains { $0.field == .studentNumber })
        XCTAssertEqual(store.data.students[0].name, "王小明")
    }

    @MainActor
    func testChoiceFieldType() throws {
        let store = try makeStore()
        store.addField(name: "性别", type: .choice(options: ["男", "女"]))

        let field = store.data.orderedFields[0]
        let spec = StudentColumnSpec(id: field.id.uuidString, title: field.name,
                                     field: nil, customField: field)
        XCTAssertEqual(spec.cellKind, .choice(options: ["男", "女"]))

        var s = Student()
        s.name = "王小明"

        // 合法选项写入
        XCTAssertEqual(spec.applying(CellEdit.text("男"), to: s).customValues[field.id.uuidString], .text("男"))
        // 非法值拒绝
        XCTAssertEqual(spec.applying(CellEdit.text("未知"), to: s).customValues[field.id.uuidString], nil)
        // 清空允许
        let filled = spec.applying(CellEdit.text("男"), to: s)
        XCTAssertNil(spec.applying(CellEdit.text(""), to: filled).customValues[field.id.uuidString])

        // 编解码往返（含选项）
        let raw = try ProjectStore.encoder.encode(store.data)
        let decoded = try ProjectStore.decoder.decode(ProjectData.self, from: raw)
        XCTAssertEqual(decoded.fieldDefinitions[0].type, .choice(options: ["男", "女"]))

        // 导入：选项外的值不写入
        var imported = Student()
        imported.name = "李小红"
        let applied = spec.applying(CellEdit.text("女"), to: imported)
        XCTAssertEqual(applied.customValues[field.id.uuidString], .text("女"))
    }

    func testFieldTypeCodableCompat() throws {
        // 旧文件字段类型为字符串编码（无 choice）
        let old = """
        [{"id": "622E5632-340E-482D-BA5B-54FF8CC4CBDE", "name": "班级", "type": "text"}]
        """
        let fields = try JSONDecoder().decode([CustomField].self, from: Data(old.utf8))
        XCTAssertEqual(fields[0].type, .text)
    }
}

// MARK: 表格文本编辑提交回归（修复：field editor 转发时提交被丢弃）

final class TextCommitRegressionTests: XCTestCase {

    @MainActor
    func testControlTextEndEditingAcceptsFieldEditorForwarding() {
        let phoneSpec = StudentColumnSpec.builtins(order: [], deleted: []).first { $0.field == .phone }!
        var student = Student()
        student.name = "王小明"
        student.phone = "13812345678"

        var committed: (UUID, String, CellEdit)?
        var representable = EditableStudentTable(
            students: [student],
            columns: [phoneSpec],
            sortKey: .name,
            sortAscending: true,
            selection: .constant([]),
            onSortChange: { _, _ in },
            onCommit: { studentID, spec, edit in
                // 命中即视为提交成功
                committed = (studentID, spec.id, edit)
            }
        )

        // 模拟 AppKit 运行时：field editor 的 delegate 是被编辑的控件
        final class TestField: NSTextField, NSTextViewDelegate {}
        let textField = TestField(string: "13900000000")
        let editor = NSTextView()
        editor.delegate = textField
        let note = Notification(name: Notification.Name("t"), object: nil)

        let coordinator = representable.makeCoordinator()
        coordinator.editingContext = (student.id, phoneSpec)

        // 场景 1：object 是 NSTextField（正常路径）
        coordinator.controlTextDidEndEditing(Notification(name: note.name, object: textField))
        XCTAssertNil(coordinator.editingContext, "提交后 editingContext 应清空")

        // 场景 2：object 是 field editor（NSTextView）——修复前此路径丢弃编辑
        committed = nil
        representable = EditableStudentTable(
            students: [student],
            columns: [phoneSpec],
            sortKey: .name,
            sortAscending: true,
            selection: .constant([]),
            onSortChange: { _, _ in },
            onCommit: { studentID, spec, edit in
                committed = (studentID, spec.id, edit)
            }
        )
        let coordinator2 = representable.makeCoordinator()
        coordinator2.editingContext = (student.id, phoneSpec)
        coordinator2.controlTextDidEndEditing(Notification(name: note.name, object: editor))
        XCTAssertNil(coordinator2.editingContext, "field editor 路径也应提交（修复点）")
        XCTAssertNotNil(committed, "onCommit 必须被调用")

        // 场景 3：action 路径（回车触发 target/action）
        var committed3: Bool = false
        let representable3 = EditableStudentTable(
            students: [student],
            columns: [phoneSpec],
            sortKey: .name,
            sortAscending: true,
            selection: .constant([]),
            onSortChange: { _, _ in },
            onCommit: { _, _, _ in committed3 = true }
        )
        let coordinator3 = representable3.makeCoordinator()
        coordinator3.editingContext = (student.id, phoneSpec)
        coordinator3.textFieldActionFired(textField)
        XCTAssertTrue(committed3, "action 路径应提交")

        _ = representable
    }
}

// MARK: 新字段类型（多选 / 日期时间 / 地址）

final class NewFieldTypeTests: XCTestCase {

    func testMultiChoiceSpec() {
        let field = CustomField(name: "标签", type: .multiChoice(options: ["团员", "班干部", "住宿生"]))
        let spec = StudentColumnSpec(id: field.id.uuidString, title: field.name, field: nil, customField: field)
        XCTAssertEqual(spec.cellKind, .multiChoice(options: ["团员", "班干部", "住宿生"]))

        var s = Student()
        s.name = "王小明"
        // 合法子集写入（顿号拼接）
        let picked = spec.applying(CellEdit.text("团员、住宿生"), to: s)
        XCTAssertEqual(picked.customValues[field.id.uuidString], .text("团员、住宿生"))
        // 含非法选项拒绝
        XCTAssertEqual(spec.applying(CellEdit.text("团员、其他"), to: s).customValues[field.id.uuidString], nil)
        // 清空允许
        XCTAssertNil(spec.applying(CellEdit.text(""), to: picked).customValues[field.id.uuidString])
    }

    func testDateTimeSpec() {
        let field = CustomField(name: "约谈时间", type: .dateTime)
        let spec = StudentColumnSpec(id: field.id.uuidString, title: field.name, field: nil, customField: field)
        XCTAssertEqual(spec.cellKind, .dateTimePicker)

        var s = Student()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let edited = spec.applying(.date(date), to: s)
        XCTAssertEqual(edited.customValues[field.id.uuidString], .date(date))
        // 文本方式写入被拒绝（由选择器维护）
        XCTAssertEqual(spec.applying(CellEdit.text("随便"), to: s).customValues[field.id.uuidString], nil)
    }

    func testAddressSpec() {
        let field = CustomField(name: "家庭住址", type: .address)
        let spec = StudentColumnSpec(id: field.id.uuidString, title: field.name, field: nil, customField: field)
        XCTAssertEqual(spec.cellKind, .text(editable: true)) // 地址为文本编辑

        var s = Student()
        let edited = spec.applying(CellEdit.text("江苏省无锡市江阴市某某镇某某村12号"), to: s)
        XCTAssertEqual(edited.customValues[field.id.uuidString], .text("江苏省无锡市江阴市某某镇某某村12号"))
    }

    func testNewTypesCodableRoundTrip() throws {
        let fields = [
            CustomField(name: "标签", type: .multiChoice(options: ["团员", "班干部"])),
            CustomField(name: "约谈时间", type: .dateTime),
            CustomField(name: "家庭住址", type: .address)
        ]
        let raw = try JSONEncoder().encode(fields)
        let decoded = try JSONDecoder().decode([CustomField].self, from: raw)
        XCTAssertEqual(decoded, fields)
    }

    @MainActor
    func testImporterMultiChoice() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewFieldImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore()
        try store.createProject(at: dir.appendingPathComponent("t.studentproj"), name: "t")
        store.addField(name: "标签", type: .multiChoice(options: ["团员", "班干部"]))

        var s = Student()
        s.name = "王小明"
        s.studentNumber = "1"
        let field = store.data.orderedFields[0]
        let spec = StudentColumnSpec(id: field.id.uuidString, title: field.name, field: nil, customField: field)
        let ok = spec.applying(CellEdit.text("团员、班干部"), to: s)
        XCTAssertEqual(ok.customValues[field.id.uuidString], .text("团员、班干部"))
    }
}

// MARK: 统一列布局（表格拖拽 / 详情拖拽 / 字段管理共用）

final class ColumnLayoutTests: XCTestCase {

    @MainActor
    func testUnifiedLayout() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectStore()
        try store.createProject(at: dir.appendingPathComponent("布局.studentproj"), name: "布局")
        store.addField(name: "班级", type: .text)

        // 默认布局：内置 → 监护人 → 自定义
        let base = store.currentColumnLayout()
        XCTAssertEqual(base.first, "name")

        // 模拟表格列拖拽：整体替换顺序（班级提到最前，监护人居后）
        let dragged = ["boardingAddress", "guardian1-name", "guardian1-relation",
                       "guardian1-phone", "name", "studentNumber", "boarding",
                       "phone", "policeStation", "recordCount",
                       store.data.orderedFields[0].id.uuidString]
        store.setColumnLayout(dragged)

        let cols = StudentColumnSpec.columns(
            fields: store.data.orderedFields, hidden: [],
            guardianSlots: 1,
            builtinOrder: store.data.builtinOrder,
            deletedBuiltin: store.data.deletedBuiltinFields,
            layout: store.data.columnLayout
        )
        XCTAssertEqual(cols.map { $0.id }, dragged, "列输出应严格按统一布局")

        // 上移/下移按钮：姓名（dragged 中 index 4）上移一位到 index 3
        store.moveColumn(id: "name", offset: -1)
        let moved = StudentColumnSpec.columns(
            fields: store.data.orderedFields, hidden: [],
            guardianSlots: 1, builtinOrder: store.data.builtinOrder,
            deletedBuiltin: store.data.deletedBuiltinFields,
            layout: store.data.columnLayout
        ).map { $0.id }
        XCTAssertEqual(moved.firstIndex(of: "name"), 3)

        // 隐藏列不受布局影响：隐藏姓名后其余顺序保持
        var withHidden = StudentColumnSpec.columns(
            fields: store.data.orderedFields, hidden: ["name"],
            guardianSlots: 1, builtinOrder: store.data.builtinOrder,
            deletedBuiltin: store.data.deletedBuiltinFields,
            layout: store.data.columnLayout
        ).map { $0.id }
        XCTAssertFalse(withHidden.contains("name"))
        withHidden.insert("name", at: moved.firstIndex(of: "name")!)
        XCTAssertEqual(withHidden, moved)

        // 持久化
        try store.saveNow()
        let reopened = ProjectStore()
        try reopened.openProject(at: dir.appendingPathComponent("布局.studentproj"))
        XCTAssertEqual(reopened.data.columnLayout.firstIndex(of: "name"), 3)

        // 新增字段未在布局中：追加尾部
        reopened.addField(name: "新字段", type: .text)
        let appended = StudentColumnSpec.columns(
            fields: reopened.data.orderedFields, hidden: [],
            guardianSlots: 1, builtinOrder: reopened.data.builtinOrder,
            deletedBuiltin: reopened.data.deletedBuiltinFields,
            layout: reopened.data.columnLayout
        ).map { $0.id }
        XCTAssertEqual(appended.last, reopened.data.orderedFields.first { $0.name == "新字段" }?.id.uuidString)
    }
}

// MARK: 批量操作（多选修改 / 批量删除）

final class BatchOperationTests: XCTestCase {

    @MainActor
    private func makeStoreWith5() throws -> ProjectStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchOps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProjectStore()
        try store.createProject(at: dir.appendingPathComponent("t.studentproj"), name: "t")
        store.addField(name: "班级", type: .text)
        for i in 1...5 {
            var s = Student()
            s.name = "学生\(i)"
            s.studentNumber = "B\(i)"
            s.isBoarding = i % 2 == 0
            store.addStudent(s)
        }
        return store
    }

    @MainActor
    func testBatchFieldUpdate() throws {
        let store = try makeStoreWith5()
        let boardingSpec = StudentColumnSpec.builtins(order: [], deleted: []).first { $0.field == .boarding }!

        // 批量：全部设为住宿（模拟 BatchEditSheet.apply 的管线）
        let ids = Set(store.data.students.map { $0.id })
        var applied = 0
        for id in ids {
            guard let student = store.student(id: id) else { continue }
            let updated = boardingSpec.applying(.boolean(true), to: student)
            if updated != student {
                store.updateStudent(updated)
                applied += 1
            }
        }
        XCTAssertEqual(applied, 3, "仅 3 名走读学生被更新")
        XCTAssertEqual(store.data.students.filter { $0.isBoarding }.count, 5)

        // 批量：自定义字段赋值
        let classField = store.data.orderedFields[0]
        let classSpec = StudentColumnSpec(id: classField.id.uuidString, title: "班级",
                                          field: nil, customField: classField)
        for id in ids {
            guard let student = store.student(id: id) else { continue }
            store.updateStudent(classSpec.applying(.text("251301班"), to: student))
        }
        XCTAssertTrue(store.data.students.allSatisfy {
            $0.customValues[classField.id.uuidString] == .text("251301班")
        })

        // 非法值不生效（数字列批量赋非数字）
        store.addField(name: "身高", type: .number)
        let numberField = store.data.orderedFields[1]
        let numberSpec = StudentColumnSpec(id: numberField.id.uuidString, title: "身高",
                                           field: nil, customField: numberField)
        for id in ids {
            guard let student = store.student(id: id) else { continue }
            store.updateStudent(numberSpec.applying(.text("abc"), to: student))
        }
        XCTAssertTrue(store.data.students.allSatisfy { (s: Student) in
            !s.customValues.keys.contains(numberField.id.uuidString)
        })
    }

    @MainActor
    func testBatchDelete() throws {
        let store = try makeStoreWith5()
        let ids = Set(store.data.students.filter { !$0.isBoarding }.map { $0.id })
        XCTAssertEqual(ids.count, 3)

        store.deleteStudents(ids: ids)
        XCTAssertEqual(store.data.students.count, 2)
        XCTAssertTrue(store.data.students.allSatisfy { $0.isBoarding })
    }
}
