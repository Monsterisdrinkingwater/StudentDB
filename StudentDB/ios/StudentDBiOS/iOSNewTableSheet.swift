import SwiftUI

// MARK: - 新建数据表（iOS 版，带模板）

/// 模板选择（LazyVGrid 卡片）+ 表名 + 字段行（名称 + 类型）→ store.addTable。
/// 模板清单与字段预设与 macOS 版 NewTableSheet.Template 对齐
/// （Sources/StudentDB/Views/TableViews.swift），此处为 SwiftUI 原生实现，不移植 AppKit 代码。
struct IOSNewTableSheet: View {
    @ObservedObject var store: ProjectStore
    /// 创建成功回调（数据表页用来回到列表）
    var onCreated: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    // MARK: 模板（与 macOS 版一致：自定义表从空白开始，其余提供预设字段）

    enum Template: String, CaseIterable, Identifiable {
        case blankCustom = "自定义表"
        case qingjia = "请假记录"
        case xueqing = "学情周报"
        case yibiao = "一表多清摸排"
        case observation = "平时观察"
        case medication = "精神药品服用"
        case campusConflict = "校园矛盾排查"
        case suspendFollowup = "休学电话随访"
        case focusFollowup = "重点电话随访"
        case focusHomeVisit = "重点家访记录"
        case focusTalk = "重点谈心谈话"
        case blankRecord = "空白记录表"

        var id: String { rawValue }

        var kind: TableKind {
            switch self {
            case .blankCustom: return .custom
            case .qingjia, .xueqing, .yibiao, .observation, .medication, .campusConflict,
                 .suspendFollowup, .focusFollowup, .focusHomeVisit, .focusTalk, .blankRecord:
                return .record
            }
        }

        var defaultName: String {
            switch self {
            case .blankCustom: return ""
            case .qingjia: return "请假记录"
            case .xueqing: return "学情周报"
            case .yibiao: return "一表多清摸排"
            case .observation: return "平时观察"
            case .medication: return "精神药品服用"
            case .campusConflict: return "校园矛盾排查"
            case .suspendFollowup: return "休学学生电话随访"
            case .focusFollowup: return "重点学生电话随访"
            case .focusHomeVisit: return "重点学生家访"
            case .focusTalk: return "重点学生谈心谈话"
            case .blankRecord: return "新记录表"
            }
        }

        /// 卡片图标（iOS 版新增：网格卡片以图标+名称呈现）
        var systemImage: String {
            switch self {
            case .blankCustom: return "tablecells"
            case .qingjia: return "calendar.badge.exclamationmark"
            case .xueqing: return "chart.line.uptrend.xyaxis"
            case .yibiao: return "checklist"
            case .observation: return "eye"
            case .medication: return "pills"
            case .campusConflict: return "exclamationmark.shield"
            case .suspendFollowup: return "phone.arrow.down.left"
            case .focusFollowup: return "phone.badge.checkmark"
            case .focusHomeVisit: return "house"
            case .focusTalk: return "text.bubble"
            case .blankRecord: return "square.and.pencil"
            }
        }
    }

    /// 字段草稿行（建表前在本地编辑，创建时映射为 CustomField）
    private struct FieldDraft {
        var name: String
        var type: FieldType
    }

    @State private var name = ""
    @State private var selectedTemplate: Template = .blankCustom
    @State private var fields: [FieldDraft] = [FieldDraft(name: "名称", type: .text)]

    /// 类型选择器的候选：FieldType.selectableTypes + 关联学生（与 macOS 版字段行一致）
    private var typeChoices: [FieldType] {
        FieldType.selectableTypes + [.linkStudents]
    }

