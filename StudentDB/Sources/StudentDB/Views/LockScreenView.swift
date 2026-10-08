import SwiftUI

/// 全窗口锁屏覆盖层
struct LockScreenView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var password = ""
    @State private var errorMessage: String?
    @State private var shakeTrigger = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)

                VStack(spacing: 6) {
                    Text("学生信息管理系统已锁定")
                        .font(.title3.weight(.semibold))
                    Text("输入密码继续使用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .focused($focused)
                    .onSubmit(unlock)
                    .offset(x: shakeTrigger ? -8 : 0)
                    .animation(.easeInOut(duration: 0.06).repeatCount(5, autoreverses: true),
                               value: shakeTrigger)

                Button("解锁", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(.top, 40)
        }
        .onAppear {
            focused = true
        }
    }

    private func unlock() {
        if appModel.unlock(withPassword: password) {
            password = ""
            errorMessage = nil
        } else {
            errorMessage = "密码不正确，请重试。"
            password = ""
            shakeTrigger.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                shakeTrigger = false
            }
        }
    }
}

// MARK: - 设置密码

struct SetPasswordSheet: View {
    var onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirm = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            Text("设置启动密码")
                .font(.headline)
                .padding(.top, 16)
            Text("请牢记密码，忘记密码将无法进入软件（可删除钥匙串项恢复）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Form {
                SecureField("新密码", text: $password)
                SecureField("再次输入", text: $confirm)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开启密码锁", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .padding(.top, 4)
    }

    private func save() {
        if password.count < 4 {
            errorMessage = "密码至少 4 位。"
            return
        }
        if password != confirm {
            errorMessage = "两次输入的密码不一致。"
            return
        }
        onSet(password)
        dismiss()
    }
}

// MARK: - 输入密码确认

struct ConfirmPasswordSheet: View {
    let title: String
    let message: String
    /// 返回 true 表示验证通过
    var verify: (String) -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.headline)
                .padding(.top, 16)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .onSubmit(confirmAction)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确定", action: confirmAction)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .padding(.top, 4)
    }

    private func confirmAction() {
        if verify(password) {
            dismiss()
        } else {
            errorMessage = "密码不正确。"
            password = ""
        }
    }
}
