import PDFKit
import SwiftUI

/// Reading screen. A tap toggles the chrome; the position is remembered per book.
struct ReaderView: View {
    let book: Book
    @State private var document: PDFDocument?
    @State private var pageIndex = 0
    @State private var chromeVisible = true
    @State private var missing = false

    var body: some View {
        Group {
            if let document {
                PDFKitView(document: document, initialPage: book.lastPageIndex,
                           onPageChange: pageChanged, onTap: toggleChrome)
                    .ignoresSafeArea()
            } else if missing {
                ContentUnavailableView("找不到这本书的文件", systemImage: "exclamationmark.triangle",
                                       description: Text("文件可能已被删除。可以从书库里删掉它，再重新导入。"))
            } else {
                ProgressView()
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(chromeVisible ? .visible : .hidden, for: .navigationBar)
        .statusBarHidden(!chromeVisible)
        .overlay(alignment: .bottom) {
            if chromeVisible, document != nil {
                PageIndicator(index: pageIndex, count: book.pageCount)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .task(id: book.id) { open() }
    }

    private func open() {
        guard document == nil else { return }
        if let doc = PDFDocument(url: book.fileURL) {
            document = doc
            pageIndex = min(book.lastPageIndex, max(doc.pageCount - 1, 0))
            book.lastOpenedAt = .now
        } else {
            missing = true
        }
    }

    private func pageChanged(_ index: Int) {
        pageIndex = index
        book.lastPageIndex = index
    }

    private func toggleChrome() { chromeVisible.toggle() }
}

private struct PageIndicator: View {
    let index: Int
    let count: Int

    var body: some View {
        Text("\(index + 1) / \(count)")
            .font(.footnote.monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
    }
}
