import SwiftUI
import UniformTypeIdentifiers

/// 学生独立附件区：存放学籍表扫描件、体检报告等文件（对应项目包内 attachments/<学生>/files/）
struct StudentFilesTabView: View {
    @ObservedObject var store: ProjectStore
    let student: Student

    @State private var files: [URL] = []
    @State private var isTargeted = false
    @State private var pendingDelete: URL?

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("该学生的独立附件区（学籍表、证件扫描件等），拖入文件即可保存到项目包内。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addViaPanel()
                    } label: {
                        Label("添加文件", systemImage: "plus")
                    }
                    if !files.isEmpty {
                        Button {
                            if let dir = store.studentFilesDirectory(student.id) {
                                store.revealInFinder(dir)
                            }
                        } label: {
                            Label("打开文件夹", systemImage: "folder")
                        }
                    }
                }

                if files.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(files, id: \.absoluteString) { url in
                            fileTile(url)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
        .onAppear(perform: reload)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .alert("删除文件？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { url in
            Button("移入废纸篓", role: .destructive) {
                store.deleteAttachment(url)
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: { url in
            Text("「\(url.lastPathComponent)」将被移入废纸篓。")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("暂无附件")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("把文件拖到此处，或点击“添加文件”")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(Color(nsColor: .separatorColor))
        )
    }

    private func fileTile(_ url: URL) -> some View {
        VStack(spacing: 6) {
            FileIconView(url: url, size: 44)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
            Text(Fmt.fileSize((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.openAttachment(url)
        }
        .onTapGesture {
            // 单击选中效果较弱，双击打开；右键提供删除
        }
        .contextMenu {
            Button("打开") { store.openAttachment(url) }
            Button("在访达中显示") { store.revealInFinder(url) }
            Divider()
            Button("删除…", role: .destructive) { pendingDelete = url }
        }
    }

    // MARK: - 逻辑

    private func reload() {
        files = store.attachmentFileURLs(studentID: student.id)
    }

    private func addViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "添加文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var added = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    importURLs([url])
                }
            }
            added = true
        }
        return added
    }

    private func importURLs(_ urls: [URL]) {
        for url in urls {
            try? store.importAttachment(at: url, studentID: student.id, recordID: nil)
        }
        reload()
    }
}
