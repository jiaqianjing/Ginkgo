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

                // Below the notes, so a card near the bottom covers the folio instead of the other way round.
                if model.chromeVisible && !model.showNotes {
                    PageIndicator(index: pageIndex, count: model.document.pageCount)
                        .position(x: layout.pageWidth / 2, y: geo.size.height - geo.safeAreaInsets.bottom - 28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

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
                        .frame(maxWidth: layout.pageWidth - Theme.menuInset * 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.cardInset)
                        .frame(width: layout.pageWidth)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if model.showNotes {
                    Theme.panelShade
                        .onTapGesture { withAnimation(.smooth) { model.showNotes = false } }
                        .transition(.opacity)
                    NotesPanel(model: model)
                        .frame(width: min(Theme.panelWidth, geo.size.width * 0.9), height: geo.size.height - 24)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                        .shadow(color: Theme.panelShadowColor, radius: Theme.panelShadow, x: Theme.panelShadowX)
                        .position(x: geo.size.width - min(Theme.panelWidth, geo.size.width * 0.9) / 2 - 12, y: geo.size.height / 2)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(.smooth(duration: 0.3), value: model.mode)
            .animation(.smooth(duration: 0.3), value: layout.hasMarginColumn)
            .onChange(of: layout.hasMarginColumn) { _, _ in DispatchQueue.main.async { model.recompute() } }
        }
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .background(Theme.desk)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.cardInset) { instructions; controls }
            VStack(spacing: Theme.rhythm) { instructions; controls }
        }
        .padding(.horizontal, Theme.cardInset)
        .padding(.vertical, Theme.rhythm)
        .glassEffect(.regular.tint(Theme.glassTint).interactive(), in: .rect(cornerRadius: Theme.panelRadius))
    }

    private var instructions: some View {
        Label("划线高亮 · 圈选提问 · 页边写字提问", systemImage: "pencil.tip")
            .font(Theme.footnoteFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        HStack(spacing: Theme.rhythm) {
            ForEach(HighlightColor.allCases, id: \.self) { c in
                Button { color = c } label: {
                    Circle().fill(c.fill)
                        .overlay { Circle().strokeBorder(c.ink, lineWidth: color == c ? 2 : 0) }
                        .overlay { if color == c { Image(systemName: "checkmark").font(Theme.checkFont).foregroundStyle(Theme.swatchInk) } }
                        .frame(width: Theme.swatchSize, height: Theme.swatchSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(c.name)色")
                .accessibilityAddTraits(color == c ? .isSelected : [])
            }
            Divider().frame(height: Theme.swatchSize)
            Button("完成", action: done).font(Theme.doneFont)
        }
    }

}

private struct MarginBackground: View {
    var body: some View {
        Rectangle()
            .fill(Theme.margin)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.rule).frame(width: Theme.hairline)
            }
    }
}

private struct PageIndicator: View {
    let index: Int
    let count: Int

    var body: some View {
        Text("\(index + 1) / \(count)")
            .font(Theme.labelFont.monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Space.generous)
            .padding(.vertical, Theme.folioVerticalInset)
            .glassEffect(.regular.tint(Theme.glassTint), in: .capsule)
    }
}
