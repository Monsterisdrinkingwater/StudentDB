import SwiftUI

/// 未打开项目时的欢迎页
struct WelcomeView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                Text("学生信息管理系统")
                    .font(.title.weight(.semibold))
                Text("学生档案 · 监护人 · 关心关爱记录 · 本地安全存储")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 30)

            HStack(spacing: 14) {
                Button {
                    appModel.promptNewProject()
                } label: {
                    Label("新建项目", systemImage: "plus")
                        .frame(width: 130)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    appModel.promptOpenProject()
                } label: {
                    Label("打开项目", systemImage: "folder")
                        .frame(width: 130)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 34)

            if !appModel.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近项目")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(appModel.recentProjects.prefix(5), id: \.absoluteString) { url in
                        HStack(spacing: 6) {
                            Button {
                                appModel.openProject(at: url)
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .font(.body)
                                        Text(url.deletingLastPathComponent().path)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    appModel.removeRecentProject(url)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .padding(2)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("从最近项目中移除（不会删除项目文件）")
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(width: 380)
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
                )
            }

            Spacer()

            Text("所有数据以 .studentproj 项目文件保存在本机，可随时在访达中复制备份。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
