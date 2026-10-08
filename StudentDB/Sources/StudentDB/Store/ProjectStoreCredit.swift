import Foundation

// MARK: - 学分计算（记录 / 规则 / 学期）
//
// ProjectStore 的学分扩展（按域拆扩展，惯例同 ProjectStoreTables）：
// 记录留痕增删、规则整体替换、面板学期选择。学生引用一律存 Student.id；
// 总分不落库，由记录按学期累计（CreditSummary）。

extension ProjectStore {

    // MARK: 学期

    /// 面板当前所选学期（未手动切换过 = 按当前日期推断）
    var currentCreditSemesterKey: String {
        data.creditSemesterKey ?? CreditSemester.infer(from: Date())
    }

    /// 切换面板学期（记录写入时快照此值；切到上学期即可补录）
    func setCreditSemester(_ key: String) {
        guard data.creditSemesterKey != key else { return }
        mutateData { $0.creditSemesterKey = key }
        scheduleSave()
    }

    // MARK: 记录

    /// 对一批学生套用规则（一条记录；规则名/分值/学期为套用时刻快照）
    @discardableResult
    func addCreditRecord(studentIDs: [UUID], rule: CreditRule, semesterKey: String,
                         note: String = "", date: Date = Date()) -> CreditRecord? {
        guard !studentIDs.isEmpty else { return nil }
        let record = CreditRecord(id: UUID(), createdAt: date, studentIDs: studentIDs,
                                  ruleID: rule.id, ruleName: rule.name, points: rule.points,
                                  note: note, semesterKey: semesterKey)
        mutateData { $0.creditRecords.append(record) }
        scheduleSave()
        return record
    }

    /// 自定义分值记录（不挂规则，ruleID 为 nil；支持负数与 0.5 半分）
    @discardableResult
    func addCustomCreditRecord(studentIDs: [UUID], points: Double, name: String,
                               semesterKey: String, note: String = "",
                               date: Date = Date()) -> CreditRecord? {
        guard !studentIDs.isEmpty else { return nil }
        let record = CreditRecord(id: UUID(), createdAt: date, studentIDs: studentIDs,
                                  ruleID: nil, ruleName: name, points: points,
                                  note: note, semesterKey: semesterKey)
        mutateData { $0.creditRecords.append(record) }
        scheduleSave()
        return record
    }

    /// 删除单条记录（总分随之回到剩余记录的累计，不直接改写总分）
    /// 编辑学分记录（学生/分值/规则名/备注/日期/学期均可改；汇总按记录实时累计，自动对齐）
    func updateCreditRecord(_ record: CreditRecord) {
        mutateData { data in
            guard let idx = data.creditRecords.firstIndex(where: { $0.id == record.id }) else { return }
            data.creditRecords[idx] = record
        }
        scheduleSave()
    }

    func deleteCreditRecord(id: UUID) {
        mutateData { $0.creditRecords.removeAll { $0.id == id } }
        scheduleSave()
    }

    /// 某学期的流水（新 → 旧）
    func creditRecords(semesterKey: String) -> [CreditRecord] {
        data.creditRecords
            .filter { $0.semesterKey == semesterKey }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: 规则

    /// 整体替换规则表（编辑规则 sheet 确定时写回；历史记录存的是快照，不受影响）
    /// 每周无扣分结算：为符合条件的学生一次性记一条 +1（幂等——当周已结算的学生自动排除）
    /// 返回本次结算的学生数（0 = 没有符合条件的学生或已全部结算过）
    @discardableResult
    func settleWeeklyNoDeductBonus(week: DateInterval, semesterKey: String,
                                   date: Date = Date()) -> Int {
        let allIDs = data.students.map { $0.id }
        let qualifying = CreditWeeklyBonus.qualifyingStudents(
            allStudentIDs: allIDs, records: data.creditRecords, week: week)
        guard !qualifying.isEmpty,
              let rule = data.creditRules.first(where: { $0.id == CreditWeeklyBonus.bonusRuleID })
              ?? CreditRule.defaults.first(where: { $0.id == CreditWeeklyBonus.bonusRuleID }) else {
            return 0
        }
        let note = "周结算：\(CreditWeeklyBonus.weekLabel(for: week))"
        _ = addCreditRecord(studentIDs: qualifying, rule: rule,
                            semesterKey: semesterKey, note: note, date: date)
        return qualifying.count
    }

    /// 打开旧项目时补齐新增的内置规则（按固定 UUID 去重；不改用户已改过的分值/名称）
    func mergeMissingDefaultCreditRules() {
        let existing = Set(data.creditRules.map { $0.id })
        let missing = CreditRule.defaults.filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return }
        mutateData { data in
            data.creditRules.append(contentsOf: missing)
        }
        scheduleSave()
    }

    func updateCreditRules(_ rules: [CreditRule]) {
        mutateData { $0.creditRules = rules }
        scheduleSave()
    }

    // MARK: 删学生同步

    /// 学生被删除时清理学分记录里的引用；引用清空的记录整条删除（防悬挂 UUID）。
    /// 由 removeStudentLinks 在其 mutateData 事务内调用；返回是否有变更。
    static func removeStudentCreditLinks(studentID: UUID, in data: inout ProjectData) -> Bool {
        let before = data.creditRecords
        var next = before
        for idx in next.indices {
            next[idx].studentIDs.removeAll { $0 == studentID }
        }
        next.removeAll { $0.studentIDs.isEmpty }
        guard next != before else { return false }
        data.creditRecords = next
        return true
    }
}