    // MARK: 界面

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    templateSection
                    nameSection
                    fieldSection
                }
                .padding(16)
            }
            .navigationTitle("新建数据表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { create() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                // sheet 复用会残留 @State：每次打开强制按当前模板重置
                applyTemplate(selectedTemplate)
            }
        }
    }

    // MARK: 模板卡片

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模板")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())],
                      spacing: 8) {
                ForEach(Template.allCases) { template in
                    templateCard(template)
                }
            }
            .onChange(of: selectedTemplate) { _, template in
                applyTemplate(template)
            }
        }
    }

    private func templateCard(_ template: Template) -> some View {
        let selected = selectedTemplate == template
        return Button {
            selectedTemplate = template
        } label: {
            VStack(spacing: 5) {
                Image(systemName: template.systemImage)
                    .font(.title3)
                Text(template.rawValue)
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                selected ? Color.accentColor.opacity(0.16)
                         : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(
                    selected ? Color.accentColor.opacity(0.6)
                             : Color(uiColor: .separator).opacity(0.5),
                    lineWidth: 1
                )
            )
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 表名

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("表名")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("留空使用模板默认名", text: $name)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: 字段行

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("字段")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    fields.append(FieldDraft(name: "", type: .text))
                } label: {
                    Label("添加字段", systemImage: "plus")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            }

            ForEach(fields.indices, id: \.self) { index in
                fieldRow(index: index)
            }

            Text("单选 / 多选的选项内容按模板预设带入，建表后可在字段管理中调整。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func fieldRow(index: Int) -> some View {
        // 删除行后的过渡帧可能带着旧 index 重绘：取不到就给占位草稿，避免越界
        let draft = fields.indices.contains(index)
            ? fields[index]
            : FieldDraft(name: "", type: .text)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("字段名", text: Binding(
                    get: { fields.indices.contains(index) ? fields[index].name : "" },
                    set: { if fields.indices.contains(index) { fields[index].name = $0 } }
                ))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()

                typePicker(index: index)

                Button(role: .destructive) {
                    guard fields.count > 1 else { return }
                    _ = fields.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(fields.count <= 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 8))

            // 模板带入的选项概要（选项编辑不在本次范围）
            if let summary = optionsSummary(draft.type) {
                Text(summary.isEmpty ? "选项：空（建表后维护）"
                                     : "选项：\(summary.joined(separator: "、"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// 单选/多选的选项内容（其他类型返回 nil，不显示概要行）
    private func optionsSummary(_ type: FieldType) -> [String]? {
        switch type {
        case .choice(let options): return options
        case .multiChoice(let options): return options
        default: return nil
        }
    }

    /// 类型选择器：以 kind id 为选择值，避免单选/多选因选项内容不同而显示为空
    private func typePicker(index: Int) -> some View {
        Picker("类型", selection: Binding(
            get: { fields.indices.contains(index) ? fields[index].type.id : FieldType.text.id },
            set: { setFieldType(at: index, kindID: $0) }
        )) {
            ForEach(typeChoices, id: \.id) { type in
                Label(type.displayName, systemImage: type.systemImage)
                    .tag(type.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: 状态变更

    /// 按模板重置表名与字段清单
    private func applyTemplate(_ template: Template) {
        name = template.defaultName
        fields = templateFieldPresets(template)
    }

    private func setFieldType(at index: Int, kindID: String) {
        guard fields.indices.contains(index),
              let candidate = typeChoices.first(where: { $0.id == kindID }) else { return }
        let current = fields[index].type
        // 同类切换（单选→单选、多选→多选）保留已带入的选项内容
        let newType: FieldType
        switch (candidate, current) {
        case (.choice, .choice(let options)):
            newType = .choice(options: options)
        case (.multiChoice, .multiChoice(let options)):
            newType = .multiChoice(options: options)
        default:
            newType = candidate
        }
        fields[index].type = newType
    }

    // MARK: 模板字段预设（与 macOS 版 applyTemplate 一致）

    private func templateFieldPresets(_ template: Template) -> [FieldDraft] {
        switch template {
        case .blankCustom:
            return [FieldDraft(name: "名称", type: .text)]
        case .blankRecord:
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "日期", type: .date),
                    FieldDraft(name: "内容", type: .address)]
        case .qingjia:
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "请假类型", type: .choice(options: ["病假", "事假", "丧假", "其他"])),
                    FieldDraft(name: "开始日期", type: .date),
                    FieldDraft(name: "结束日期", type: .date),
                    FieldDraft(name: "请假天数", type: .number),
                    FieldDraft(name: "是否销假", type: .boolean),
                    FieldDraft(name: "备注", type: .text)]
        case .xueqing:
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "周次", type: .number),
                    FieldDraft(name: "学业", type: .text),
                    FieldDraft(name: "情绪", type: .text),
                    FieldDraft(name: "人际关系", type: .text),
                    FieldDraft(name: "学生周记", type: .text),
                    FieldDraft(name: "行为", type: .text),
                    FieldDraft(name: "网络空间", type: .text),
                    FieldDraft(name: "亲子关系", type: .text),
                    FieldDraft(name: "其他观察", type: .text),
                    FieldDraft(name: "补充说明", type: .address),
                    FieldDraft(name: "家庭结构情况", type: .address),
                    FieldDraft(name: "家庭生活状况", type: .address),
                    FieldDraft(name: "特异体质", type: .address),
                    FieldDraft(name: "心理健康状况", type: .address),
                    FieldDraft(name: "分析人", type: .text),
                    FieldDraft(name: "填表日期", type: .date)]
        case .yibiao:
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "孤儿或事实无人抚养", type: .boolean),
                    FieldDraft(name: "单亲（离异/重组/病故）", type: .boolean),
                    FieldDraft(name: "父母服刑", type: .boolean),
                    FieldDraft(name: "二胎及以上家庭", type: .boolean),
                    FieldDraft(name: "家庭关系紧张", type: .boolean),
                    FieldDraft(name: "先天性疾病/特殊体质", type: .boolean),
                    FieldDraft(name: "精神或心理问题", type: .boolean),
                    FieldDraft(name: "家族精神心理疾病史", type: .boolean),
                    FieldDraft(name: "内向敏感/人际紧张", type: .boolean),
                    FieldDraft(name: "转学生/复学生", type: .boolean),
                    FieldDraft(name: "家庭特困/父母在外打工", type: .boolean),
                    FieldDraft(name: "学习压力大/学习困难", type: .boolean),
                    FieldDraft(name: "违法/欺凌/网瘾/辍学等", type: .boolean),
                    FieldDraft(name: "后续关爱类别", type: .choice(options: ["日常关注", "年级关注", "重点关注"])),
                    FieldDraft(name: "备注", type: .address)]
        case .observation:
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "日期", type: .date),
                    FieldDraft(name: "时间段", type: .choice(options: ["早自习", "第一节课", "第二节课", "第三节课", "第四节课",
                                                                       "午休", "第五节课", "第六节课", "第七节课", "第八节课",
                                                                       "晚自习", "放学后"])),
                    FieldDraft(name: "表现情况", type: .multiChoice(options: ["认真听讲", "积极发言", "遵守纪律", "乐于助人",
                                                                              "睡觉", "吵闹", "玩手机", "与同学冲突", "顶撞老师"])),
                    FieldDraft(name: "违纪情况", type: .multiChoice(options: ["无", "迟到", "早退", "旷课", "上课讲话",
                                                                              "玩手机", "打架", "顶撞老师", "逃课"])),
                    FieldDraft(name: "处理情况", type: .text),
                    FieldDraft(name: "备注", type: .address)]
        case .medication:
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "调查日期", type: .date),
                    FieldDraft(name: "是否服用", type: .boolean),
                    FieldDraft(name: "是否按时服用", type: .boolean),
                    FieldDraft(name: "是否通知家长保管", type: .boolean),
                    FieldDraft(name: "备注", type: .address)]
        case .campusConflict:
            // 对照《校园矛盾风险点排查记录表》：风险类型多选打■、化解状态、责任链与签字附件
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "风险类型", type: .multiChoice(options: ["心理问题", "家庭重大变故", "身体疾病",
                                                                              "行为异常—自残自杀", "行为异常—伤人",
                                                                              "行为异常—辍学旷课", "行为异常—其他",
                                                                              "多次信访", "诉讼纠纷", "其他"])),
                    FieldDraft(name: "类别", type: .choice(options: ["学校", "教师", "学生", "家长", "员工及第三方服务"])),
                    FieldDraft(name: "姓名", type: .text),
                    FieldDraft(name: "身份证", type: .idCard),
                    FieldDraft(name: "联系电话", type: .phone),
                    FieldDraft(name: "矛盾发生时间", type: .dateTime),
                    FieldDraft(name: "风险点概述", type: .address),
                    FieldDraft(name: "产生原因", type: .address),
                    FieldDraft(name: "关心措施", type: .address),
                    FieldDraft(name: "化解状态", type: .choice(options: ["未化解", "平稳", "已化解"])),
                    FieldDraft(name: "责任部门", type: .text),
                    FieldDraft(name: "责任人", type: .text),
                    FieldDraft(name: "责任人手机", type: .phone),
                    FieldDraft(name: "责任人职务", type: .text),
                    FieldDraft(name: "上报人手机", type: .phone),
                    FieldDraft(name: "上报人职务", type: .text),
                    FieldDraft(name: "包案领导姓名", type: .text),
                    FieldDraft(name: "领导签字", type: .attachment),
                    FieldDraft(name: "附件材料", type: .attachment)]
        case .suspendFollowup, .focusFollowup:
            // 《休学学生家长电话随访记录（每周一次）》与《重点关注学生家长电话随访记录
            // （每月一次，另加法定长假）》同构
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "系部", type: .text),
                    FieldDraft(name: "班号", type: .text),
                    FieldDraft(name: "姓名", type: .text),
                    FieldDraft(name: "性别", type: .choice(options: ["男", "女"])),
                    FieldDraft(name: "家长姓名1", type: .text),
                    FieldDraft(name: "家长手机1", type: .phone),
                    FieldDraft(name: "家长姓名2", type: .text),
                    FieldDraft(name: "家长手机2", type: .phone),
                    FieldDraft(name: "日期", type: .date),
                    FieldDraft(name: "电话随访内容", type: .address),
                    FieldDraft(name: "电话效果", type: .text)]
        case .focusHomeVisit:
            // 《重点关注学生入户家访记录》：家访组、沟通内容、照片附件与后续举措
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "学校名称", type: .text),
                    FieldDraft(name: "姓名", type: .text),
                    FieldDraft(name: "所在班级", type: .text),
                    FieldDraft(name: "班主任姓名", type: .text),
                    FieldDraft(name: "心理辅导员", type: .text),
                    FieldDraft(name: "监护人姓名", type: .text),
                    FieldDraft(name: "监护人联系方式", type: .text),
                    FieldDraft(name: "家访人1姓名", type: .text),
                    FieldDraft(name: "家访人1职务", type: .text),
                    FieldDraft(name: "家访人2姓名", type: .text),
                    FieldDraft(name: "家访人2职务", type: .text),
                    FieldDraft(name: "家访地址", type: .address),
                    FieldDraft(name: "家访时间", type: .dateTime),
                    FieldDraft(name: "一生一案建档情况", type: .choice(options: ["已建档", "未建档"])),
                    FieldDraft(name: "家访沟通内容", type: .address),
                    FieldDraft(name: "家访照片", type: .attachment),
                    FieldDraft(name: "被访人反馈情况", type: .address),
                    FieldDraft(name: "后续举措", type: .address)]
        case .focusTalk:
            // 《重点关注学生谈心谈话记录（每周一次）》
            return [FieldDraft(name: "学生", type: .linkStudents),
                    FieldDraft(name: "系部", type: .text),
                    FieldDraft(name: "班号", type: .text),
                    FieldDraft(name: "姓名", type: .text),
                    FieldDraft(name: "性别", type: .choice(options: ["男", "女"])),
                    FieldDraft(name: "日期", type: .date),
                    FieldDraft(name: "谈心谈话内容", type: .address),
                    FieldDraft(name: "效果", type: .text)]
        }
    }

    // MARK: 创建

    private func create() {
        // 空字段名丢弃（与 macOS 版一致）
        let visible = fields.compactMap { draft -> CustomField? in
            let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return CustomField(name: trimmed, type: draft.type)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let fallbackName = selectedTemplate.defaultName.isEmpty ? "新表" : selectedTemplate.defaultName
        _ = store.addTable(name: trimmedName.isEmpty ? fallbackName : trimmedName,
                           kind: selectedTemplate.kind, fields: visible)
        onCreated?()
        dismiss()
    }
}
