import SwiftUI

// MARK: - iOS 通用小组件（本模块内复用，不依赖含 AppKit 符号的共享视图文件）

/// 学生头像（iOS 版，样式对齐 macOS 共享层 AvatarView）
struct iOSAvatarView: View {
    let name: String
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initial: String {
        let first = name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        return first.isEmpty ? "?" : String(first)
    }
}

/// 住宿 / 走读 徽标（iOS 版，样式对齐 macOS 共享层 BoardingBadge）
struct iOSBoardingBadge: View {
    let isBoarding: Bool

    var body: some View {
        Label(isBoarding ? "住宿" : "走读",
              systemImage: isBoarding ? "bed.double.fill" : "figure.walk")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isBoarding ? Color.green.opacity(0.16) : Color.gray.opacity(0.16),
                        in: Capsule())
            .foregroundStyle(isBoarding ? Color.green : Color.secondary)
    }
}

/// 居中提示占位（项目未打开 / 学生不存在等场景）
struct iOSMessageView: View {
    let title: String
    let message: String
    var systemImage: String = "tray"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - 学生列表页（iOS）

/// 学生列表：搜索框 + 快捷筛选 chips + 学生清单，点击行进入学生详情。
/// 依赖环境注入的 AppModel（iOS App 入口需 .environmentObject(appModel)，与 macOS 入口一致）。
struct StudentListView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        NavigationStack {
            if let store = appModel.store {
                StudentListContent(store: store)
            } else {
                iOSMessageView(title: "尚未打开项目",
                               message: "请先打开或新建一个学生信息项目。",
                               systemImage: "tray")
            }
        }
    }
}

/// 列表内容：单独一层以便用 @ObservedObject 观察 ProjectStore.data 的变化
/// （AppModel.store 本身不变，数据变化发布在 ProjectStore 上）
private struct StudentListContent: View {
    @ObservedObject var store: ProjectStore
    @State private var showAddForm = false

    /// 隐式单视图（共享层 currentView 恒为 views.first，无多视图切换）。
    /// 关键字 / 筛选条件只在本会话内存中生效（共享层已不持久化筛选三项）；
    /// 排序等个性化设置仍随视图持久化。
    private var view: ListView { store.currentView }

    /// 复用共享层 StudentQuery 的筛选 + 排序
    private var students: [Student] {
        StudentQuery.apply(view: view,
                           students: store.data.students,
                           fields: store.data.orderedFields,
                           builtinOrder: store.data.builtinOrder,
                           deletedBuiltin: store.data.deletedBuiltinFields)
    }

    var body: some View {
        List {
            if store.data.students.isEmpty {
                Section {
                    Text("还没有学生，点击右上角“＋”添加。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            } else if students.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("没有符合条件的学生")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("清除搜索与筛选") {
                            var v = store.currentView
                            v.keyword = ""
                            v.condition = .all
                            store.updateView(v)
                        }
                        .font(.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(students) { student in
                        NavigationLink(value: student.id) {
                            StudentListRow(student: student)
                        }
                    }
                } footer: {
                    Text("共 \(students.count) 名学生")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: keywordBinding, prompt: "筛选姓名、学号、家长、派出所…")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                quickFilterTabs
                Divider()
            }
            .background(.bar)
        }
        .navigationTitle("学生")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加学生")
            }
        }
        .navigationDestination(for: UUID.self) { id in
            StudentDetailScreen(studentID: id)
        }
        .sheet(isPresented: $showAddForm) {
            // student 为 nil = 新增学生
            iOSStudentFormSheet(store: store)
        }
    }

    // MARK: 关键字与快捷筛选（会话内状态：写入共享层单视图，不落盘）

    /// 搜索框绑定：写入当前视图的 keyword（全字段模糊匹配，仅本次会话有效）
    private var keywordBinding: Binding<String> {
        Binding(
            get: { store.currentView.keyword },
            set: { newValue in
                var v = store.currentView
                v.keyword = newValue
                store.updateView(v)
            }
        )
    }

    /// 点击 chips 切换当前视图的筛选条件（会话内有效，切表/重启后回到底部「全部」）
    private func setCondition(_ condition: QuickCondition) {
        var v = store.currentView
        v.condition = condition
        store.updateView(v)
    }

    /// 快捷筛选 chips：固定「全部」+ 项目自定义标签（对照 macOS 侧栏标签行为）
    private var quickFilterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                QuickFilterChipView(title: "全部", isActive: view.condition == .all) {
                    setCondition(.all)
                }
                ForEach(store.data.quickFilters) { filter in
                    QuickFilterChipView(title: filter.name,
                                        isActive: view.condition == filter.condition) {
                        setCondition(filter.condition)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

/// 列表行：头像 + 姓名 + 学号 + 住宿徽章
private struct StudentListRow: View {
    let student: Student

    var body: some View {
        HStack(spacing: 12) {
            iOSAvatarView(name: student.name, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(student.name.isEmpty ? "（未命名）" : student.name)
                    .font(.body.weight(.medium))
                Text(student.studentNumber.isEmpty ? "未填学号" : "学号 \(student.studentNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            iOSBoardingBadge(isBoarding: student.isBoarding)
        }
        .padding(.vertical, 2)
    }
}

/// 快捷筛选胶囊按钮
private struct QuickFilterChipView: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
                            in: Capsule())
                .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}
