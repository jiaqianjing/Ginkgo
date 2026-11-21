import GinkgoCore
import PDFKit
import SwiftData
import SwiftUI

/// Reading screen. Opens the book's file, then hands over to `ReaderContent`.
struct ReaderView: View {
    let book: Book
    @Environment(\.modelContext) private var context
    @State private var model: ReaderModel?
    @State private var missing = false

    var body: some View {
        Group {
            if let model {
                ReaderContent(model: model)
            } else if missing {
                ContentUnavailableView("找不到这本书的文件", systemImage: "exclamationmark.triangle",
                                       description: Text("文件可能已被删除。可以从书库里删掉它，再重新导入。"))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) { open() }
    }

    private func open() {
        guard model == nil else { return }
        guard let document = PDFDocument(url: book.fileURL) else { missing = true; return }
        book.lastOpenedAt = .now
        model = ReaderModel(book: book, document: document, context: context)
    }
}

private struct ReaderContent: View {
    @Bindable var model: ReaderModel
    @State private var pageIndex = 0

    var body: some View {
        GeometryReader { geo in
            let layout = ReaderLayout(size: geo.size)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    PDFKitView(model: model, onPageChange: pageChanged)
                        .frame(width: layout.pageWidth)
                    if layout.hasMarginColumn {
                        MarginBackground().frame(width: layout.marginWidth)
                    }
                }

                MarksLayer(model: model)
                    .frame(width: layout.pageWidth, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)

                Group {
                    if layout.hasMarginColumn {
                        ConnectorLayer(model: model, layout: layout).allowsHitTesting(false)
                        if model.penOn {
                            MarginInkCanvas(model: model, layout: layout)
                                .frame(width: layout.marginWidth, height: geo.size.height)
                                .offset(x: layout.pageWidth)
                        }
                        SidenoteColumn(model: model, layout: layout)
                    } else {
                        FoldedNotesLayer(model: model, layout: layout)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()

                SelectionMenu(model: model, layout: layout)
                AnnotationMenu(model: model, layout: layout)

                if model.penOn {
                    PenBanner(color: $model.penHighlightColor) { model.penOn = false }
                        .position(x: layout.pageWidth / 2, y: 34)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if model.showNotes {
                    Color.black.opacity(0.08)
                        .onTapGesture { withAnimation(.smooth) { model.showNotes = false } }
                        .transition(.opacity)
                    NotesPanel(model: model)
                        .frame(width: min(380, geo.size.width * 0.9), height: geo.size.height - 24)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .black.opacity(0.18), radius: 24, x: -4)
                        .position(x: geo.size.width - min(380, geo.size.width * 0.9) / 2 - 12, y: geo.size.height / 2)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if model.chromeVisible && !model.showNotes {
                    PageIndicator(index: pageIndex, count: model.document.pageCount)
                        .position(x: layout.pageWidth / 2, y: geo.size.height - geo.safeAreaInsets.bottom - 28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(.smooth(duration: 0.3), value: model.mode)
            .animation(.smooth(duration: 0.3), value: layout.hasMarginColumn)
            .onChange(of: layout.hasMarginColumn) { _, _ in DispatchQueue.main.async { model.recompute() } }
        }
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .background(Color(uiColor: .secondarySystemBackground))
        .toolbarVisibility(model.chromeVisible ? .visible : .hidden, for: .navigationBar)
        .statusBarHidden(!model.chromeVisible)
        .toolbar { toolbar }
        .sheet(item: $model.asking) { AskSheet(model: model, target: $0) }
        .sheet(isPresented: $model.showSettings) { SettingsView() }

        .onAppear { pageIndex = model.book.lastPageIndex }
        .onPencilDoubleTap { _ in withAnimation { model.penOn.toggle() } }
        .onDisappear { model.pageInk.saveAll() }
        .task { await DebugLaunch.annotateIfRequested(model) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("模式", selection: $model.mode) {
                ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(model.penOn ? "停止书写" : "用笔书写",
                   systemImage: model.penOn ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle") {
                withAnimation { model.penOn.toggle() }
            }
            Button("批注", systemImage: "list.bullet.rectangle") { withAnimation(.smooth) { model.showNotes.toggle() } }
            Button("AI 设置", systemImage: "gearshape") { model.showSettings = true }
        }
    }

    private func pageChanged(_ index: Int) {
        pageIndex = index
        model.book.lastPageIndex = index
    }
}

/// Shown while writing: what the Pencil gestures do, the underline colour, and a way out.
private struct PenBanner: View {
    @Binding var color: HighlightColor
    var done: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.tip").foregroundStyle(.secondary)
            Text("划线高亮 · 圈选提问 · 页边写字提问")
                .font(.footnote)
            Divider().frame(height: 18)
            ForEach(HighlightColor.allCases, id: \.self) { c in
                Button { color = c } label: {
                    Circle().fill(c.fill)
                        .overlay { Circle().strokeBorder(c.ink, lineWidth: color == c ? 2 : 0) }
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(c.name)色")
            }
            Divider().frame(height: 18)
            Button("完成", action: done).font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize()
    }
}

private struct MarginBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 0.5)
            }
    }
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
