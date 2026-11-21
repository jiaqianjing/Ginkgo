import GinkgoCore
import SwiftUI

// MARK: - Marks on the text

/// Highlight marks drawn over the page: a soft marker stroke per line, stronger for the focused annotation and
/// fainter in reading mode.
struct MarksLayer: View {
    let model: ReaderModel

    var body: some View {
        Canvas { ctx, _ in
            for record in model.annotations {
                guard let g = model.geometry[record.id] else { continue }
                let focused = model.focused == record.id
                let opacity = focused ? 0.55 : (model.mode == .reading ? 0.32 : 0.42)
                for line in g.lines {
                    let r = line.insetBy(dx: -1.5, dy: -0.5)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(record.color.fill.opacity(opacity)))
                }
                if focused || (record.hasNote && model.isOpen(record.id)) {
                    for line in g.lines {
                        var p = Path()
                        p.move(to: CGPoint(x: line.minX, y: line.maxY + 1))
                        p.addLine(to: CGPoint(x: line.maxX, y: line.maxY + 1))
                        ctx.stroke(p, with: .color(record.color.ink.opacity(0.8)), lineWidth: 1.4)
                    }
                }
            }
        }
        .blendMode(.multiply)
    }
}

// MARK: - Note card

/// One AI note: what was asked, then the answer as it streams in.
struct NoteCard: View {
    let model: ReaderModel
    let record: AnnotationRecord
    var width: CGFloat
    var floating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(record.color.ink).frame(width: 7, height: 7)
                Text(record.taskLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(record.color.ink)
                Spacer(minLength: 0)
                if record.replyState == .pending || record.replyState == .streaming {
                    ThinkingDots(color: record.color.ink)
                }
            }
            if let q = record.question, !q.isEmpty {
                Text(q)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            answer
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .systemBackground).opacity(floating ? 0.98 : 0.92))
                .shadow(color: .black.opacity(floating ? 0.16 : 0.07), radius: floating ? 16 : 6, y: floating ? 6 : 2)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(record.color.fill).frame(width: 3).padding(.vertical, 12)
        }
        .overlay {
            if model.focused == record.id {
                RoundedRectangle(cornerRadius: 14).strokeBorder(record.color.ink.opacity(0.35), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { withAnimation(.smooth(duration: 0.2)) { model.focused = record.id } }
        .contextMenu {
            if let text = record.replyText {
                Button("复制回答", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            }
            Button("重新回答", systemImage: "arrow.clockwise") { model.retry(record.id) }
            Button("收起", systemImage: "chevron.up") { withAnimation { model.toggle(record.id) } }
            Divider()
            Button("删除批注", systemImage: "trash", role: .destructive) { withAnimation { model.delete(record.id) } }
        }
    }

    @ViewBuilder private var answer: some View {
        switch record.replyState {
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(record.replyError ?? "没有拿到回答。")
                    .font(.footnote)
                    .foregroundStyle(.red)
                HStack {
                    Button("重试") { model.retry(record.id) }
                    if record.replyError?.contains("API key") == true {
                        Button("打开设置") { model.showSettings = true }
                    }
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.bordered)
            }
        case .pending:
            Text("正在思考…").font(.footnote).foregroundStyle(.secondary)
        default:
            if let text = record.replyText {
                Text(text)
                    .font(.system(.subheadline, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ThinkingDots: View {
    var color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 3) % 3
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle().fill(color.opacity(i == step ? 0.9 : 0.3)).frame(width: 4, height: 4)
                }
            }
        }
    }
}

// MARK: - Style A: margin column

/// Cards in the margin column, each level with its line and pushed down when they would overlap.
/// In reading mode only a small tick marks each note; tapping it opens the card.
struct SidenoteColumn: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        let tops = positions()
        ZStack(alignment: .topLeading) {
            ForEach(model.notes, id: \.id) { record in
                if let g = model.geometry[record.id], let top = tops[record.id] {
                    if model.isOpen(record.id) {
                        NoteCard(model: model, record: record, width: layout.cardWidth)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { model.cardHeights[record.id] = $0 }
                            .offset(x: layout.pageWidth + layout.columnInset, y: top)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else {
                        MarginTick(color: record.color.ink) { withAnimation(.smooth(duration: 0.25)) { model.toggle(record.id) } }
                            .offset(x: layout.pageWidth + 10, y: g.first.minY - 2)
                    }
                }
            }
        }
    }

    private func positions() -> [UUID: CGFloat] {
        let items = model.notes.compactMap { r -> MarginLayout.Item<UUID>? in
            guard let g = model.geometry[r.id] else { return nil }
            let h = model.isOpen(r.id) ? (model.cardHeights[r.id] ?? 90) : 22
            return .init(id: r.id, anchorY: g.first.minY - 8, height: h)
        }
        return MarginLayout.stack(items, gap: 12)
    }
}

/// Thin curves from the end of a passage's last line to its open card.
struct ConnectorLayer: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        let items = model.notes.compactMap { r -> MarginLayout.Item<UUID>? in
            guard let g = model.geometry[r.id] else { return nil }
            let h = model.isOpen(r.id) ? (model.cardHeights[r.id] ?? 90) : 22
            return .init(id: r.id, anchorY: g.first.minY - 8, height: h)
        }
        let tops = MarginLayout.stack(items, gap: 12)
        Canvas { ctx, _ in
            for record in model.notes where model.isOpen(record.id) {
                guard let g = model.geometry[record.id], let top = tops[record.id] else { continue }
                let start = CGPoint(x: g.first.maxX + 4, y: g.first.midY)
                let end = CGPoint(x: layout.pageWidth + layout.columnInset, y: top + 20)
                var p = Path()
                p.move(to: start)
                p.addCurve(to: end, control1: CGPoint(x: start.x + 60, y: start.y),
                           control2: CGPoint(x: end.x - 60, y: end.y))
                let strong = model.focused == record.id
                ctx.stroke(p, with: .color(record.color.ink.opacity(strong ? 0.55 : 0.22)), lineWidth: strong ? 1.2 : 0.8)
            }
        }
    }
}

