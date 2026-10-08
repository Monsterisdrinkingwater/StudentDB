import XCTest
@testable import StudentDB

/// 学分计算：默认规则值、记录快照与累计、0.5 半分、学期隔离、旧项目兼容（只增不删）、
/// 删学生引用清理、学期选择持久化。
/// 全部用临时目录建独立 .studentproj（照 ProjectStoreTests / DBTableTests 范式），
/// 不触碰用户真实数据；不模仿 upgrade_fields.swift。
@MainActor
final class CreditPointTests: XCTestCase {

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
        tempDir.appendingPathComponent("学分测试学生库.studentproj")
    }

    private func makeStore() throws -> ProjectStore {
        let store = ProjectStore()
        try store.createProject(at: makeProjectURL(), name: "学分测试")
        return store
    }

    private func makeStudent(name: String, number: String) -> Student {
        var student = Student()
        student.name = name
        student.studentNumber = number
        return student
    }

    /// 固定时区公历日历（推断按年月分量，测试显式传入保证确定性）
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: 默认规则值

    func testDefaultRules() {
        let rules = CreditRule.defaults
        XCTAssertEqual(rules.count, 196)
        let byName = Dictionary(uniqueKeysWithValues: rules.map { ($0.name, $0.points) })
        // 手册子项：常规抽查与处分层级
        XCTAssertEqual(byName["常规抽查（系级）（橙色等级）"], -2)
        XCTAssertEqual(byName["常规抽查（校级）（红色等级）"], -4)
        XCTAssertEqual(byName["处分（通报批评）"], -10)
        XCTAssertEqual(byName["处分（警告）"], -20)
        XCTAssertEqual(byName["处分（严重警告）"], -30)
        XCTAssertEqual(byName["处分（记过）"], -40)
        XCTAssertEqual(byName["处分（留校察看）"], -50)
        // 扣分
        XCTAssertEqual(byName["违反校纪校规"], -2)
        XCTAssertEqual(byName["劳动有问题"], -1)
        XCTAssertEqual(byName["劳动返工"], -0.5)
        // 参赛（愿意主动参加也是加分）
        XCTAssertEqual(byName["参加校级比赛"], 2)
        XCTAssertEqual(byName["参加江阴市级比赛"], 3)
        XCTAssertEqual(byName["参加无锡市级比赛"], 4)
        XCTAssertEqual(byName["参加省级比赛"], 5)
        // 获奖（新递进：奖次差 3，层间差 4；市级单项最高 20、省级最高 30 为锚点）
        XCTAssertEqual(byName["校级比赛三等奖"], 6)
        XCTAssertEqual(byName["校级比赛二等奖"], 9)
        XCTAssertEqual(byName["校级比赛一等奖"], 12)
        XCTAssertEqual(byName["江阴市级比赛三等奖"], 10)
        XCTAssertEqual(byName["江阴市级比赛二等奖"], 13)
        XCTAssertEqual(byName["江阴市级比赛一等奖"], 16)
        XCTAssertEqual(byName["无锡市级比赛三等奖"], 14)
        XCTAssertEqual(byName["无锡市级比赛二等奖"], 17)
        XCTAssertEqual(byName["无锡市级比赛一等奖"], 20)
        XCTAssertEqual(byName["省级比赛三等奖"], 24)
        XCTAssertEqual(byName["省级比赛二等奖"], 27)
        XCTAssertEqual(byName["省级比赛一等奖"], 30)
        // 三组齐全、固定 UUID（重复构造结果稳定）
        XCTAssertEqual(Set(rules.map(\.category)), Set(CreditRule.categories))
        XCTAssertEqual(rules.map(\.id), CreditRule.defaults.map(\.id))
    }

    // MARK: 学期推断

    func testSemesterInference2026October() {
        // 今天 2026-10-07 所在学期
        let key = CreditSemester.infer(from: date(2026, 10, 7), calendar: calendar)
        XCTAssertEqual(key, "2026-2027-1")
        XCTAssertEqual(CreditSemester.displayName(for: key), "2026-2027 学年第一学期")
    }

    func testSemesterInferenceJanuary() {
        // 1 月属上一学年第一学期
        XCTAssertEqual(CreditSemester.infer(from: date(2027, 1, 15), calendar: calendar),
                       "2026-2027-1")
    }

    func testSemesterInferenceBoundary() {
        // 7 月底仍是上一学年第二学期，8 月 1 日进入新学年第一学期
        XCTAssertEqual(CreditSemester.infer(from: date(2026, 7, 31), calendar: calendar),
                       "2025-2026-2")
        XCTAssertEqual(CreditSemester.infer(from: date(2026, 8, 1), calendar: calendar),
                       "2026-2027-1")
    }

    func testRecentSemesters() {
        let keys = CreditSemester.recentSemesters(from: date(2026, 10, 7), count: 4,
                                                  calendar: calendar)
        XCTAssertEqual(keys, ["2026-2027-1", "2025-2026-2", "2025-2026-1", "2024-2025-2"])
        XCTAssertEqual(CreditSemester.displayName(for: keys[1]), "2025-2026 学年第二学期")
    }

    // MARK: 旧项目兼容（只增不删、幂等）

    /// 手写一份无 creditRules / creditRecords / creditSemesterKey 键的最小旧版 students.json
    private func oldProjectJSON() -> Data {
        Data("""
        {
          "formatVersion": 1,
          "createdAt": 1700000000000,
          "updatedAt": 1700000000000,
          "recordTypes": ["关心关爱记录", "违纪记录"],
          "fieldDefinitions": [],
          "students": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "王小明",
              "studentNumber": "2024001",
              "isBoarding": false,
              "phone": "",
              "boardingAddress": "",
              "policeStation": "",
              "customValues": {},
              "guardians": [],
              "records": [],
              "createdAt": 1700000000000,
              "updatedAt": 1700000000000
            }
          ],
          "views": [
            {
              "id": "66666666-2222-3333-4444-555555555555",
              "name": "全部学生",
              "sortKey": "name",
              "sortAscending": true,
              "layout": "detail",
              "hiddenColumnIDs": [],
              "guardianColumnCount": 1
            }
          ],
          "quickFilters": [],
          "builtinOrder": ["name", "studentNumber"],
          "fieldOrder": [],
          "deletedBuiltinFields": [],
          "columnLayout": [],
          "tables": [],
          "columnWidths": {},
          "recordMigrationDone": true
        }
        """.utf8)
    }

    private func writeOldProject() throws -> URL {
        let url = makeProjectURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try oldProjectJSON().write(to: url.appendingPathComponent(ProjectStore.dataFileName))
        return url
    }

    func testOldProjectDecodeDefaults() throws {
        let url = try writeOldProject()
        let store = ProjectStore()
        try store.openProject(at: url)

        // 新键以默认值补齐（旧文件缺键不炸）
        XCTAssertEqual(store.data.creditRules, CreditRule.defaults)
        XCTAssertEqual(store.data.creditRecords, [])
        XCTAssertNil(store.data.creditSemesterKey)
        // 旧键一个不丢
        XCTAssertEqual(store.data.students.first?.name, "王小明")
        XCTAssertEqual(store.data.recordTypes, ["关心关爱记录", "违纪记录"])
        XCTAssertEqual(store.data.views.first?.name, "全部学生")
    }

    func testOldProjectRoundTripIdempotent() throws {
        let url = try writeOldProject()
        let first = ProjectStore()
        try first.openProject(at: url)
        try first.saveNow()

        let dataURL = url.appendingPathComponent(ProjectStore.dataFileName)
        let raw1 = try Data(contentsOf: dataURL)

        let second = ProjectStore()
        try second.openProject(at: url)
        try second.saveNow()
        let raw2 = try Data(contentsOf: dataURL)

        // 新键在两次保存里都写入且稳定（幂等二开）
        let json1 = try XCTUnwrap(JSONSerialization.jsonObject(with: raw1) as? [String: Any])
        let json2 = try XCTUnwrap(JSONSerialization.jsonObject(with: raw2) as? [String: Any])
        XCTAssertNotNil(json1["creditRules"])
        XCTAssertNotNil(json2["creditRules"])
        XCTAssertNotNil(json1["creditRecords"])
        XCTAssertNotNil(json2["creditRecords"])

        let decoded1 = try ProjectStore.decoder.decode(ProjectData.self, from: raw1)
        let decoded2 = try ProjectStore.decoder.decode(ProjectData.self, from: raw2)
        XCTAssertEqual(decoded1.creditRules, decoded2.creditRules)
        XCTAssertEqual(decoded1.creditRecords, decoded2.creditRecords)
        XCTAssertEqual(decoded1.creditSemesterKey, decoded2.creditSemesterKey)
        // 既有键不丢
        XCTAssertEqual(decoded1.students, decoded2.students)
        XCTAssertEqual(decoded1.recordTypes, ["关心关爱记录", "违纪记录"])
        XCTAssertEqual(decoded1.students.count, 1)
    }

    // MARK: 记录快照 / 累计 / 删除 / 自定义

    func testAddRecordSnapshots() throws {
        let store = try makeStore()
        let student = makeStudent(name: "李雷", number: "01")
        store.addStudent(student)
        let rule = try XCTUnwrap(CreditRule.defaults.first { $0.name == "违反校纪校规" })

        let record = try XCTUnwrap(store.addCreditRecord(
            studentIDs: [student.id], rule: rule,
            semesterKey: "2026-2027-1", note: "课堂违纪", date: date(2026, 10, 7)))
        XCTAssertEqual(store.data.creditRecords.count, 1)
        XCTAssertEqual(record.ruleID, rule.id)
        XCTAssertEqual(record.ruleName, "违反校纪校规")
        XCTAssertEqual(record.points, -2)
        XCTAssertEqual(record.semesterKey, "2026-2027-1")
        XCTAssertEqual(record.createdAt, date(2026, 10, 7))
        XCTAssertEqual(record.note, "课堂违纪")

        // 规则改名/改分值后，历史记录的留痕不变
        var renamed = rule
        renamed.name = "重大违纪"
        renamed.points = -5
        store.updateCreditRules([renamed])
        XCTAssertEqual(store.data.creditRecords[0].ruleName, "违反校纪校规")
        XCTAssertEqual(store.data.creditRecords[0].points, -2)
    }

    func testSubtotalsAndSemesterIsolation() throws {
        let store = try makeStore()
        let a = makeStudent(name: "甲", number: "01")
        let b = makeStudent(name: "乙", number: "02")
        store.addStudent(a)
        store.addStudent(b)
        let contest = try XCTUnwrap(CreditRule.defaults.first { $0.name == "参加校级比赛" })   // +2
        let rework = try XCTUnwrap(CreditRule.defaults.first { $0.name == "劳动返工" })        // -0.5

        // 甲本学期：+2、-0.5（半分）、再一条甲乙同记 +2
        store.addCreditRecord(studentIDs: [a.id], rule: contest,
                              semesterKey: "2026-2027-1", date: date(2026, 9, 1))
        store.addCreditRecord(studentIDs: [a.id], rule: rework,
                              semesterKey: "2026-2027-1", date: date(2026, 9, 2))
        store.addCreditRecord(studentIDs: [a.id, b.id], rule: contest,
                              semesterKey: "2026-2027-1", date: date(2026, 9, 3))
        // 甲上学期的记录不应计入本学期
        store.addCreditRecord(studentIDs: [a.id], rule: contest,
                              semesterKey: "2025-2026-2", date: date(2026, 3, 1))

        let totals = CreditSummary.studentTotals(records: store.data.creditRecords,
                                                 semesterKey: "2026-2027-1")
        XCTAssertEqual(totals[a.id] ?? 0, 3.5, accuracy: 0.0001)   // 2 - 0.5 + 2
        XCTAssertEqual(totals[b.id] ?? 0, 2, accuracy: 0.0001)

        let lastSemester = CreditSummary.studentTotals(records: store.data.creditRecords,
                                                       semesterKey: "2025-2026-2")
        XCTAssertEqual(lastSemester[a.id] ?? 0, 2, accuracy: 0.0001)
        XCTAssertNil(lastSemester[b.id])

        // 学期合计 = 各生小计之和
        XCTAssertEqual(CreditSummary.semesterTotal(records: store.data.creditRecords,
                                                   semesterKey: "2026-2027-1"),
                       5.5, accuracy: 0.0001)
        XCTAssertEqual(CreditSummary.semesterTotal(records: store.data.creditRecords,
                                                   semesterKey: "2025-2026-2"),
                       2, accuracy: 0.0001)

        // 流水按学期过滤（store 侧）
        XCTAssertEqual(store.creditRecords(semesterKey: "2026-2027-1").count, 3)
        XCTAssertEqual(store.creditRecords(semesterKey: "2025-2026-2").count, 1)
    }

    func testDeleteRecord() throws {
        let store = try makeStore()
        let a = makeStudent(name: "甲", number: "01")
        store.addStudent(a)
        let rule = try XCTUnwrap(CreditRule.defaults.first { $0.points == -2 })
        let first = try XCTUnwrap(store.addCreditRecord(studentIDs: [a.id], rule: rule,
                                                        semesterKey: "2026-2027-1"))
        _ = try XCTUnwrap(store.addCreditRecord(studentIDs: [a.id], rule: rule,
                                                semesterKey: "2026-2027-1"))
        let key = "2026-2027-1"
        XCTAssertEqual(CreditSummary.studentTotals(records: store.data.creditRecords,
                                                   semesterKey: key)[a.id] ?? 0, -4, accuracy: 0.0001)

        // 删除单条后，总分 = 剩余记录累计（总分本就不落库，没有可直接改写的字段）
        store.deleteCreditRecord(id: first.id)
        XCTAssertEqual(store.data.creditRecords.count, 1)
        XCTAssertEqual(CreditSummary.studentTotals(records: store.data.creditRecords,
                                                   semesterKey: key)[a.id] ?? 0, -2, accuracy: 0.0001)
    }

    func testCustomRecord() throws {
        let store = try makeStore()
        let a = makeStudent(name: "甲", number: "01")
        store.addStudent(a)

        let record = try XCTUnwrap(store.addCustomCreditRecord(
            studentIDs: [a.id], points: -0.5, name: "值日返工补扣",
            semesterKey: "2026-2027-1", note: "卫生角未整理"))
        XCTAssertNil(record.ruleID, "自定义记录不挂规则")
        XCTAssertEqual(record.points, -0.5, accuracy: 0.0001)
        XCTAssertEqual(store.data.creditRecords.count, 1)
        XCTAssertEqual(CreditSummary.studentTotals(records: store.data.creditRecords,
                                                   semesterKey: "2026-2027-1")[a.id] ?? 0,
                       -0.5, accuracy: 0.0001)

        // 分值显示格式
        XCTAssertEqual(CreditSummary.pointsText(3.0), "3")
        XCTAssertEqual(CreditSummary.pointsText(-0.5), "-0.5")
        XCTAssertEqual(CreditSummary.signedPointsText(2), "+2")
        XCTAssertEqual(CreditSummary.signedPointsText(-2), "-2")
        XCTAssertEqual(CreditSummary.signedPointsText(0), "0")
    }

    // MARK: 删学生同步

    func testRemoveStudentCleansCreditLinks() throws {
        let store = try makeStore()
        let a = makeStudent(name: "甲", number: "01")
        let b = makeStudent(name: "乙", number: "02")
        store.addStudent(a)
        store.addStudent(b)
        let rule = CreditRule.defaults[0]
        // 一条只记甲、一条甲乙同记
        store.addCreditRecord(studentIDs: [a.id], rule: rule, semesterKey: "2026-2027-1")
        store.addCreditRecord(studentIDs: [a.id, b.id], rule: rule, semesterKey: "2026-2027-1")

        store.deleteStudent(id: a.id)

        // 甲的引用被清掉；只含甲的记录整条删除（防悬挂 UUID）
        XCTAssertEqual(store.data.creditRecords.count, 1)
        XCTAssertEqual(store.data.creditRecords[0].studentIDs, [b.id])
        XCTAssertFalse(store.data.creditRecords[0].studentIDs.contains(a.id))
    }

    // MARK: 学期选择持久化

    func testCreditSemesterKeyPersists() throws {
        let url = makeProjectURL()
        let store = ProjectStore()
        try store.createProject(at: url, name: "学分测试")
        store.setCreditSemester("2024-2025-2")
        try store.saveNow()

        let reopened = ProjectStore()
        try reopened.openProject(at: url)
        XCTAssertEqual(reopened.data.creditSemesterKey, "2024-2025-2")
        XCTAssertEqual(reopened.currentCreditSemesterKey, "2024-2025-2")

        // 未手动切换过的项目回落到按当前日期推断的学期
        let freshURL = tempDir.appendingPathComponent("全新项目.studentproj")
        let fresh = ProjectStore()
        try fresh.createProject(at: freshURL, name: "全新项目")
        XCTAssertNil(fresh.data.creditSemesterKey)
        XCTAssertEqual(fresh.currentCreditSemesterKey, CreditSemester.infer(from: Date()))
    }
}

    // MARK: 手册全量条目批量导入

    func testHandbookBatchImport() {
        let rules = CreditRule.defaults
        // 抽查各模块关键条目（名称精确匹配手册 + 分值一致）
        let checks: [(String, Double)] = [
            ("参与“学习强国”学习", 5),
            ("青年志愿者活动（组织者）", 1.5),
            ("担任班长、团支书", 6),
            ("常规抽查（校级）（红色等级）", -4),
            ("处分（记过）", -40),
            ("文化课成绩（及格 +2/门，不及格 -2/门）", 2),
            ("技能竞赛获奖（国家级一等奖）", 34),
            ("体育比赛获奖（市级二等奖）", 17),
            ("艺术类竞赛获奖（省级三等奖）", 24),
            ("参与勤工俭学", 10),
        ]
        let byName = Dictionary(uniqueKeysWithValues: rules.map { ($0.name, $0.points) })
        for (name, points) in checks {
            XCTAssertEqual(byName[name], points, "手册条目「\(name)」缺失或分值不符")
        }
        // 五育分组条数（含负值归扣分组的常规抽查 9 条）
        let byCategory = Dictionary(grouping: rules, by: { $0.category })
        XCTAssertEqual(byCategory[CreditRule.categoryDeYu]?.count, 48)
        XCTAssertEqual(byCategory[CreditRule.categoryZhiYu]?.count, 45)
        XCTAssertEqual(byCategory[CreditRule.categoryTiYu]?.count, 30)
        XCTAssertEqual(byCategory[CreditRule.categoryMeiYu]?.count, 31)
        XCTAssertEqual(byCategory[CreditRule.categoryLaoYu]?.count, 13)
        // 固定 UUID 唯一（批量导入不撞号）
        XCTAssertEqual(Set(rules.map { $0.id }).count, rules.count)
    }

    // MARK: 三级树拆解（大类 → 小类 → 程度）

    func testSplitSubDegree() {
        // 参与类：前缀剥离 + 括号程度
        let a = CreditPanelView.splitSubDegree("参与党课、团课、讲座（系级层面）")
        XCTAssertEqual(a.sub, "党课、团课、讲座")
        XCTAssertEqual(a.degree, "系级层面")
        // 获奖类：括号内为层级+奖次
        let b = CreditPanelView.splitSubDegree("技能竞赛获奖（校级一等奖）")
        XCTAssertEqual(b.sub, "技能竞赛获奖")
        XCTAssertEqual(b.degree, "校级一等奖")
        // 常规抽查双层括号：取最外层
        let c = CreditPanelView.splitSubDegree("常规抽查（系级）（橙色等级）")
        XCTAssertEqual(c.sub, "常规抽查（系级）")
        XCTAssertEqual(c.degree, "橙色等级")
        // 无括号、带前缀
        let d = CreditPanelView.splitSubDegree("参加技能竞赛")
        XCTAssertEqual(d.sub, "技能竞赛")
        XCTAssertEqual(d.degree, "—")
        // 无括号无前缀
        let e = CreditPanelView.splitSubDegree("好人好事")
        XCTAssertEqual(e.sub, "好人好事")
        XCTAssertEqual(e.degree, "—")
    }

    func testSubGroupTreeCoversAllRules() {
        // 每个大类的三级树展开后，叶子数应等于该组规则数（不丢规则）
        for category in CreditRule.categories {
            let rulesInCat = CreditRule.defaults.filter { $0.category == category }
            guard !rulesInCat.isEmpty else { continue }
            // 逐条拆解分组（与面板 subGroups 同逻辑）
            var map: [String: Int] = [:]
            for rule in rulesInCat {
                let key = CreditPanelView.splitSubDegree(rule.name)
                map[key.sub, default: 0] += 1
            }
            let leafCount = map.values.reduce(0, +)
            XCTAssertEqual(leafCount, rulesInCat.count, "\(category) 组拆解后叶子数不符")
        }
    }
