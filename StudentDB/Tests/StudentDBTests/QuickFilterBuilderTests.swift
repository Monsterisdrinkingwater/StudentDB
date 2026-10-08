import XCTest
@testable import StudentDB

/// 快捷筛选统一构造器：值控件映射、条件生成、条件说明
final class QuickFilterBuilderTests: XCTestCase {

    private func spec(fields: [CustomField] = [], builtinDeleted: Set<String> = []) -> [StudentColumnSpec] {
        StudentColumnSpec.allColumns(fields: fields, guardianSlots: 1,
                                     builtinOrder: [], deletedBuiltin: builtinDeleted)
    }

    // MARK: 值控件映射

    func testValueInputMapping() {
        let columns = spec(fields: [
            CustomField(name: "性别", type: .choice(options: ["男", "女"])),
            CustomField(name: "是否团员", type: .boolean),
            CustomField(name: "班级", type: .text),
        ])
        let boarding = columns.first { $0.field == .boarding }!
        let name = columns.first { $0.field == .name }!
        let guardianPhone = columns.first { $0.id == "guardian1-phone" }!
        let choice = columns.first { $0.customField?.name == "性别" }!
        let boolean = columns.first { $0.customField?.name == "是否团员" }!
        let text = columns.first { $0.customField?.name == "班级" }!

        // 内置住宿列：勾选 → 住宿/走读（与列显示文字一致）
        XCTAssertEqual(QuickFilterBuilder.valueInput(for: boarding), .boolPick(trueValue: "住宿", falseValue: "走读"))
        // 自定义是/否字段：勾选 → 是/否
        XCTAssertEqual(QuickFilterBuilder.valueInput(for: boolean), .boolPick(trueValue: "是", falseValue: "否"))
        // 单选/多选 → 从选项中选一个
        XCTAssertEqual(QuickFilterBuilder.valueInput(for: choice), .options(["男", "女"]))
        // 其他列 → 文本
        XCTAssertEqual(QuickFilterBuilder.valueInput(for: name), .text)
        XCTAssertEqual(QuickFilterBuilder.valueInput(for: text), .text)
        XCTAssertEqual(QuickFilterBuilder.valueInput(for: guardianPhone), .text)
    }

    func testConditionIsColumnContains() {
        let condition = QuickFilterBuilder.condition(columnID: "policeStation", value: "朝阳所")
        XCTAssertEqual(condition, .columnContains(columnID: "policeStation", value: "朝阳所"))
    }

    // MARK: 条件说明

    func testCaptionShowsColumnName() {
        let columns = spec(fields: [CustomField(name: "班级", type: .text)])
        let classColumn = columns.first { $0.customField?.name == "班级" }!
        let police = columns.first { $0.field == .policeStation }!

        XCTAssertEqual(QuickFilterBuilder.caption(
            for: .columnContains(columnID: police.id, value: "朝阳"), columns: columns),
            "「派出所」包含「朝阳」")
        // 列已不存在（如字段被删）时退回旧文案
        XCTAssertEqual(QuickFilterBuilder.caption(
            for: .columnContains(columnID: "missing", value: "x"), columns: columns),
            "包含「x」")
        // 旧版自定义字段条件也带列名
        XCTAssertEqual(QuickFilterBuilder.caption(
            for: .customField(fieldID: classColumn.customField!.id, value: "三（2）班"), columns: columns),
            "「班级」包含「三（2）班」")
        // 旧版内置条件沿用原文案
        XCTAssertEqual(QuickFilterBuilder.caption(for: .boarding(true), columns: columns), "住宿学生")
        XCTAssertEqual(QuickFilterBuilder.caption(for: .all, columns: columns), "全部学生")
    }

    // MARK: 与查询的端到端一致性

    func testGeneratedConditionFiltersStudents() {
        let columns = spec()
        let boarding = columns.first { $0.field == .boarding }!

        var a = Student(); a.name = "甲"; a.isBoarding = true
        var b = Student(); b.name = "乙"; b.isBoarding = false

        // 勾选列生成的条件（包含「住宿」）应与旧 .boarding(true) 筛出同一批学生
        let newCondition = QuickFilterBuilder.condition(columnID: boarding.id, value: "住宿")
        let byNew = StudentQuery.filter(
            view: ListView(name: "t", condition: newCondition), students: [a, b], fields: [])
        let byOld = StudentQuery.filter(
            view: ListView(name: "t", condition: .boarding(true)), students: [a, b], fields: [])
        XCTAssertEqual(byNew.map(\.name), byOld.map(\.name))
        XCTAssertEqual(byNew.map(\.name), ["甲"])

        let walk = StudentQuery.filter(
            view: ListView(name: "t", condition: QuickFilterBuilder.condition(columnID: boarding.id, value: "走读")),
            students: [a, b], fields: [])
        XCTAssertEqual(walk.map(\.name), ["乙"])
    }
}
