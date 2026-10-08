import SwiftUI

/// 设置窗口：通用（密码锁）/ 数据与备份
struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView {
            GeneralSettingsTab(appModel: appModel)
                .tabItem { Label("通用", systemImage: "gearshape") }
            BackupSettingsTab()
                .tabItem { Label("数据与备份", systemImage: "externaldrive.badge.timemachine") }
        }
        .padding(14)
        .frame(minHeight: 380)
    }
}

// MARK: - 通用

struct GeneralSettingsTab: View {
    @ObservedObject var appModel: AppModel

    @AppStorage(AppModel.autoLockMinutesKey) private var autoLockMinutes = 15
    @State private var showEnableSheet = false
    @State private var showDisableSheet = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启动密码锁")
                            .font(.callout.weight(.medium))
                        Text("打开软件时需要输入密码；密码哈希保存在本机钥匙串。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if AppLock.isEnabled {
                        Button("关闭密码锁…", role: .destructive) {
                            showDisableSheet = true
                        }
                    } else {
                        Button("开启密码锁…") {
                            showEnableSheet = true
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("闲置自动锁定", selection: $autoLockMinutes) {
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("从不").tag(0)
                }
                .disabled(!AppLock.isEnabled)
                if !AppLock.isEnabled {
                    Text("开启密码锁后可选：离开电脑一段时间后自动锁定。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("自动锁定")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showEnableSheet) {
            SetPasswordSheet { password in
                AppLock.enable(password: password)
                appModel.objectWillChange.send()
            }
            .frame(width: 360)
        }
        .sheet(isPresented: $showDisableSheet) {
            ConfirmPasswordSheet(title: "关闭密码锁", message: "输入当前密码以关闭密码锁。") { password in
                if AppLock.verify(password: password) {
                    AppLock.disable()
                    appModel.objectWillChange.send()
                    return true
                }
                return false
            }
            .frame(width: 360)
        }
    }
}

// MARK: - 数据与备份

struct BackupSettingsTab: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var refreshTrigger = false
    @State private var pendingRestore: BackupInfo?

    var body: some View {
        Form {
            if let store = appModel.store {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.projectName)
                                .font(.callout.weight(.medium))
                            Text(store.projectURL?.path ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("立即备份") {
                            try? store.backupNow()
                            refreshTrigger.toggle()
                        }
                    }
                } header: {
                    Text("当前项目")
                }

                Section {
                    let backups = store.listBackups()
                    if backups.isEmpty {
                        Text("暂无备份。修改数据并保存后，软件会自动保留最近 \(ProjectStore.maxBackups) 份备份。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(backups) { backup in
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backup.displayName)
                                        .font(.callout)
                                    Text("\(Fmt.dateTime.string(from: backup.modifiedAt)) · \(Fmt.fileSize(backup.size))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button("恢复…") {
                                    pendingRestore = backup
                                }
                                Button {
                                    store.revealInFinder(backup.url)
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .help("在访达中显示")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    Text("自动备份（保留最近 \(ProjectStore.maxBackups) 份）")
                }
            } else {
                Section {
                    Text("尚未打开项目。打开项目后可在此管理备份。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .id(refreshTrigger)
        .confirmationDialog(
            "恢复到备份「\(pendingRestore?.displayName ?? "")」？",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) {
                if let backup = pendingRestore, let store = appModel.store {
                    try? store.restore(from: backup)
                    refreshTrigger.toggle()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将覆盖当前项目数据。恢复前会自动为当前数据再做一次备份。")
        }
    }
}
