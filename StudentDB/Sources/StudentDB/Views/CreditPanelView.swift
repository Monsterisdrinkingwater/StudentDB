import SwiftUI

// MARK: - 学分管理面板
//
// 顶部醒目标注当前学期（可切换，近 4 个学期；记录/小计/合计按学期隔离）；
// 左侧选学生（搜索 + 按班级自定义字段筛选，多选，每行显示本学期小计）；
// 右侧规则按键区（扣分 / 参赛 / 获奖 三组，单击即套用）+ 自定义分值记录；
// 下方本学期流水留痕（日期时间、学生、规则名、分值、备注，可删单条）。
// 总分不落库，一律按记录累计（CreditSummary）。

struct CreditPanelView: View {
    @ObservedObject var store: ProjectStore

    @State private var selectedStudentIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var classFilter = ""
    @State private var showRuleSheet = false
    @State private var showCustomEntry = false
    @State private var showWeeklySettle = false
    @State private var editingRecord: CreditRecord?
    /// 大类展开状态（默认只展开扣分与每周奖励）
    @State private var expandedCategories: Set<String> = [CreditRule.categoryDeduct, CreditRule.categoryWeekly]

    // MARK: 派生数据

    private var semesterKey: String { store.currentCreditSemesterKey }

    /// 学期切换器选项：近 4 个学期；手动切换过的旧学期不在列表时补在最前
    private var semesterOptions: [String] {
        var keys = CreditSemester.recentSemesters(from: Date())
        if !keys.contains(semesterKey) {
            keys.insert(semesterKey, at: 0)
        }
        return keys
    }

    private var semesterRecords: [CreditRecord] {
        store.creditRecords(semesterKey: semesterKey)
    }

    private var studentTotals: [UUID: Double] {
        CreditSummary.studentTotals(records: store.data.creditRecords, semesterKey: semesterKey)
    }

    private var semesterTotal: Double {
        CreditSummary.semesterTotal(records: store.data.creditRecords, semesterKey: semesterKey)
    }

    /// 班级是文档建议的自定义字段（项目无内置班级实体）；字段不存在时不显示班级筛选
    private var classField: CustomField? {
        store.data.fieldDefinitions.first { $0.name == "班级" }
    }

    private var classOptions: [String] {
        guard let classField else { return [] }
        let key = classField.id.uuidString
        return Array(Set(store.data.students.compactMap { $0.customValues[key]?.displayText })
            .filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filteredStudents: [Student] {
        var list = store.data.students
        if let classField, !classFilter.isEmpty {
            let key = classField.id.uuidString
            list = list.filter { $0.customValues[key]?.displayText == classFilter }
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(keyword)
                    || $0.studentNumber.localizedCaseInsensitiveContains(keyword)
            }
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 规则套用对象：选中优先，未选则为筛选出的全部学生
    private var targetStudentIDs: [UUID] {
        selectedStudentIDs.isEmpty ? filteredStudents.map(\.id) : Array(selectedStudentIDs)
    }

    private var targetHint: String {
        selectedStudentIDs.isEmpty
            ? "未选学生：点规则将对筛选出的全部 \(filteredStudents.count) 名学生记分"
            : "已选 \(selectedStudentIDs.count) 名学生：点规则为其记分"
    }

    // MARK: 界面

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                studentList
                    .frame(width: 260)
                Divider()
                ruleArea
                    .frame(height: 300)
            }
            Divider()
            recordArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showRuleSheet) {
            CreditRuleSheet(store: store)
        }
        .sheet(item: $editingRecord) { record in
            CreditRecordEditSheet(store: store, record: record)
        }
        .sheet(isPresented: $showWeeklySettle) {
            WeeklyBonusSettleSheet(store: store, semesterKey: semesterKey)
        }
        .sheet(isPresented: $showCustomEntry) {
            CustomCreditEntrySheet(store: store,
                                   studentIDs: targetStudentIDs,
                                   semesterKey: semesterKey)
        }
    }

