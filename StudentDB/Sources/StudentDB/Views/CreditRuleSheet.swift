import SwiftUI

// MARK: - 学分规则编辑
//
// 按分组列出规则，支持新增 / 改名 / 改分值（允许负数与 0.5 半分）/ 改分类 / 删除，
// 可一键恢复默认；确定时整体写回 store.updateCreditRules。
// 历史记录存的是套用时刻的名称/分值快照，改规则不影响已有留痕。

struct CreditRuleSheet: View {
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    /// 本地编辑副本：确定时整体写回
    @State private var rules: [CreditRule] = []
    @State private var showRestoreDefaults = false

    var body: some View {
        VStack(spacing: 0) {
            Text("编辑学分规则")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 6)

            Text("分值支持负数（扣分）与 0.5 半分。修改规则不影响已有记录的留痕。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()

            List {
                ForEach(CreditRule.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(rules) { rule in
                            if rule.category == category {
                                CreditRuleRow(rule: binding(for: rule), onDelete: {
                                    rules.removeAll { $0.id == rule.id }
                                })
                            }
                        }
                        Button {
                            addRule(category: category)
                        } label: {
                            Label("添加\(category)规则", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                Button("恢复默认规则…", role: .destructive) {
                    showRestoreDefaults = true
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("确定", action: save)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .onAppear { rules = store.data.creditRules }
        .resizableSheet(minWidth: 480, minHeight: 400, idealWidth: 600, idealHeight: 540)
        .confirmationDialog(
            "恢复默认规则？",
            isPresented: $showRestoreDefaults,
            titleVisibility: .visible
        ) {
            Button("恢复为默认规则", role: .destructive) {
                rules = CreditRule.defaults
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将替换为内置的 \(CreditRule.defaults.count) 条预设规则，当前自定义规则会被移除（点「确定」后才写入项目）。")
        }
    }

    // MARK: 编辑辅助

    /// 按 id 回链到本地编辑副本（行内改动写回副本，点「确定」才写入项目）
    private func binding(for rule: CreditRule) -> Binding<CreditRule> {
        Binding(
            get: { rules.first { $0.id == rule.id } ?? rule },
            set: { newValue in
                if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                    rules[idx] = newValue
                }
            }
        )
    }

    private func addRule(category: String) {
        var rule = CreditRule()
        rule.name = "新规则"
        rule.points = 1
        rule.category = category
        rule.sortOrder = (rules.filter { $0.category == category }.map(\.sortOrder).max() ?? 0) + 1
        rules.append(rule)
    }

    private func save() {
        var result = rules
        for idx in result.indices where result[idx].name.trimmingCharacters(in: .whitespaces).isEmpty {
            result[idx].name = "未命名规则"
        }
        store.updateCreditRules(result)
        dismiss()
    }
}

/// 规则编辑行：名称 / 分值（文本输入，解析通过即生效）/ 分类 / 删除
private struct CreditRuleRow: View {
    @Binding var rule: CreditRule
    let onDelete: () -> Void

    @State private var pointsText = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("规则名称", text: $rule.name)
                .textFieldStyle(.roundedBorder)
            TextField("分值", text: $pointsText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .onSubmit(commitPoints)
                .onChange(of: pointsText) { _ in commitPoints() }
                .help("分值：负数 = 扣分，支持 0.5 半分")
            Picker("", selection: $rule.category) {
                ForEach(CreditRule.categories, id: \.self) { category in
                    Text(category).tag(category)
                }
            }
            .labelsHidden()
            .frame(width: 84)
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除该规则（已有记录的留痕不受影响）")
        }
        .onAppear { pointsText = CreditSummary.pointsText(rule.points) }
    }

    /// 解析通过才写回（无效输入暂留本地，不影响原值）
    private func commitPoints() {
        guard let value = Double(pointsText.trimmingCharacters(in: .whitespaces)),
              rule.points != value else { return }
        rule.points = value
    }
}
