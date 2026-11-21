import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The shelf: every imported PDF as a cover, most recently read first.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query private var books: [Book]
    @State private var importing = false
    @State private var path: [Book] = []
    @State private var importError: String?
    @State private var dropTargeted = false

    private var shelf: [Book] { books.sorted { $0.recency > $1.recency } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("书库")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("导入 PDF", systemImage: "plus") { importing = true }
                }
            }
            .navigationDestination(for: Book.self) { ReaderView(book: $0) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .onOpenURL { add([$0], open: true) }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.filter { $0.pathExtension.lowercased() == "pdf" })
            return true
        } isTargeted: { dropTargeted = $0 }
        .alert("没能导入", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .task { DebugLaunch.seedIfRequested(context: context, open: { path = [$0] }) }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 28, alignment: .top)],
                      spacing: 36) {
                ForEach(shelf) { book in
                    NavigationLink(value: book) {
                        BookCover(book: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            withAnimation { Library.delete(book, from: context) }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .overlay { if dropTargeted { dropHighlight } }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("书库是空的", systemImage: "books.vertical")
        } description: {
            Text("从“文件”导入 PDF，或者直接把 PDF 拖到这里。")
        } actions: {
            Button("导入 PDF") { importing = true }
                .buttonStyle(.glassProminent)
        }
        .overlay { if dropTargeted { dropHighlight } }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 24)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .padding(16)
            .allowsHitTesting(false)
    }

    private func add(_ urls: [URL], open: Bool = false) {
        var failures: [String] = []
        var last: Book?
        for url in urls {
            do { last = try Library.importPDF(at: url, into: context) } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { importError = failures.joined(separator: "\n") }
        if open, let last { path = [last] }
    }
}

private struct BookCover: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
                .aspectRatio(0.72, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var cover: some View {
        if let data = book.coverData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay { Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary) }
        }
    }

    private var status: String {
        guard book.lastOpenedAt != nil else { return "\(book.pageCount) 页 · 未读" }
        return "读到第 \(book.lastPageIndex + 1) / \(book.pageCount) 页"
    }
}
