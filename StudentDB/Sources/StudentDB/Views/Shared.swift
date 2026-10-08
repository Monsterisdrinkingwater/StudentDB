import SwiftUI

// MARK: - 通用小组件

/// 学生列表头像
struct AvatarView: View {
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

/// 住宿 / 走读 徽标
struct BoardingBadge: View {
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

/// 记录类型彩色胶囊（同一类型颜色固定）
struct TypeChip: View {
    let text: String

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .teal, .pink, .indigo, .mint, .brown]

    private var color: Color {
        if text.contains("违纪") { return .red } // 违纪记录固定红色警示
        let index = abs(text.hashValue) % Self.palette.count
        return Self.palette[index]
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// 详情页“标签：值”信息行
struct InfoRow: View {
    let label: String
    let value: String
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            if let systemImage {
                Label(value.isEmpty ? "—" : value, systemImage: systemImage)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

/// 详情页分组标题
struct SectionHeader: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 4)
    }
}

/// 表单区块卡片
struct FormCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, systemImage: systemImage)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            content
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
    }
}

/// 详情 / 表格 显示方式切换（保存在视图上）
struct ViewLayoutSwitcher: View {
    let layout: ViewLayout
    let onChange: (ViewLayout) -> Void

    var body: some View {
        Picker("显示方式", selection: Binding(
            get: { layout },
            set: { onChange($0) }
        )) {
            Text("详情").tag(ViewLayout.detail)
            Text("表格").tag(ViewLayout.table)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 150)
    }
}

/// 附件文件图标
struct FileIconView: View {
    let url: URL
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

// （SearchKit 已移至 Store/SearchKit.swift：Models.swift 的 StudentQuery 依赖它，
//  而本文件其余符号依赖 AppKit，不能进 iOS 目标。逻辑逐字未改。）

// MARK: - 可缩放 sheet

/// SwiftUI sheet 默认固定尺寸；插入 resizable 样式后即可拖拽边缘/四角缩放
struct ResizableSheetEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.enable(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.enable(nsView) }
    }

    static func enable(_ view: NSView) {
        guard let window = view.window else { return }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        window.minSize = NSSize(width: 380, height: 300)
    }
}

extension View {
    /// sheet 内容使用：min 为可缩放下限，ideal 为每次打开的默认尺寸
    func resizableSheet(minWidth: CGFloat, minHeight: CGFloat,
                        idealWidth: CGFloat, idealHeight: CGFloat) -> some View {
        self
            .frame(minWidth: minWidth, minHeight: minHeight)
            .frame(idealWidth: idealWidth, idealHeight: idealHeight)
            .background(ResizableSheetEnabler())
    }
}
