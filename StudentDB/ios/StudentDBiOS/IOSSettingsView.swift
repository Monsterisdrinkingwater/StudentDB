import SwiftUI

// MARK: - iOS 设置页

/// 密码锁开关（AppLock）＋ 自动锁定分钟数（appModel.autoLockMinutes）
/// ＋ 项目信息（名称/路径/保存时间）＋「在文件 App 中显示」提示文案。
struct IOSSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var lockEnabled = AppLock.isEnabled
    @State private var showSetPassword = false
    @State private var autoLockMinutes = 15

    /// 自动锁定可选时长（分钟）
    private static let autoLockOptions: [(minutes: Int, title: String)] = [
        (1, "1 分钟"), (5, "5 分钟"), (15, "15 分钟"), (30, "30 分钟"), (60, "60 分钟")
    ]

    var body: some View {
        Form {
            lockSection
            autoLockSection
            projectSection
            filesHintSection
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showSetPassword) {
            IOSSetPasswordSheet { lockEnabled = true }
        }
        .onAppear { autoLockMinutes = appModel.autoLockMinutes }
    }

    // MARK: 密码锁

    private var lockSection: some View {
        Section {
            Toggle("启动时需要密码", isOn: Binding(
                get: { lockEnabled },
                set: { on in
                    if on {
                        // 开启：先设置密码（确认成功后写钥匙串）
                        showSetPassword = true
                    } else {
                        AppLock.disable()
                        lockEnabled = false
                    }
                }
            ))
            if lockEnabled {
                Button {
                    appModel.lockNow()
                } label: {
                    Label("立即锁定", systemImage: "lock.fill")
                }
            }
        } header: {
            Text("密码锁")
        } footer: {
            Text("开启后打开应用需要输入密码；密码哈希只保存在本机钥匙串，不会写进项目文件。")
        }
    }

    // MARK: 自动锁定

    private var autoLockSection: some View {
        Section {
            Picker("空闲后自动锁定", selection: $autoLockMinutes) {
                ForEach(Self.autoLockOptions, id: \.minutes) { option in
                    Text(option.title).tag(option.minutes)
                }
            }
        } header: {
            Text("自动锁定")
        } footer: {
            Text("应用空闲达到设定时长后自动上锁（需先开启密码锁）。")
        }
        .onChange(of: autoLockMinutes) { _, newValue in
            // AppModel.autoLockMinutes 每次实时读这个键
            UserDefaults.standard.set(newValue, forKey: AppModel.autoLockMinutesKey)
        }
    }

    // MARK: 项目信息

    @ViewBuilder
    private var projectSection: some View {
        Section("项目信息") {
            if let store = appModel.store {
                LabeledContent("名称", value: store.projectName)
                if let url = store.projectURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("路径")
                        Text(url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
                LabeledContent(
                    "最近保存",
                    value: Fmt.dateTime.string(from: store.lastSavedAt ?? store.data.updatedAt)
                )
                LabeledContent("学生数", value: "\(store.data.students.count)")
                LabeledContent("数据表", value: "\(store.data.tables.count) 张")
            } else {
                Text("未打开项目。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 文件 App 提示

    private var filesHintSection: some View {
        Section("在文件 App 中显示") {
            Text("项目是一个独立文件夹（.studentproj），数据、附件与备份都保存在其中。可在 iPhone 的「文件」App 中浏览本应用的目录找到项目文件；也可通过 AirDrop / iCloud 云盘把项目在 Mac 与 iPhone 之间传输后打开。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 首次开启密码锁

/// 输入并确认新密码 → AppLock.enable(password:)
struct IOSSetPasswordSheet: View {
    var onEnabled: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmed = ""

    private var mismatch: Bool { !confirmed.isEmpty && confirmed != password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("密码", text: $password)
                    SecureField("再次输入密码", text: $confirmed)
                } header: {
                    Text("设置启动密码")
                } footer: {
                    if mismatch {
                        Text("两次输入不一致。")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("开启密码锁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开启") {
                        AppLock.enable(password: password)
                        onEnabled()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(password.isEmpty || password != confirmed)
                }
            }
        }
    }
}
