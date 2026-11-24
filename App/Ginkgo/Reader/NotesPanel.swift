import GinkgoCore
import PencilKit
import SwiftUI

/// Every annotation in the book, in reading order: tap one to jump to it. Export lives here too.
struct NotesPanel: View {
    let model: ReaderModel
    @State private var filter: Filter = .all
    @State private var shareURL: URL?
    @State private var exportError: String?
    @State private var confirmClear = false
    /// "Export first": clear once the share sheet for the exported notes closes.
    @State private var clearAfterExport = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, notes, highlights
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "全部"
            case .notes: "AI 批注"
            case .highlights: "高亮"
            }
        }
    }

    private var items: [AnnotationRecord] {
        model.annotations.filter { r in
            switch filter {
            case .all: r.kind != .ink
            case .notes: r.hasNote
            case .highlights: r.kind != .ink && !r.hasNote
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Own header: a NavigationStack here would nest inside the reader's and pop it.
            HStack {
                Button { withAnimation(.smooth) { model.showNotes = false } } label: {
                    Image(systemName: "xmark").font(Theme.panelIconFont).frame(width: Theme.panelControlSize, height: Theme.panelControlSize)
                }
                .accessibilityLabel("关闭")
                Spacer()
                Text("批注").font(Theme.titleFont)
                Spacer()
                Menu {
                    Button("Markdown 笔记", systemImage: "doc.plaintext") { export { try Exporter.writeMarkdown(for: model.book, annotations: model.annotations) } }
                    Button("带批注的 PDF", systemImage: "doc.richtext") { export { try Exporter.writeAnnotatedPDF(for: model.book, annotations: model.annotations) } }
                    Divider()
                    Button("清除全部批注…", systemImage: "arrow.counterclockwise", role: .destructive) { confirmClear = true }
                        .disabled(Library.AnnotationCount(model.allRecords).isEmpty)
                } label: {
                    Image(systemName: "square.and.arrow.up").font(Theme.panelIconFont).frame(width: Theme.panelControlSize, height: Theme.panelControlSize)
                }
                .accessibilityLabel("导出")
            }
            .padding(.horizontal, Theme.rhythm)
            .padding(.top, Theme.rhythm)
            Picker("筛选", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.cardInset)
            .padding(.vertical, Theme.rhythm)
            if items.isEmpty {
                ContentUnavailableView("还没有批注", systemImage: "highlighter",
                                       description: Text("选中文字后高亮或向 AI 提问，批注会按页码出现在这里。"))
            } else {
                List {
                    ForEach(items, id: \.id) { record in
                        Button { withAnimation(.smooth) { model.reveal(record.id) } } label: { NoteRow(record: record) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .swipeActions {
                                Button("删除", systemImage: "trash", role: .destructive) { model.delete(record.id) }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.paper)
        .sheet(item: $shareURL, onDismiss: {
            if clearAfterExport { clearAfterExport = false; withAnimation { model.clearAll() } }
        }) { ShareSheet(url: $0) }
        .confirmationDialog("恢复到导入时的样子？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除全部批注", role: .destructive) { withAnimation { model.clearAll() } }
            Button("先导出笔记，再清除") {
                clearAfterExport = true
                export { try Exporter.writeMarkdown(for: model.book, annotations: model.annotations) }
                if shareURL == nil { clearAfterExport = false }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除\(Library.AnnotationCount(model.allRecords).summary)。PDF 原文件不受影响。关闭这本书之前，可以用撤销整批恢复。")
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    private func export(_ make: () throws -> URL) {
        model.pageInk.saveAll()
        do { shareURL = try make() } catch { exportError = error.localizedDescription }
    }
}

private struct NoteRow: View {
    let record: AnnotationRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.medium) {
            RoundedRectangle(cornerRadius: Theme.Card.ruleRadius).fill(record.color.ink.opacity(Theme.Card.ruleOpacity)).frame(width: Theme.noteRuleWidth)
            VStack(alignment: .leading, spacing: Theme.Space.compact) {
                HStack {
                    if record.hasNote {
                        Text(record.taskLabel).font(Theme.metadataFont).foregroundStyle(record.color.ink)
                    }
                    Spacer()
                    if case .pdf(let a)? = record.anchor {
                        Text("第 \(a.pageIndex + 1) 页").font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                    }
                }
                Text(record.anchor?.quote ?? "")
                    .font(Theme.noteFont)
                    .lineLimit(3)
                if let q = record.question, !q.isEmpty, record.inkData == nil {
                    Text(q).font(Theme.actionFont)
                }
                if let data = record.inkData, let ink = try? PKDrawing(data: data) {
                    InkImage(drawing: ink, maxWidth: 160)
                        .modifier(NoteInkAppearance())
                }
                if let reply = record.replyText, !reply.isEmpty {
                    Text(reply).font(Theme.footnoteFont).foregroundStyle(Theme.secondaryInk).lineLimit(4)
                } else if record.replyState == .failed {
                    Text(record.replyError ?? "没有拿到回答").font(Theme.footnoteFont).foregroundStyle(Theme.error).lineLimit(2)
                }
            }
        }
        .padding(.vertical, Theme.rhythm)
        .contentShape(Rectangle())
    }
}

/// The system share sheet for an exported file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
