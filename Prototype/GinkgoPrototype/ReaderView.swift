import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ReaderView: View {
    @State private var model = ReaderModel()
    @State private var importing = false
    @State private var question = ""

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let layout = ReaderLayout(size: geo.size, style: model.style)
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        PDFReaderView(model: model)
                            .frame(width: layout.pageWidth)
                        if layout.marginWidth > 0 {
                            MarginBackground()
                                .frame(width: layout.marginWidth)
                        }
                    }

                    MarksLayer(model: model)
                        .frame(width: layout.pageWidth)
                        .clipped()
                        .allowsHitTesting(false)

                    switch model.style {
                    case .sidenote:
                        ConnectorLayer(model: model, layout: layout)
                            .allowsHitTesting(false)
                        SidenoteColumn(model: model, layout: layout)
                    case .foldedMark:
                        FoldedMarksLayer(model: model, layout: layout)
                    case .handwritten:
                        HandColumn(model: model, layout: layout)
                    }

                    if model.penOn && layout.marginWidth > 0 {
                        InkMarginCanvas(model: model, layout: layout)
                            .frame(width: layout.marginWidth, height: geo.size.height)
                            .offset(x: layout.pageWidth)
                    }

                    SelectionMenu(model: model, layout: layout)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .animation(.smooth(duration: 0.35), value: model.style)
                .animation(.smooth(duration: 0.35), value: model.mode)
            }
            .background(Palette.desk)
            .navigationTitle(model.documentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { model.open(url: url) }
        }
        .alert("向 AI 提问", isPresented: Binding(get: { model.askingAbout != nil },
                                              set: { if !$0 { model.askingAbout = nil } })) {
            TextField("比如：这句话为什么这么说？", text: $question)
            Button("提问") {
                if let sel = model.askingAbout { model.create(.ask, from: sel, question: question.isEmpty ? nil : question) }
                question = ""
            }
            Button("取消", role: .cancel) { question = "" }
        } message: {
            Text(model.askingAbout?.string.map { "「\($0.prefix(60))」" } ?? "")
        }
        .task {
            HandFont.prepare()
            await DebugLaunch.run(model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("打开 PDF", systemImage: "doc.badge.plus") { importing = true }
        }
        ToolbarItem(placement: .principal) {
            Picker("批注风格", selection: $model.style) {
                ForEach(AnnotationStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Picker("模式", selection: $model.mode) {
                ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Button(model.penOn ? "停止书写" : "在页边书写", systemImage: model.penOn ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle") {
                model.penOn.toggle()
            }
            .disabled(model.style == .foldedMark)
        }
    }
}

/// Splits the screen between the page and the margin column for the current size and style.
struct ReaderLayout {
    let size: CGSize
    let style: AnnotationStyle

    var landscape: Bool { size.width > size.height }
    var marginWidth: CGFloat {
        guard style != .foldedMark else { return 0 }
        return landscape ? min(360, size.width * 0.3) : min(250, size.width * 0.3)
    }
    var pageWidth: CGFloat { size.width - marginWidth }
    var columnInset: CGFloat { 18 }
    var cardWidth: CGFloat { marginWidth - columnInset * 2 }
}

private struct MarginBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color(red: 0.937, green: 0.925, blue: 0.898))
            .overlay(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.06)).frame(width: 0.5)
            }
    }
}

// MARK: - Selection menu

private struct SelectionMenu: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        if let rect = model.selectionRect, let sel = model.selection {
            HStack(spacing: 2) {
                item("翻译", "character.bubble") { model.create(.translate, from: sel) }
                item("解释", "text.magnifyingglass") { model.create(.explain, from: sel) }
                item("提问", "questionmark.bubble") { model.askingAbout = sel }
            }
            .padding(4)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
            .position(x: min(max(rect.midX, 150), layout.pageWidth - 150), y: rect.maxY + 34)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private func item(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stacking

/// Places margin items at their anchor's height, pushing later ones down so none overlap.
func stack(_ items: [(id: UUID, y: CGFloat)], heights: [UUID: CGFloat], gap: CGFloat = 10,
           defaultHeight: CGFloat = 80) -> [UUID: CGFloat] {
    var out: [UUID: CGFloat] = [:]
    var floor = -CGFloat.infinity
    for item in items.sorted(by: { $0.y < $1.y }) {
        let y = max(item.y, floor)
        out[item.id] = y
        floor = y + (heights[item.id] ?? defaultHeight) + gap
    }
    return out
}

/// Launch arguments that set the prototype up for screenshots without touch input:
/// `-orientation landscape` (needs a full-screen build), `-demoSelect "<text>"`, `-demoCreate YES`, `-demoInk YES`.
enum DebugLaunch {
    @MainActor static func run(_ model: ReaderModel) async {
        let d = UserDefaults.standard
        if d.string(forKey: "orientation") == "landscape",
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        try? await Task.sleep(for: .seconds(1.2))
        if let text = d.string(forKey: "demoSelect"), let sel = model.document.findString(text, withOptions: []).first {
            model.pdfView?.currentSelection = sel
            model.pdfView?.go(to: sel)
            if d.bool(forKey: "demoCreate") {
                try? await Task.sleep(for: .seconds(0.5))
                model.create(.translate, from: sel)
            }
        }
        if d.bool(forKey: "demoInk") {
            model.penOn = true
            try? await Task.sleep(for: .seconds(0.5))
            NotificationCenter.default.post(name: .demoInk, object: nil)
        }
    }
}

extension Notification.Name {
    static let demoInk = Notification.Name("GinkgoDemoInk")
}
