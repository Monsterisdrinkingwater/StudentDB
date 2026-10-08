import XCTest
@testable import StudentDB

/// 每周无扣分奖励（校纪校规 + 打扫卫生）：周区间、资格判定、幂等、结算存取
@MainActor
final class WeeklyBonusTests: XCTestCase {

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = hour
        return Calendar.current.date(from: comps)!
    }

    // MARK: 周区间

    func testWeekIntervalMondayToSunday() {
        // 2026-10-05 是周一，2026-10-11 是周日
        let monday = makeDate(2026, 10, 5)
        let interval = CreditWeeklyBonus.weekInterval(containing: monday)
        XCTAssertEqual(interval.start, Calendar.current.startOfDay(for: monday))
        XCTAssertEqual(interval.duration, 7 * 24 * 3600)
        // 周日 23 点仍在同一周
        let sundayNight = makeDate(2026, 10, 11, hour: 23)
        XCTAssertTrue(interval.contains(sundayNight))
        // 下周一已在下一周
        XCTAssertFalse(interval.contains(makeDate(2026, 10, 12)))
        // 周中任意一天归到同一周
        let wednesday = makeDate(2026, 10, 7)
        XCTAssertEqual(CreditWeeklyBonus.weekInterval(containing: wednesday), interval)
    }

    // MARK: 资格判定

    private func makeRecord(ruleID: UUID?, students: [UUID], at date: Date,
                            points: Double = 0) -> CreditRecord {
        var r = CreditRecord()
        r.createdAt = date
        r.studentIDs = students
        r.ruleID = ruleID
        r.points = points
        r.semesterKey = "2026-2027-1"
        return r
    }

    func testQualifyingExcludesDeductedAndSettled() throws {
        let students = [UUID(), UUID(), UUID(), UUID()]
        let week = CreditWeeklyBonus.weekInterval(containing: makeDate(2026, 10, 5))

        var records: [CreditRecord] = []
        // 学生0：内置规则扣分 → 取消
        records.append(makeRecord(ruleID: UUID(), students: [students[0]],
                                  at: week.start + 3600, points: -2))
        // 学生1：自定义扣分（ruleID=nil；改名/删除过的规则同理）→ 也必须取消
        records.append(makeRecord(ruleID: nil, students: [students[1]],
                                  at: week.start + 7200, points: -1.5))
        // 学生2：当周已结算过 → 排除
        records.append(makeRecord(ruleID: CreditWeeklyBonus.bonusRuleID,
                                  students: [students[2]], at: week.start + 3600, points: 1))
        // 学生3：加分项（参赛）不取消资格
        records.append(makeRecord(ruleID: UUID(), students: [students[3]],
                                  at: week.start + 5400, points: 2))

        let qualifying = CreditWeeklyBonus.qualifyingStudents(
            allStudentIDs: students, records: records, week: week)
        XCTAssertEqual(qualifying, [students[3]], "内置扣分、自定义扣分、已结算的都要排除；加分不排除")

        // 无任何记录 → 全部符合
        let all = CreditWeeklyBonus.qualifyingStudents(
            allStudentIDs: students, records: [], week: week)
        XCTAssertEqual(all, students)

        // 上周的扣分不影响本周
        var lastWeekRecords = records.filter { $0.points < 0 }
        let lastWeek = CreditWeeklyBonus.weekInterval(containing: makeDate(2026, 9, 28))
        for i in lastWeekRecords.indices {
            lastWeekRecords[i].createdAt = lastWeek.start + 3600
        }
        let currentWeek = CreditWeeklyBonus.qualifyingStudents(
            allStudentIDs: students, records: lastWeekRecords, week: week)
        XCTAssertEqual(currentWeek, students, "上周扣分不影响本周资格")
    }

    // MARK: 结算存取（幂等）

    func testSettleIdempotent() throws {
        let store = ProjectStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("weekly-\(UUID().uuidString).studentproj")
        try store.createProject(at: dir, name: "库")
        for name in ["甲", "乙", "丙"] {
            var s = Student(); s.name = name; store.addStudent(s)
        }
        let week = CreditWeeklyBonus.weekInterval(containing: makeDate(2026, 10, 5))

        // 乙在当周被扣分（违反校纪校规）
        let deductRule = try XCTUnwrap(store.data.creditRules.first { $0.name == "违反校纪校规" })
        _ = store.addCreditRecord(studentIDs: [store.data.students[1].id], rule: deductRule,
                                  semesterKey: "2026-2027-1", date: week.start + 3600)

        // 第一次结算：甲、丙两人 +1
        let first = store.settleWeeklyNoDeductBonus(week: week, semesterKey: "2026-2027-1")
        XCTAssertEqual(first, 2)
        let bonusRuleID = CreditWeeklyBonus.bonusRuleID
        let totals = CreditSummary.studentTotals(records: store.data.creditRecords,
                                                 semesterKey: "2026-2027-1")
        XCTAssertEqual(totals[store.data.students[0].id], 1)
        XCTAssertEqual(totals[store.data.students[1].id], -2, "被扣分的学生只有扣分记录")
        XCTAssertEqual(totals[store.data.students[2].id], 1)

        // 重复结算同一周：0（幂等），分数不变
        let second = store.settleWeeklyNoDeductBonus(week: week, semesterKey: "2026-2027-1")
        XCTAssertEqual(second, 0)
        let totals2 = CreditSummary.studentTotals(records: store.data.creditRecords,
                                                  semesterKey: "2026-2027-1")
        XCTAssertEqual(totals2, totals)

        // 结算记录留痕：规则名、分值、周备注
        let record = try XCTUnwrap(store.data.creditRecords.first { $0.ruleID == bonusRuleID })
        XCTAssertEqual(record.ruleName, "校纪校规与打扫卫生一周无扣分")
        XCTAssertEqual(record.points, 1)
        XCTAssertTrue(record.note.contains("10月5日"))
        XCTAssertTrue(CreditWeeklyBonus.weekInterval(containing: record.createdAt).contains(week.start + 1))
    }

    // MARK: 旧项目迁移补规则

    func testMergeMissingDefaultRules() throws {
        let store = ProjectStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-\(UUID().uuidString).studentproj")
        try store.createProject(at: dir, name: "库")
        // 模拟旧项目：规则里没有每周奖励（删掉后不再自动补——merge 只在打开时跑）
        var rules = store.data.creditRules
        rules.removeAll { $0.category == CreditRule.categoryWeekly }
        store.updateCreditRules(rules)
        // 直接调用迁移逻辑：缺失的默认规则应被补回
        let before = store.data.creditRules.count
        store.mergeMissingDefaultCreditRules()
        XCTAssertEqual(store.data.creditRules.count, before + 1)
        XCTAssertTrue(store.data.creditRules.contains {
            $0.name == "校纪校规与打扫卫生一周无扣分" && $0.points == 1
        })
        // 重复调用不重复补
        store.mergeMissingDefaultCreditRules()
        XCTAssertEqual(store.data.creditRules.count, before + 1)
    }
}