struct MarginTick: View {
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule().fill(color.opacity(0.75)).frame(width: 4, height: 18)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开批注")
    }
}

// MARK: - Style B: folded marks

/// Portrait: a coloured tick in the page's right margin for each note; tapping it opens a card that floats just
/// below the passage. In review mode every card is open.
struct FoldedNotesLayer: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        let tops = positions()
        ZStack(alignment: .topLeading) {
            ForEach(model.notes, id: \.id) { record in
                if let g = model.geometry[record.id], let page = pageFrame(for: g) {
                    MarginTick(color: record.color.ink) { withAnimation(.smooth(duration: 0.25)) { model.toggle(record.id) } }
                        .offset(x: page.maxX - 26, y: g.first.minY - 3)
                    if model.isOpen(record.id), let top = tops[record.id] {
                        NoteCard(model: model, record: record, width: layout.floatingCardWidth, floating: true)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { model.cardHeights[record.id] = $0 }
                            .offset(x: cardX(page), y: top)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
            }
        }
    }

    private func pageFrame(for g: NoteGeometry) -> CGRect? {
        model.pageFrames.first { $0.intersects(g.first) } ?? model.pageFrames.first
    }

    private func cardX(_ page: CGRect) -> CGFloat {
        min(max(page.maxX - layout.floatingCardWidth - 36, 16), layout.size.width - layout.floatingCardWidth - 16)
    }

    private func positions() -> [UUID: CGFloat] {
        let items = model.notes.compactMap { r -> MarginLayout.Item<UUID>? in
            guard model.isOpen(r.id), let g = model.geometry[r.id] else { return nil }
            return .init(id: r.id, anchorY: g.union.maxY + 8, height: model.cardHeights[r.id] ?? 100)
        }
        return MarginLayout.stack(items, gap: 10)
    }
}

// MARK: - Menus

/// Shown under a text selection: highlight colours, then the AI actions.
struct SelectionMenu: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        if let rect = model.selectionRect, let selection = model.selection {
            ActionCapsule(
                colors: { color in withAnimation { _ = model.highlight(selection, color: color) } },
                translate: { model.run(.translate, on: selection) },
                explain: { model.run(.explain, on: selection) },
                ask: { model.asking = .selection(selection) },
                trailing: AnyView(Button { UIPasteboard.general.string = selection.string; model.clearSelection() } label: {
                    Image(systemName: "doc.on.doc").frame(width: 34, height: 34)
                }.accessibilityLabel("复制"))
            )
            .position(x: min(max(rect.midX, 230), layout.pageWidth - 230),
                      y: min(rect.maxY + 36, layout.size.height - 60))
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }
}

/// Shown on a tapped highlight: change its colour, ask about it, or delete it.
struct AnnotationMenu: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        if model.selection == nil, let id = model.focused, let record = model.annotation(id), !record.hasNote,
           let g = model.geometry[id] {
            ActionCapsule(
                current: record.color,
                colors: { color in model.recolor(id, color) },
                translate: { model.run(.translate, on: id) },
                explain: { model.run(.explain, on: id) },
                ask: { model.asking = .annotation(id) },
                trailing: AnyView(Button(role: .destructive) { withAnimation { model.delete(id) } } label: {
                    Image(systemName: "trash").frame(width: 34, height: 34)
                }.accessibilityLabel("删除高亮"))
            )
            .position(x: min(max(g.union.midX, 230), layout.pageWidth - 230),
                      y: min(g.union.maxY + 36, layout.size.height - 60))
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }
}

private struct ActionCapsule: View {
    var current: HighlightColor?
    var colors: (HighlightColor) -> Void
    var translate: () -> Void
    var explain: () -> Void
    var ask: () -> Void
    var trailing: AnyView

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button { colors(color) } label: {
                    Circle().fill(color.fill)
                        .overlay { Circle().strokeBorder(color.ink.opacity(current == color ? 0.9 : 0.25), lineWidth: current == color ? 2 : 1) }
                        .frame(width: 22, height: 22)
                        .frame(width: 30, height: 34)
                }
                .accessibilityLabel("\(color.name)色高亮")
            }
            Divider().frame(height: 22).padding(.horizontal, 4)
            item("翻译", "character.bubble", translate)
            item("解释", "text.magnifyingglass", explain)
            item("提问", "questionmark.bubble", ask)
            Divider().frame(height: 22).padding(.horizontal, 2)
            trailing
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize()
    }

    private func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 8)
                .frame(height: 34)
        }
    }
}

// MARK: - Ask sheet

struct AskSheet: View {
    let model: ReaderModel
    let target: AskTarget
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @FocusState private var focused: Bool

    private var quote: String {
        switch target {
        case .selection(let s): s.string ?? ""
        case .annotation(let id): model.annotation(id)?.anchor?.quote ?? ""
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(quote)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                TextField("比如：这句话为什么这么说？", text: $question, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Spacer()
            }
            .padding(20)
            .navigationTitle("向 AI 提问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提问", action: send).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        switch target {
        case .selection(let s): model.run(.ask(q), on: s)
        case .annotation(let id): model.run(.ask(q), on: id)
        }
        dismiss()
    }
}