    /// 顶部：学期醒目标注 + 切换器 + 本学期合计 + 编辑规则
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CreditSemester.displayName(for: semesterKey))
                    .font(.title2.weight(.bold))
                Text("学分管理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("学期", selection: semesterBinding) {
                ForEach(semesterOptions, id: \.self) { key in
                    Text(CreditSemester.displayName(for: key)).tag(key)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            .help("切换学期：记录在录入时归属当时所选学期，可切回上学期补录")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("本学期合计")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(CreditSummary.signedPointsText(semesterTotal))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(semesterTotal < 0 ? Color.red : (semesterTotal > 0 ? Color.green : Color.primary))
            }
            Button {
                showRuleSheet = true
            } label: {
                Label("编辑规则…", systemImage: "slider.horizontal.3")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var semesterBinding: Binding<String> {
        Binding(
            get: { semesterKey },
            set: { store.setCreditSemester($0) }
        )
    }

    /// 左侧：学生多选（搜索 + 班级筛选，每行显示本学期小计）
    private var studentList: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("搜索姓名、学号", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
            )
            if let classField {
                Picker("班级", selection: $classFilter) {
                    Text("全部班级").tag("")
                    ForEach(classOptions, id: \.self) { value in
                        Text("\(classField.name)：\(value)").tag(value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(targetHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            // .sidebar 样式不支持 Set 多选，用 .inset（惯例同侧栏学生列表）
            List(selection: $selectedStudentIDs) {
                ForEach(filteredStudents) { student in
                    HStack(spacing: 8) {
                        AvatarView(name: student.name)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(student.name.isEmpty ? "（未命名）" : student.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Text(student.studentNumber.isEmpty ? "未填学号" : "学号 \(student.studentNumber)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(CreditSummary.signedPointsText(studentTotals[student.id] ?? 0))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(pointsColor(studentTotals[student.id] ?? 0))
                    }
                    .tag(student.id)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
        }
        .padding(12)
    }

    /// 右侧：规则按键区（三级树：大类 → 小类 → 程度）+ 工具入口
    /// 程度只有一个的小类，点小类行直接套用；多个程度在行内以小按钮选择。
    private var ruleArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(CreditRule.categories, id: \.self) { category in
                    let groups = subGroups(in: category)
                    if !groups.isEmpty {
                        DisclosureGroup(isExpanded: bindingForCategory(category)) {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(groups, id: \.sub) { group in
                                    subGroupRow(group)
                                }
                            }
                            .padding(.top, 2)
                        } label: {
                            Label(categoryTitle(category), systemImage: categoryIcon(category))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Button {
                    showWeeklySettle = true
                } label: {
                    Label("每周无扣分结算…", systemImage: "checkmark.seal")
                }
                .help("一周内没有任何扣分记录（校纪校规全部子项 + 自定义扣分）的学生 +1 分")
                Button {
                    showCustomEntry = true
                } label: {
                    Label("自定义分值记录…", systemImage: "square.and.pencil")
                }
                .help("记一条不挂规则的临时分值（支持负数与 0.5 半分）")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 三级树构造（大类 → 小类 → 程度）

    private struct DegreeOption: Identifiable {
        let degree: String     // "—" = 无程度（单档）
        let rule: CreditRule
        var id: String { degree }
    }
    private struct SubGroup: Identifiable {
        let sub: String
        var options: [DegreeOption]
        var id: String { sub }
    }

    /// 小类名拆解：去掉「参与/参加」前缀；最外层括号内为程度
    static func splitSubDegree(_ name: String) -> (sub: String, degree: String) {
        guard let m = name.range(of: "[（(]([^）)]*)[）)]$",
                                 options: .regularExpression,
                                 range: name.startIndex..<name.endIndex) else {
            var sub = name
            for prefix in ["参与", "参加"] where sub.hasPrefix(prefix) {
                sub = String(sub.dropFirst(prefix.count))
            }
            return (sub, "—")
        }
        let inner = name[m].trimmingCharacters(in: CharacterSet(charactersIn: "（）()"))
        var head = String(name[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
        for prefix in ["参与", "参加"] where head.hasPrefix(prefix) {
            head = String(head.dropFirst(prefix.count))
        }
        return (head, inner.isEmpty ? "—" : inner)
    }

    private func subGroups(in category: String) -> [SubGroup] {
        var order: [String] = []
        var map: [String: [DegreeOption]] = [:]
        for rule in rules(in: category) {
            let key = Self.splitSubDegree(rule.name)
            if map[key.sub] == nil { order.append(key.sub) }
            map[key.sub, default: []].append(DegreeOption(degree: key.degree, rule: rule))
        }
        return order.map { sub in
            SubGroup(sub: sub, options: map[sub]!.sorted {
                $0.rule.points < $1.rule.points
            })
        }
    }

    /// 小类行：单程度 → 点击即用；多程度 → 程度小按钮组
    @ViewBuilder
    private func subGroupRow(_ group: SubGroup) -> some View {
        if group.options.count == 1, let only = group.options.first {
            ruleButton(only.rule, title: group.sub)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.sub)
                    .font(.callout.weight(.medium))
                    .frame(width: 148, alignment: .leading)
                    .lineLimit(1)
                    .help(group.sub)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], spacing: 6) {
                    ForEach(group.options) { option in
                        degreeButton(option.rule, degree: option.degree)
                    }
                }
            }
        }
    }

    private func degreeButton(_ rule: CreditRule, degree: String) -> some View {
        Button {
            apply(rule)
        } label: {
            VStack(spacing: 1) {
                Text(degree)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(CreditSummary.signedPointsText(rule.points))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(rule.points < 0 ? Color.red : Color.green)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rule.name)
    }

    private func bindingForCategory(_ category: String) -> Binding<Bool> {
        Binding(
            get: { expandedCategories.contains(category) },
            set: { if $0 { expandedCategories.insert(category) } else { expandedCategories.remove(category) } }
        )
    }

    private func rules(in category: String) -> [CreditRule] {
        store.data.creditRules
            .filter { $0.category == category }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    private func categoryTitle(_ category: String) -> String {
        switch category {
        case CreditRule.categoryDeduct: return "扣分"
        case CreditRule.categoryContest: return "参赛（参加即加分）"
        case CreditRule.categoryAward: return "获奖"
        default: return category
        }
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case CreditRule.categoryDeduct: return "minus.circle"
        case CreditRule.categoryWeekly: return "checkmark.seal"
        case CreditRule.categoryContest: return "flag"
        case CreditRule.categoryAward: return "medal"
        case CreditRule.categoryDeYu: return "heart.text.square"
        case CreditRule.categoryZhiYu: return "book"
        case CreditRule.categoryTiYu: return "figure.run"
        case CreditRule.categoryMeiYu: return "paintpalette"
        case CreditRule.categoryLaoYu: return "leaf"
        default: return "tag"
        }
    }

    private func ruleButton(_ rule: CreditRule, title: String? = nil) -> some View {
        Button {
            apply(rule)
        } label: {
            VStack(spacing: 2) {
                Text(title ?? rule.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(CreditSummary.signedPointsText(rule.points))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(rule.points < 0 ? Color.red : Color.green)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("为\(selectedStudentIDs.isEmpty ? "筛选出的全部学生" : "选中的学生")套用「\(rule.name)」")
    }

    private func apply(_ rule: CreditRule) {
        let ids = targetStudentIDs
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        store.addCreditRecord(studentIDs: ids, rule: rule, semesterKey: semesterKey)
    }

    /// 下方：本学期流水留痕（可删单条，删除即回到剩余记录的累计口径）
    private var recordArea: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本学期流水 · \(semesterRecords.count) 条")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            List {
                ForEach(semesterRecords) { record in
                    recordRow(record)
                }
            }
            .listStyle(.inset)
            .overlay {
                if semesterRecords.isEmpty {
                    ContentUnavailableView(
                        "本学期暂无学分记录",
                        systemImage: "star",
                        description: Text("在上方按键为学生加 / 减学分，或使用自定义分值记录。")
                    )
                }
            }
        }
    }

    private func recordRow(_ record: CreditRecord) -> some View {
        HStack(spacing: 10) {
            Text(Fmt.dateTime.string(from: record.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(record.studentNames(in: store.data.students))
                .font(.callout)
                .lineLimit(1)
            Text(record.ruleName.isEmpty ? "自定义" : record.ruleName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 12)
            if !record.note.isEmpty {
                Text(record.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(CreditSummary.signedPointsText(record.points))
                .font(.callout.weight(.semibold))
                .foregroundStyle(pointsColor(record.points))
                .frame(width: 48, alignment: .trailing)
            Button(role: .destructive) {
                store.deleteCreditRecord(id: record.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除该记录（总分按剩余记录累计）")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editingRecord = record }
        .help("点击编辑该记录")
    }

    private func pointsColor(_ points: Double) -> Color {
        points > 0 ? .green : (points < 0 ? .red : .secondary)
    }
}

// MARK: - 自定义分值记录（不挂规则）

/// 临时分值 + 备注，对当前目标学生记一条（ruleID 为 nil）
private struct CustomCreditEntrySheet: View {
    @ObservedObject var store: ProjectStore
    let studentIDs: [UUID]
    let semesterKey: String
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var pointsText = ""
    @State private var note = ""

    private var parsedPoints: Double? {
        Double(pointsText.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("自定义分值记录")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 6)

            Text("对\(studentIDs.count)名学生记一条不挂规则的学分记录，记入\(CreditSemester.displayName(for: semesterKey))。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()

            Form {
                TextField("名称（选填，留空显示“自定义”）", text: $name)
                TextField("分值（支持负数与 0.5，如 -1 或 0.5）", text: $pointsText)
                TextField("备注（选填）", text: $note)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            Divider()

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("记录", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedPoints == nil || studentIDs.isEmpty)
            }
            .padding(16)
        }
        .resizableSheet(minWidth: 380, minHeight: 250, idealWidth: 430, idealHeight: 310)
    }

    private func save() {
        guard let points = parsedPoints, !studentIDs.isEmpty else { return }
        store.addCustomCreditRecord(
            studentIDs: studentIDs,
            points: points,
            name: name.trimmingCharacters(in: .whitespaces),
            semesterKey: semesterKey,
            note: note.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

// MARK: - 每周无扣分结算（校纪校规 + 打扫卫生）

/// 选周 → 预览符合条件的学生 → 一键结算 +1（幂等：当周已结算学生自动排除）
struct WeeklyBonusSettleSheet: View {
    @ObservedObject var store: ProjectStore
    let semesterKey: String
    @Environment(\.dismiss) private var dismiss

    /// 默认结算上一个完整周（本周通常还没过完）
    @State private var week: DateInterval = CreditWeeklyBonus.weekInterval(
        containing: Date().addingTimeInterval(-7 * 24 * 3600))
    @State private var settledNotice = ""

    private var allStudentIDs: [UUID] { store.data.students.map { $0.id } }
    private var qualifying: [UUID] {
        CreditWeeklyBonus.qualifyingStudents(allStudentIDs: allStudentIDs,
                                             records: store.data.creditRecords, week: week)
    }
    private var alreadySettledCount: Int {
        let week_ = week
        let settled = store.data.creditRecords
            .filter { $0.ruleID == CreditWeeklyBonus.bonusRuleID && week_.contains($0.createdAt) }
            .flatMap { $0.studentIDs }
        return Set(settled).count
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("每周无扣分结算")
                    .font(.headline)
                Text("一周内没有任何扣分记录（校纪校规全部子项 + 自定义扣分）的学生 +1 分")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            HStack {
                Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("上一周")
                Text(CreditWeeklyBonus.weekLabel(for: week))
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 150)
                Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .help("下一周")
                Spacer()
                if !settledNotice.isEmpty {
                    Label(settledNotice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                let names = qualifying.compactMap { id in
                    store.data.students.first { $0.id == id }?.name
                }
                HStack {
                    Text("符合条件：\(names.count) 名学生")
                        .font(.callout.weight(.medium))
                    if alreadySettledCount > 0 {
                        Text("（该周已结算 \(alreadySettledCount) 名，自动排除）")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                if names.isEmpty {
                    Text("该周没有符合条件的学生（所有人都有扣分记录，或已结算过）。")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
                            ForEach(names, id: \.self) { name in
                                Text(name)
                                    .font(.callout)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(nsColor: .controlBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            HStack {
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("为 \(qualifying.count) 名学生结算 +1") {
                    let count = store.settleWeeklyNoDeductBonus(
                        week: week, semesterKey: semesterKey,
                        date: week.start.addingTimeInterval(6 * 24 * 3600 + 18 * 3600))
                    settledNotice = count > 0 ? "已结算 \(count) 人" : "无需结算"
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(qualifying.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 460)
    }

    private func shiftWeek(_ weeks: Int) {
        settledNotice = ""
        week = DateInterval(start: week.start.addingTimeInterval(Double(weeks) * 7 * 24 * 3600),
                            duration: week.duration)
    }
}

// MARK: - 学分记录编辑（点击流水行打开）

/// 编辑一条学分记录：学生（多选）、分值、名称、备注、日期时间、学期归属。
/// 汇总不落库、按记录实时累计，保存即对齐。
struct CreditRecordEditSheet: View {
    @ObservedObject var store: ProjectStore
    let record: CreditRecord
    @Environment(\.dismiss) private var dismiss

    @State private var studentIDs: Set<UUID> = []
    @State private var pointsText: String = ""
    @State private var name: String = ""
    @State private var note: String = ""
    @State private var date: Date = Date()
    @State private var semesterKey: String = ""
    @State private var loaded = false

    private var pointsValue: Double? { Double(pointsText.replacingOccurrences(of: ",", with: ".")) }
    private var isValid: Bool {
        !studentIDs.isEmpty && pointsValue != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑学分记录")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section("学生（可多选）") {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                            ForEach(store.data.students) { student in
                                let selected = studentIDs.contains(student.id)
                                Button {
                                    if selected { studentIDs.remove(student.id) }
                                    else { studentIDs.insert(student.id) }
                                } label: {
                                    Text(student.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .frame(maxWidth: .infinity)
                                        .background(selected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor),
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(selected ? Color.accentColor : .clear))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 150)
                }
                Section("记录内容") {
                    TextField("名称（如：违反校纪校规 / 自定义）", text: $name)
                    HStack {
                        TextField("分值（负数=扣分，支持 0.5）", text: $pointsText)
                        if let v = pointsValue {
                            Text(CreditSummary.signedPointsText(v))
                                .foregroundStyle(pointsColor(v))
                                .frame(width: 44)
                        }
                    }
                    DatePicker("日期时间", selection: $date)
                    Picker("学期", selection: $semesterKey) {
                        ForEach(CreditSemester.recentSemesters(from: Date()), id: \.self) { key in
                            Text(CreditSemester.displayName(for: key)).tag(key)
                        }
                    }
                    TextField("备注", text: $note)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            studentIDs = Set(record.studentIDs)
            pointsText = CreditSummary.pointsText(record.points)
            name = record.ruleName
            note = record.note
            date = record.createdAt
            semesterKey = record.semesterKey
        }
    }

    private func pointsColor(_ points: Double) -> Color {
        points > 0 ? .green : (points < 0 ? .red : .secondary)
    }

    private func save() {
        guard let points = pointsValue else { return }
        // 按学生表顺序排列选中 id（类型显式化，避免大表达式超时）
        let nameByID: [UUID: String] = Dictionary(
            uniqueKeysWithValues: store.data.students.map { ($0.id, $0.name) })
        let ordered: [UUID] = store.data.students
            .filter { studentIDs.contains($0.id) }
            .map { $0.id }

        var updated = record
        updated.studentIDs = ordered.isEmpty ? Array(studentIDs) : ordered
        updated.points = points
        updated.ruleName = name.trimmingCharacters(in: .whitespaces)
        updated.note = note.trimmingCharacters(in: .whitespaces)
        updated.createdAt = date
        updated.semesterKey = semesterKey
        _ = nameByID   // 保留按名查的语义（当前按表序，无需名字）
        store.updateCreditRecord(updated)
        dismiss()
    }
}
