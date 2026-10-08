import SwiftUI

// MARK: - 数据表列表（记录表 + 自定义表）

/// 数据表标签页：当前项目全部 DBTable（store.data.tables），
/// 每行显示表名 + 行数；点击进入 TableViewScreen(tableID:)。
struct TableViewList: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if let store = appModel.store {
                    // 子视图持有 @ObservedObject store：新建表后（store.data 变化）列表立即刷新
                    TableViewListView(store: store)
                } else {
                    ContentUnavailableView(
                        "未打开项目",
                        systemImage: "tray",
                        description: Text("请先打开或新建一个学生库项目。")
                    )
                }
            }
            .navigationTitle("数据表")
        }
    }
}

/// 列表主体：订阅 ProjectStore 变化 + 右上角「＋」新建表入口
private struct TableViewListView: View {
    @ObservedObject var store: ProjectStore

    @State private var showNewTable = false

    var body: some View {
        Group {
            if store.data.tables.isEmpty {
                ContentUnavailableView(
                    "还没有数据表",
                    systemImage: "tablecells",
                    description: Text("点击右上角「＋」从模板新建数据表。")
                )
            } else {
                List {
                    ForEach(store.data.tables) { table in
                        NavigationLink(value: TableViewTarget(id: table.id)) {
                            row(table)
                        }
                    }
                }
                .navigationDestination(for: TableViewTarget.self) { target in
                    TableViewScreen(store: store, tableID: target.id)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showNewTable = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建数据表")
            }
        }
        .sheet(isPresented: $showNewTable) {
            IOSNewTableSheet(store: store)
        }
    }

    /// 单行：图标 + 表名 + 表类型 + 行数
    private func row(_ table: DBTable) -> some View {
        HStack(spacing: 12) {
            Image(systemName: table.systemImage)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(table.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(table.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("\(table.rows.count) 行")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 导航目标包装：表 id 与行 id 都是 UUID，
/// 用独立类型区分两段 navigationDestination，避免值类型冲突。
struct TableViewTarget: Hashable {
    let id: UUID
}