/// 学分记录编辑：保存后汇总实时对齐、删除即撤销
@MainActor
final class CreditRecordEditTests: XCTestCase {

    func testUpdateAlignsTotalsImmediately() throws {
        let store = ProjectStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-\(UUID().uuidString).studentproj")
        try store.createProject(at: dir, name: "库")
        for name in ["甲", "乙"] {
            var s = Student(); s.name = name; store.addStudent(s)
        }
        let rule = try XCTUnwrap(store.data.creditRules.first { $0.name == "违反校纪校规" })
        let ids = store.data.students.map { $0.id }

        // 甲 -2（误录），编辑改成 乙、+0.5、改备注日期学期不变
        var record = try XCTUnwrap(store.addCreditRecord(
            studentIDs: [ids[0]], rule: rule, semesterKey: "2026-2027-1"))
        var totals = CreditSummary.studentTotals(records: store.data.creditRecords,
                                                 semesterKey: "2026-2027-1")
        XCTAssertEqual(totals[ids[0]], -2)

        record.studentIDs = [ids[1]]
        record.points = 0.5
        record.note = "更正记录"
        store.updateCreditRecord(record)

        totals = CreditSummary.studentTotals(records: store.data.creditRecords,
                                             semesterKey: "2026-2027-1")
        XCTAssertNil(totals[ids[0]], "甲的记录改走后小计应清零")
        XCTAssertEqual(totals[ids[1]], 0.5, "乙立即获得更正后的分值")

        // 改学期归属：移出当前学期
        record.semesterKey = "2025-2026-2"
        store.updateCreditRecord(record)
        totals = CreditSummary.studentTotals(records: store.data.creditRecords,
                                             semesterKey: "2026-2027-1")
        XCTAssertNil(totals[ids[1]], "学期改走后本学期小计清零")

        // 删除 = 撤销
        store.deleteCreditRecord(id: record.id)
        XCTAssertTrue(store.data.creditRecords.isEmpty)
    }
}
