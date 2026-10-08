import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 附件辅助（iOS）

// 本文件提供：系统分享面板（UIActivityViewController 包装）与附件管理区
// （添加 / 预览 / 分享 / 删除）。
// QuickLook 预览复用模块 1 的 QuickLookPreview（ios/StudentDBiOS/iOSPlatformServices.swift）；
// iOS 平台服务注入由模块 1 的 IOSPlatformServices 提供（同文件），此处不再重复定义。

// MARK: 分享面板

/// 系统分享面板：传入文件 URL 或文本。
/// 在 SwiftUI 里以 `.sheet { ShareSheet(items: [...]) }` 呈现。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: 预览请求

/// sheet(item:) 用的预览请求包装（内容交给模块 1 的 QuickLookPreview 呈现）
struct IOSPreviewRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: 附件管理区

/// 附件管理区（行级 / 附件字段通用）：
/// 添加（fileImporter 多选 → store.importAttachment）、
/// 预览（QuickLookPreview）、分享（ShareSheet）、删除（store.deleteAttachment）。
struct IOSAttachmentSection: View {
    @ObservedObject var store: ProjectStore
    let table: DBTable
    let rowID: UUID
    /// nil = 行级附件区；非空 = 附件字段的专属目录
    var fieldID: UUID?

    @State private var files: [URL] = []
    @State private var showPicker = false
    @State private var preview: IOSPreviewRequest?
    @State private var shareItem: IOSShareItem?
    @State private var pendingDelete: URL?
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("附件（随项目文件一起保存）")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showPicker = true
                } label: {
                    Label("添加", systemImage: "plus.circle.fill")
                        .font(.callout)
                }
                .labelStyle(.titleAndIcon)
            }

            if files.isEmpty {
                Text("还没有附件。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(files, id: \.self) { url in
                    fileRow(url)
                }
            }
        }
        .onAppear(perform: reload)
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            add(urls: urls)
        }
        .sheet(item: $preview) { request in
            QuickLookPreview(urls: request.urls)
                .ignoresSafeArea()
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog(
            "删除附件「\(pendingDelete?.lastPathComponent ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let url = pendingDelete {
                    store.deleteAttachment(url)
                    reload()
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("附件将从项目中移除，此操作不可撤销。")
        }
        .alert(
            "附件导入",
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failureMessage ?? "")
        }
    }

    // MARK: 单行

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                Text(fileSize(url))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                shareItem = IOSShareItem(url: url)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                pendingDelete = url
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        // 点行 → 预览全部附件（QuickLook 内可翻页）
        .onTapGesture {
            preview = IOSPreviewRequest(urls: files)
        }
    }

    // MARK: 操作

    private func reload() {
        files = store.attachmentFileURLs(tableID: table.id, rowID: rowID, fieldID: fieldID)
    }

    private func add(urls: [URL]) {
        var failed = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try store.importAttachment(at: url, tableID: table.id,
                                               rowID: rowID, fieldID: fieldID)
            } catch {
                failed += 1
            }
        }
        reload()
        if failed > 0 {
            failureMessage = "\(failed) 个文件导入失败，请重试。"
        }
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Fmt.fileSize(bytes)
    }
}
