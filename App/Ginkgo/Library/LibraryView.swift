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
    @State private var showSettings = false
    @State private var clearing: Book?

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
            .background(Theme.paper)
            .navigationTitle("书库")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("AI 设置", systemImage: "gearshape") { showSettings = true }
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
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("恢复到导入时的样子？", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            Button("清除全部批注", role: .destructive) {
                if let book = clearing { withAnimation { Library.clearAnnotations(of: book, in: context) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除《\(clearing?.title ?? "")》的\(Library.AnnotationCount(clearing?.annotations ?? []).summary)。PDF 原文件不受影响。这里清除后不能撤销；想留后路，可以先打开书，在批注列表里清除。")
        }
        .task {
            DebugLaunch.seedIfRequested(context: context, open: { path = [$0] })
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "inMemoryStore"), UserDefaults.standard.bool(forKey: "visualSettings") { showSettings = true }
            #endif
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Cover.minimumWidth, maximum: Theme.Cover.maximumWidth), spacing: Theme.pageInset, alignment: .top)],
                      spacing: Theme.pageInset + Theme.rhythm) {
                ForEach(shelf) { book in
                    NavigationLink(value: book) {
                        BookCover(book: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !Library.AnnotationCount(book.annotations ?? []).isEmpty {
                            Button("清除全部批注…", systemImage: "arrow.counterclockwise") { clearing = book }
                        }
                        Button("删除", systemImage: "trash", role: .destructive) {
                            withAnimation { Library.delete(book, from: context) }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pageInset)
            .padding(.vertical, Theme.pageInset)
        }
        .overlay { if dropTargeted { dropHighlight } }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.cardInset) {
            Image(systemName: "book.closed")
                .font(Theme.emptyIconFont)
                .foregroundStyle(Theme.accent)
                .padding(Theme.pageInset)
                .background(Theme.margin, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .accessibilityHidden(true)
            Text("书库是空的").font(Theme.emptyTitleFont)
            Text("从“文件”导入 PDF，或者直接把 PDF 拖到这里。")
                .font(Theme.calloutFont)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
            Button("导入 PDF") { importing = true }
                .buttonStyle(.glassProminent)
                .padding(.top, Theme.rhythm)
        }
        .padding(Theme.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if dropTargeted { dropHighlight } }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: Theme.dropRadius)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: Theme.dropLineWidth, dash: Theme.dropDash))
            .padding(Theme.cardInset)
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
        VStack(alignment: .leading, spacing: Theme.cardInset) {
            cover
                .aspectRatio(Theme.Cover.ratio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.coverRadius))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.Cover.spine).frame(width: Theme.Cover.spineWidth)
                }
                .shadow(color: Theme.Cover.shadow, radius: Theme.coverShadow, x: Theme.Cover.shadowX, y: Theme.Cover.shadowY)
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                Text(book.title)
                    .font(Theme.titleFont)
                    .lineLimit(2)
                ProgressView(value: book.lastOpenedAt == nil ? 0 : Double(book.lastPageIndex + 1), total: Double(max(book.pageCount, 1)))
                    .tint(Theme.accent)
                    .accessibilityLabel("阅读进度")
                Text(status)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.secondaryInk)
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
                .overlay { Image(systemName: "doc.text").font(Theme.largeIconFont).foregroundStyle(Theme.secondaryInk) }
        }
    }

    private var status: String {
        if BookFiles.shared.cloudDirectory != nil, !BookFiles.shared.isReady(book.fileName) { return String(localized: "正在从 iCloud 下载") }
        guard book.lastOpenedAt != nil else { return String(localized: "\(book.pageCount) 页 · 未读") }
        return String(localized: "读到第 \(book.lastPageIndex + 1) / \(book.pageCount) 页")
    }
}
