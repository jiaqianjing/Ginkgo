import GinkgoCore
import PencilKit
import SwiftUI

// MARK: - Marks on the text

/// Highlight marks drawn over the page: a soft marker stroke per line, stronger for the focused annotation and
/// fainter in reading mode.
struct MarksLayer: View {
    let model: ReaderModel

    var body: some View {
        Canvas { ctx, _ in
            if model.penOn {
                for line in model.selectionLines {
                    ctx.fill(Path(roundedRect: line.insetBy(dx: -1, dy: -1), cornerRadius: Theme.markRadius),
                             with: .color(Theme.accent.opacity(Theme.Mark.selectionOpacity)))
                }
            }
            for record in model.annotations {
                guard let g = model.geometry[record.id] else { continue }
                let focused = model.focused == record.id
                let opacity = focused ? Theme.markFocusOpacity : (model.mode == .reading ? Theme.markReadingOpacity : Theme.markReviewOpacity)
                for line in g.lines {
                    let r = line.insetBy(dx: -1.5, dy: -0.5)
                    ctx.fill(Path(roundedRect: r, cornerRadius: Theme.markRadius), with: .color(record.color.fill.opacity(opacity)))
                }
                if focused || (record.hasNote && model.isOpen(record.id)) {
                    for line in g.lines {
                        var p = Path()
                        p.move(to: CGPoint(x: line.minX, y: line.maxY + 1))
                        p.addLine(to: CGPoint(x: line.maxX, y: line.maxY + 1))
                        ctx.stroke(p, with: .color(record.color.ink.opacity(Theme.Mark.underlineOpacity)), lineWidth: Theme.Mark.underlineWidth)
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
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(spacing: Theme.Space.compact) {
                Circle().fill(record.color.ink).frame(width: Theme.Card.dotSize, height: Theme.Card.dotSize)
                Text(record.taskLabel)
                    .font(Theme.labelFont)
                    .foregroundStyle(record.color.ink)
                Spacer(minLength: 0)
                if record.replyState == .pending || record.replyState == .streaming {
                    ThinkingDots(color: record.color.ink)
                }
            }
            if let data = record.inkData, let ink = try? PKDrawing(data: data) {
                InkImage(drawing: ink, maxWidth: width - Theme.cardInset * 2)
                    .modifier(NoteInkAppearance())
                if let q = record.question, !q.isEmpty {
                    Text("“\(q)”").font(Theme.captionFont).foregroundStyle(Theme.secondaryInk)
                }
            } else if let q = record.question, !q.isEmpty {
                Text(q)
                    .font(Theme.questionFont)
                    .foregroundStyle(Theme.ink)
            }
            answer
        }
        .padding(Theme.cardInset)
        .frame(width: width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.card)
                .shadow(color: floating ? Theme.Card.floatingShadow : Theme.Card.marginShadow, radius: floating ? Theme.floatingShadow : Theme.Card.marginRadius, y: floating ? Theme.Card.floatingY : Theme.Card.marginY)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Card.ruleRadius).fill(record.color.ink.opacity(Theme.Card.ruleOpacity)).frame(width: Theme.noteRuleWidth).padding(.vertical, Theme.cardInset)
        }
        .overlay {
            if model.focused == record.id {
                RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(record.color.ink.opacity(Theme.Card.focusOpacity), lineWidth: Theme.Card.borderWidth)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
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
            VStack(alignment: .leading, spacing: Theme.rhythm) {
                Text(record.replyError ?? "没有拿到回答。")
                    .font(Theme.footnoteFont)
                    .foregroundStyle(Theme.error)
                HStack {
                    Button("重试") { model.retry(record.id) }
                    if record.replyError?.contains("API key") == true {
                        Button("打开设置") { model.showSettings = true }
                    }
                }
                .font(Theme.actionFont)
                .buttonStyle(.bordered)
            }
        case .pending:
            Text("正在思考…").font(Theme.footnoteFont).foregroundStyle(Theme.secondaryInk)
        default:
            if let text = record.replyText {
                Text(text)
                    .font(Theme.noteFont)
                    .lineSpacing(Theme.lineSpacing)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: Theme.Thinking.interval, paused: reduceMotion)) { context in
            let step = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate * 3) % 3
            HStack(spacing: Theme.Space.tiny) {
                ForEach(0..<3) { i in
                    Circle().fill(color.opacity(i == step ? Theme.Thinking.activeOpacity : Theme.Thinking.idleOpacity)).frame(width: Theme.Thinking.size, height: Theme.Thinking.size)
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
                ctx.stroke(p, with: .color(record.color.ink.opacity(strong ? Theme.Connector.focusedOpacity : Theme.Connector.idleOpacity)), lineWidth: strong ? Theme.Connector.focusedWidth : Theme.Connector.idleWidth)
            }
        }
    }
}

struct MarginTick: View {
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule().fill(color.opacity(Theme.Connector.tickOpacity)).frame(width: Theme.tickWidth, height: Theme.tickHeight)
                .padding(.horizontal, Theme.rhythm).padding(.vertical, Theme.Space.small)
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
            let halfWidth = min(Theme.menuWidth, layout.pageWidth - Theme.menuInset * 2) / 2
            ActionCapsule(
                availableWidth: layout.pageWidth - Theme.menuInset * 2,
                colors: { color in withAnimation { _ = model.highlight(selection, color: color) } },
                translate: { model.run(.translate, on: selection) },
                explain: { model.run(.explain, on: selection) },
                ask: { model.asking = .selection(selection) },
                trailing: AnyView(Button { UIPasteboard.general.string = selection.string; model.clearSelection() } label: {
                    Image(systemName: "doc.on.doc").frame(minWidth: Theme.controlHeight, minHeight: Theme.controlHeight)
                }.accessibilityLabel("复制"))
            )
            .position(x: min(max(rect.midX, halfWidth + Theme.menuInset), layout.pageWidth - halfWidth - Theme.menuInset),
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
            let halfWidth = min(Theme.menuWidth, layout.pageWidth - Theme.menuInset * 2) / 2
            ActionCapsule(
                current: record.color,
                availableWidth: layout.pageWidth - Theme.menuInset * 2,
                colors: { color in model.recolor(id, color) },
                translate: { model.run(.translate, on: id) },
                explain: { model.run(.explain, on: id) },
                ask: { model.asking = .annotation(id) },
                trailing: AnyView(Button(role: .destructive) { withAnimation { model.delete(id) } } label: {
                    Image(systemName: "trash").frame(minWidth: Theme.controlHeight, minHeight: Theme.controlHeight)
                }.accessibilityLabel("删除高亮"))
            )
            .position(x: min(max(g.union.midX, halfWidth + Theme.menuInset), layout.pageWidth - halfWidth - Theme.menuInset),
                      y: min(g.union.maxY + 36, layout.size.height - 60))
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }
}

private struct ActionCapsule: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var current: HighlightColor?
    var availableWidth: CGFloat
    var colors: (HighlightColor) -> Void
    var translate: () -> Void
    var explain: () -> Void
    var ask: () -> Void
    var trailing: AnyView

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.rhythm) { swatches; actions }
            VStack(spacing: Theme.rhythm) { swatches; actions }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(Theme.rhythm)
        .frame(maxWidth: min(Theme.menuWidth, availableWidth))
        .glassEffect(.regular.tint(Theme.glassTint).interactive(), in: .rect(cornerRadius: Theme.panelRadius))
    }

    private var swatches: some View {
        HStack(spacing: Theme.Space.small) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button { colors(color) } label: {
                    Circle().fill(color.fill)
                        .overlay { Circle().strokeBorder(color.ink.opacity(current == color ? Theme.Swatch.selectedOpacity : Theme.Swatch.idleOpacity), lineWidth: current == color ? Theme.Swatch.selectedBorder : Theme.Swatch.idleBorder) }
                        .overlay { if current == color { Image(systemName: "checkmark").font(Theme.checkFont).foregroundStyle(Theme.swatchInk) } }
                        .frame(width: Theme.swatchSize, height: Theme.swatchSize)
                        .frame(width: Theme.swatchHitWidth, height: Theme.controlHeight)
                }
                .accessibilityLabel("\(color.name)色高亮")
                .accessibilityAddTraits(current == color ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if typeSize.isAccessibilitySize {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                     count: availableWidth < Theme.menuWidth ? 1 : 2), spacing: Theme.rhythm) {
                actionItems
            }
        } else {
            HStack(spacing: 0) { actionItems }
        }
    }

    @ViewBuilder private var actionItems: some View {
        item("翻译", "character.bubble", translate)
        item("解释", "text.magnifyingglass", explain)
        item("提问", "questionmark.bubble", ask)
        trailing
    }

    private func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.menuFont)
                .padding(.horizontal, Theme.Space.regular)
                .frame(minHeight: Theme.controlHeight)
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
                    .font(Theme.quoteFont)
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(5)
                    .padding(Theme.Space.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.margin))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(Theme.quoteRuleOpacity)).frame(width: Theme.noteRuleWidth) }
                TextField("比如：这句话为什么这么说？", text: $question, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Spacer()
            }
            .padding(Theme.Space.section)
            .background(Theme.paper)
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
