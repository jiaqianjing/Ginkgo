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
    @State private var downloading = false

    var body: some View {
        Group {
            if let model {
                ReaderContent(model: model)
            } else if downloading {
                VStack(spacing: Theme.Space.generous) {
                    ProgressView()
                    Text("正在从 iCloud 下载这本书…").font(Theme.calloutFont).foregroundStyle(Theme.secondaryInk)
                }
            } else if missing {
                ContentUnavailableView("找不到这本书的文件", systemImage: "exclamationmark.triangle",
                                       description: Text("文件可能已被删除。可以从书库里删掉它，再重新导入。"))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) { await open() }
    }

    private func open() async {
        guard model == nil else { return }
        let files = BookFiles.shared
        while !files.isReady(book.fileName) {
            // Without iCloud a missing file is gone; with it, the file may still be on its way from another device.
            if files.resolved && files.cloudDirectory == nil { missing = true; return }
            downloading = true
            files.download(book.fileName)
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        downloading = false
        guard let document = PDFDocument(url: book.fileURL) else { missing = true; return }
        book.lastOpenedAt = .now
        model = ReaderModel(book: book, document: document, context: context)
    }
}

private struct ReaderContent: View {
    @Bindable var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var pageIndex = 0

    var body: some View {
        GeometryReader { geo in
            let conversation = model.expanded.flatMap { model.annotation($0) }
            let layout = ReaderLayout(size: geo.size,
                                      sidebar: model.mode == .review || conversation != nil,
                                      conversation: conversation != nil,
                                      scratch: model.showScratch ? model.scratchWidth : 0)
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

                if let notice = model.notice {
                    NoticeLine(text: notice)
                        .position(x: layout.pageWidth / 2, y: geo.size.height - geo.safeAreaInsets.bottom - 76)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Group {
                    if layout.hasMarginColumn, conversation == nil {
                        ConnectorLayer(model: model, layout: layout).allowsHitTesting(false)
                        if model.tool == .pen {
                            MarginInkCanvas(model: model, layout: layout)
                                .frame(width: layout.marginWidth, height: geo.size.height)
                                .offset(x: layout.pageWidth)
                        }
                        SidenoteColumn(model: model, layout: layout)
                    } else if conversation == nil || model.mode == .reading {
                        // With a conversation docked, other notes stay as tabs (and one floating card) on the page.
                        FoldedNotesLayer(model: model, layout: layout)
                    }
                    if let record = conversation {
                        if layout.hasMarginColumn {
                            ConversationPanel(model: model, record: record, width: layout.marginWidth, docked: true)
                                .frame(height: geo.size.height)
                                .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: Theme.hairline) }
                                .offset(x: layout.pageWidth)
                                .transition(.move(edge: .trailing))
                        } else {
                            ConversationPanel(model: model, record: record, width: layout.panelWidth, docked: false)
                                .frame(height: geo.size.height - Theme.Space.large * 2)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                                .shadow(color: Theme.panelShadowColor, radius: Theme.panelShadow, x: Theme.panelShadowX)
                                .frame(width: geo.size.width - Theme.rhythm, height: geo.size.height, alignment: .trailing)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()

                SelectionMenu(model: model, layout: layout)
                AnnotationMenu(model: model, layout: layout)


                if model.showScratch {
                    // Beside the page it runs full height; floating, it starts below the tray so the tray keeps its room.
                    let top = layout.scratchBeside ? 0 : Theme.Tray.topInset + Theme.Tray.button + Theme.Space.compact * 2 + Theme.Space.small
                    let shape = UnevenRoundedRectangle(topLeadingRadius: layout.scratchBeside ? 0 : Theme.panelRadius)
                    ScratchSheet(model: model, maxWidth: layout.isWide ? geo.size.width * 0.5 : geo.size.width - 64)
                        .frame(width: layout.scratchWidth, height: geo.size.height - top)
                        .clipShape(shape)
                        .overlay { shape.stroke(Theme.rule, lineWidth: Theme.hairline) }
                        .shadow(color: layout.scratchBeside ? .clear : Theme.panelShadowColor,
                                radius: Theme.panelShadow, x: Theme.panelShadowX)
                        .offset(x: geo.size.width - layout.scratchWidth, y: top)
                        .transition(.move(edge: .trailing))
                }

                VStack(spacing: Theme.rhythm) {
                    ToolTray(model: model)
                    if model.showToolHint {
                        ToolHint(model: model) { withAnimation(.smooth) { model.dismissToolHint() } }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, Theme.Tray.topInset)
                .frame(width: layout.pageWidth)
                .opacity(model.chromeVisible ? 1 : 0)
                .allowsHitTesting(model.chromeVisible)


                if let point = model.paletteAt {
                    SqueezePalette(model: model, point: point, bounds: CGSize(width: layout.pageWidth, height: geo.size.height))
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
            .animation(.smooth(duration: 0.3), value: model.expanded)
            .animation(.smooth(duration: 0.3), value: model.showScratch)
            .onChange(of: layout.hasMarginColumn) { _, _ in DispatchQueue.main.async { model.recompute() } }
        }
        // Only the container's edges: the keyboard still pushes content up, so the conversation box stays above it.
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        // The right edge belongs to the reader first: a swipe in from it opens the side column.
        .defersSystemGestures(on: .trailing)
        .background(Theme.desk)
        .toolbarVisibility(model.chromeVisible ? .visible : .hidden, for: .navigationBar)
        .statusBarHidden(!model.chromeVisible)
        .toolbar { toolbar }
        .sheet(item: $model.asking) { AskSheet(model: model, target: $0) }
        .sheet(isPresented: $model.showSettings, onDismiss: model.refreshFingerInput) { SettingsView() }
        // Buttons answer it; the binding never dismisses on its own, so a tap can't count as both answers.
        .alert(model.askingConsent.map { String(localized: "把文字发给 \($0.displayName)？") } ?? "",
               isPresented: Binding(get: { model.askingConsent != nil }, set: { _ in }),
               presenting: model.askingConsent) { _ in
            Button("同意并发送") { model.answerConsent(true) }
            Button("取消", role: .cancel) { model.answerConsent(false) }
        } message: { provider in
            Text(ConsentText.message(provider))
        }

        .onAppear { pageIndex = model.book.lastPageIndex }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshFingerInput() } }
        .onDisappear { model.pageInk.saveAll(); model.saveScratch() }
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
            Button("批注", systemImage: "list.bullet.rectangle") { withAnimation(.smooth) { model.showNotes.toggle() } }
            Button("设置", systemImage: "gearshape") { model.showSettings = true }
        }
    }

    private func pageChanged(_ index: Int) {
        pageIndex = index
        model.book.lastPageIndex = index
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

/// A passing remark at the bottom of the page, e.g. why the eraser left a mark alone.
private struct NoticeLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.footnoteFont)
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Space.generous)
            .padding(.vertical, Theme.folioVerticalInset)
            .glassEffect(.regular.tint(Theme.glassTint), in: .capsule)
            .accessibilityAddTraits(.updatesFrequently)
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
