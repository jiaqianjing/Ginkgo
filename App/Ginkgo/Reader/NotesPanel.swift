import GinkgoCore
import PencilKit
import SwiftUI

/// Every annotation in the book, in reading order: tap one to jump to it. Export lives here too.
struct NotesPanel: View {
    let model: ReaderModel
    @State private var filter: Filter = .all
    @State private var shareURL: URL?
    @State private var exportError: String?

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
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                }
                .accessibilityLabel("关闭")
                Spacer()
                Text("批注").font(.headline)
                Spacer()
                Menu {
                    Button("Markdown 笔记", systemImage: "doc.plaintext") { export { try Exporter.writeMarkdown(for: model.book, annotations: model.annotations) } }
                    Button("带批注的 PDF", systemImage: "doc.richtext") { export { try Exporter.writeAnnotatedPDF(for: model.book, annotations: model.annotations) } }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                }
                .accessibilityLabel("导出")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            Picker("筛选", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $shareURL) { ShareSheet(url: $0) }
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
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(record.color.fill).frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if record.hasNote {
                        Text(record.taskLabel).font(.caption.weight(.semibold)).foregroundStyle(record.color.ink)
                    }
                    Spacer()
                    if case .pdf(let a)? = record.anchor {
                        Text("第 \(a.pageIndex + 1) 页").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(record.anchor?.quote ?? "")
                    .font(.system(.subheadline, design: .serif))
                    .lineLimit(3)
                if let q = record.question, !q.isEmpty, record.inkData == nil {
                    Text(q).font(.footnote.weight(.medium))
                }
                if let data = record.inkData, let ink = try? PKDrawing(data: data) {
                    InkImage(drawing: ink, maxWidth: 160)
                }
                if let reply = record.replyText, !reply.isEmpty {
                    Text(reply).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                } else if record.replyState == .failed {
                    Text(record.replyError ?? "没有拿到回答").font(.footnote).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
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
