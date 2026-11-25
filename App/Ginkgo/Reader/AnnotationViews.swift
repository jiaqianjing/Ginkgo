import GinkgoAI
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
            if model.selectionFromPencil {
                for line in model.selectionLines {
                    ctx.fill(Path(roundedRect: line.insetBy(dx: -1, dy: -1), cornerRadius: Theme.markRadius),
                             with: .color(Theme.accent.opacity(Theme.Mark.selectionOpacity)))
                }
            }
            for record in model.annotations {
                guard let g = model.geometry[record.id] else { continue }
                let focused = model.focused == record.id
                let opacity = focused ? Theme.markFocusOpacity : (model.mode == .reading ? Theme.markReadingOpacity : Theme.markReviewOpacity)
                // A highlight inside this one keeps its own colour: this one is drawn as separate strokes around it.
                let holes = record.style == .highlight ? model.innerHighlights(of: record.id).flatMap { model.geometry[$0]?.lines ?? [] } : []
                // A rule inside a highlight skips its focus wash, which would double the colour under the word.
                let insideHighlight = record.style != .highlight
                    && model.passages[record.id].flatMap { model.enclosingMark(of: $0, style: .highlight) } != nil
                MarkPainter.paint(&ctx, lines: MarkPainter.segments(of: g.lines, around: holes), style: record.style,
                                  color: record.color, opacity: opacity, focused: focused && !insideHighlight)
                if record.style == .highlight, focused || (record.hasNote && model.isOpen(record.id)) {
                    for line in g.lines {
                        var p = Path()
                        p.move(to: CGPoint(x: line.minX, y: line.maxY + 1))
                        p.addLine(to: CGPoint(x: line.maxX, y: line.maxY + 1))
                        ctx.stroke(p, with: .color(record.color.ink.opacity(Theme.Mark.underlineOpacity)), lineWidth: Theme.Mark.underlineWidth)
                    }
                }
            }
            // The mark being drawn, following the text under the Pencil.
            if let preview = model.markPreview {
                MarkPainter.paint(&ctx, lines: preview.lines, style: preview.style, color: preview.color,
                                  opacity: Theme.markFocusOpacity, focused: false)
            }
        }
        .blendMode(.multiply)
        .overlay {
            // Pencil hover: where the current tool will land. The eraser has PencilKit's own preview.
            if let p = model.hoverPoint, let tool = model.tool, tool != .eraser {
                Circle()
                    .strokeBorder(hoverColor(tool), lineWidth: 1.5)
                    .frame(width: Theme.hoverRing, height: Theme.hoverRing)
                    .position(p)
            }
        }
    }

    private func hoverColor(_ tool: PenTool) -> Color {
        switch tool {
        case .highlighter, .underline: Theme.markLine(model.markColor)
        case .pen: model.inkColor.color
        default: Theme.accent
        }
    }
}

/// How marks look on the page, sized from the line height so they scale with zoom. A highlight is a marker pass:
/// a soft band over the x-height with rounded ends. Rules sit on the baseline, not at the bottom of the line box.
enum MarkPainter {
    /// An outer highlight's lines split around the inner highlights on them, so the outer stroke stops just short
    /// of each inner one, rounded like any marker end, instead of the two overlapping at the join.
    static func segments(of lines: [CGRect], around holes: [CGRect]) -> [CGRect] {
        guard !holes.isEmpty else { return lines }
        return lines.flatMap { line -> [CGRect] in
            let h = line.height
            // Room for both strokes' overhang at the join, plus a hairline gap.
            let clearance = h * Theme.Marker.overhang * 2 + Theme.Marker.joinGap
            let onLine = holes.filter { $0.intersection(line).height > min($0.height, h) / 2 }.sorted { $0.minX < $1.minX }
            var pieces: [CGRect] = []
            var start = line.minX
            for hole in onLine {
                let end = hole.minX - clearance
                if end - start > Theme.Marker.minPiece { pieces.append(CGRect(x: start, y: line.minY, width: end - start, height: h)) }
                start = max(start, hole.maxX + clearance)
            }
            if line.maxX - start > Theme.Marker.minPiece { pieces.append(CGRect(x: start, y: line.minY, width: line.maxX - start, height: h)) }
            return pieces
        }
    }

    static func paint(_ ctx: inout GraphicsContext, lines: [CGRect], style: MarkStyle, color: HighlightColor,
                      opacity: Double, focused: Bool) {
        for line in lines {
            let h = line.height
            switch style {
            case .highlight:
                let band = CGRect(x: line.minX - h * Theme.Marker.overhang, y: line.minY + h * Theme.Marker.topInset,
                                  width: line.width + h * Theme.Marker.overhang * 2,
                                  height: h * (1 - Theme.Marker.topInset - Theme.Marker.bottomInset))
                ctx.fill(Path(roundedRect: band, cornerRadius: band.height * Theme.Marker.roundness),
                         with: .color(color.fill.opacity(opacity)))
            case .underline, .squiggly:
                if focused {
                    ctx.fill(Path(roundedRect: line.insetBy(dx: -1.5, dy: -0.5), cornerRadius: Theme.markRadius),
                             with: .color(color.fill.opacity(Theme.Rule.focusFillOpacity)))
                }
                let y = line.maxY - h * Theme.Rule.baseline
                let width = min(max(h * Theme.Rule.relativeWidth, Theme.Rule.minWidth), Theme.Rule.maxWidth)
                var p = Path()
                if style == .squiggly {
                    p.addWave(from: CGPoint(x: line.minX, y: y), to: CGPoint(x: line.maxX, y: y),
                              amplitude: max(h * Theme.Rule.waveAmplitude, 1), wavelength: max(h * Theme.Rule.waveLength, 4))
                } else {
                    p.move(to: CGPoint(x: line.minX, y: y))
                    p.addLine(to: CGPoint(x: line.maxX, y: y))
                }
                ctx.stroke(p, with: .color(Theme.markLine(color).opacity(Theme.Rule.opacity)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Note card

/// One AI note: what was asked, the answer as it streams in, and the follow-up rounds under it.
/// Translations of a language the reader is learning add a word card, or key expressions and a grammar walk-through.
struct NoteCard: View {
    let model: ReaderModel
    let record: AnnotationRecord
    var width: CGFloat
    var floating = false
    /// Floating on the page: long answers are cut short and offer to open in the side column.
    var compact = false
    /// Off in the conversation panel, which lays out the follow-up rounds itself and has its own box.
    var showsThread = true
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0
    @State private var showEarlier = false

    private var activity: NoteActivity? { model.busy[record.id] }
    private var study: StudyNote { record.study }
    private var thread: [FollowUp] { record.thread }
    private var working: Bool { record.replyState == .pending || record.replyState == .streaming || activity != nil }
    private var canFollowUp: Bool { record.replyState == .done && activity == nil }

    /// Parts the floating card leaves for the full view.
    private var hidesParts: Bool {
        compact && ((study.keyItems?.items.count ?? 0) > NoteParts.compactKeyItems || study.analysis != nil || !thread.isEmpty)
    }
    private var truncated: Bool { compact && (fullHeight > shownHeight + 1 || hidesParts) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            header
            parentLink
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
            if record.replyState == .done { studyParts }
            childLinks
            if showsThread {
                followUps
                footer
            }
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
        .contextMenu { noteActions }
    }

    /// The card's actions, behind both the ⋯ button and a long press.
    @ViewBuilder private var noteActions: some View {
        if let text = record.replyText {
            Button("复制回答", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
        if canFollowUp {
            Button("追问", systemImage: "arrow.turn.down.right") { withAnimation(.smooth(duration: 0.3)) { model.openConversation(record.id, compose: true) } }
        }
        Menu("换颜色", systemImage: "paintpalette") { colorChoices }
        Button("重新回答", systemImage: "arrow.clockwise") { model.retry(record.id) }
        Button("收起", systemImage: "chevron.up") { withAnimation { model.toggle(record.id) } }
        Divider()
        if record.kind == .highlight {
            Button("删除批注，保留划线", systemImage: "text.badge.minus", role: .destructive) {
                withAnimation { model.removeNote(record.id) }
            }
            Button("删除划线和批注", systemImage: "trash", role: .destructive) { withAnimation { model.delete(record.id) } }
        } else {
            Button("删除批注", systemImage: "trash", role: .destructive) { withAnimation { model.delete(record.id) } }
        }
    }

    /// A word card names the sentence it was looked up in; a tap opens that sentence's card.
    @ViewBuilder private var parentLink: some View {
        if let parent = model.parentNote(of: record.id), let quote = parent.anchor?.quote {
            Button { withAnimation(.smooth(duration: 0.25)) { model.reveal(parent.id) } } label: {
                Label("在「\(NoteParts.excerpt(quote))」这句里", systemImage: "arrow.up.left")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开这句话的批注")
        }
    }

    /// A sentence card lists the words looked up inside it; a tap opens that word's card.
    @ViewBuilder private var childLinks: some View {
        let children = model.childNotes(of: record.id)
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.compact) {
                NoteParts.heading("句中查过")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.compact) {
                        ForEach(children, id: \.id) { child in
                            Button { withAnimation(.smooth(duration: 0.25)) { model.reveal(child.id) } } label: {
                                Text(NoteParts.excerpt(child.anchor?.quote ?? ""))
                                    .font(Theme.captionFont)
                                    .foregroundStyle(child.color.ink)
                                    .padding(.horizontal, Theme.Space.small)
                                    .padding(.vertical, Theme.Space.tiny)
                                    .background(Capsule().fill(child.color.fill.opacity(Theme.Card.chipOpacity)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("打开这个词的批注")
                        }
                    }
                }
            }
        }
    }

    /// The colour dot doubles as the colour menu.
    private var header: some View {
        HStack(spacing: Theme.Space.compact) {
            Menu { colorChoices } label: {
                Circle().fill(record.color.ink).frame(width: Theme.Card.dotSize, height: Theme.Card.dotSize)
                    .frame(width: Theme.Card.dotHit, height: Theme.Card.dotHit)
                    .contentShape(Rectangle())
            }
            .padding(-(Theme.Card.dotHit - Theme.Card.dotSize) / 2)
            .accessibilityLabel("换颜色，现在是\(record.color.name)色")
            Text(record.taskLabel)
                .font(Theme.labelFont)
                .foregroundStyle(record.color.ink)
            Spacer(minLength: 0)
            if working { ThinkingDots(color: record.color.ink) }
            if model.focused == record.id {
                ViewThatFits(in: .horizontal) {
                    quickActions
                    EmptyView()
                }
                .transition(.opacity)
            }
            Menu { noteActions } label: {
                Image(systemName: "ellipsis")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: Theme.Card.dotHit, height: Theme.Card.dotHit)
                    .contentShape(Rectangle())
            }
            .padding(-Theme.Space.compact)
            .accessibilityLabel("更多操作")
        }
    }

    /// On the card in focus: the colours and delete (card and mark together), one tap each. Keeping the mark
    /// while dropping the note is in ⋯.
    private var quickActions: some View {
        HStack(spacing: 0) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button { withAnimation(.smooth(duration: 0.2)) { model.recolor(record.id, color) } } label: {
                    Circle().fill(color.fill)
                        .overlay { Circle().strokeBorder(color.ink.opacity(record.color == color ? Theme.Swatch.selectedOpacity : Theme.Swatch.idleOpacity),
                                                         lineWidth: record.color == color ? Theme.Swatch.selectedBorder : Theme.Swatch.idleBorder) }
                        .frame(width: Theme.Card.swatch, height: Theme.Card.swatch)
                        .frame(width: Theme.Card.swatchHit, height: Theme.Card.dotHit)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(color.name)色")
                .accessibilityAddTraits(record.color == color ? .isSelected : [])
            }
            Button(role: .destructive) { withAnimation { model.delete(record.id) } } label: {
                Image(systemName: "trash")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.error)
                    .frame(width: Theme.Card.dotHit, height: Theme.Card.dotHit)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(record.kind == .highlight ? "删除划线和批注" : "删除批注")
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder private var colorChoices: some View {
        ForEach(HighlightColor.allCases, id: \.self) { color in
            Button { withAnimation(.smooth(duration: 0.2)) { model.recolor(record.id, color) } } label: {
                if record.color == color { Label("\(color.name)色", systemImage: "checkmark") } else { Text("\(color.name)色") }
            }
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
            if let word = study.word {
                WordCardView(card: word)
            } else if let text = record.replyText {
                answerText(text)
                    .lineLimit(compact ? Theme.Card.compactLines : nil)
                    .textSelection(.enabled)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { shownHeight = $0 }
                    .background(alignment: .top) {
                        if compact {
                            answerText(text).hidden()
                                .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
                        }
                    }
            }
        }
    }

    /// Key expressions, then the grammar walk-through or the button that asks for it.
    @ViewBuilder private var studyParts: some View {
        if let items = study.keyItems?.items, !items.isEmpty {
            NoteParts.divider
            KeyItemsView(items: compact ? Array(items.prefix(NoteParts.compactKeyItems)) : items)
        }
        if activity == .keyItems {
            NoteParts.progress("正在找重点表达…")
        } else if let error = study.keyItemsError {
            NoteParts.failure("重点表达没拿到：\(error)") { model.retryKeyItems(record.id) }
        }
        if activity == .analysis {
            NoteParts.progress("正在分析句子…")
        } else if let analysis = study.analysis {
            if !compact {
                NoteParts.divider
                AnalysisView(analysis: analysis)
            }
        } else if let error = study.analysisError {
            NoteParts.failure("分析没拿到：\(error)") { model.analyze(record.id) }
        } else if study.keyItems?.analysisWorthy == true, activity == nil {
            Button { model.analyze(record.id) } label: {
                Label {
                    Text("语法分析") + Text(study.keyItems?.analysisHint.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? "")
                        .foregroundStyle(Theme.secondaryInk)
                } icon: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                }
                .font(Theme.actionFont)
                .foregroundStyle(record.color.ink)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
        }
    }

    /// Follow-up rounds. The floating card shows the latest; the full view folds all but the latest.
    @ViewBuilder private var followUps: some View {
        if !thread.isEmpty {
            let earlier = thread.count - 1
            let shown = compact || (!showEarlier && earlier > 0) ? Array(thread.suffix(1)) : thread
            NoteParts.divider
            if !compact, earlier > 0 {
                Button { withAnimation(.smooth(duration: 0.2)) { showEarlier.toggle() } } label: {
                    Label(showEarlier ? "收起前 \(earlier) 轮" : "前 \(earlier) 轮追问",
                          systemImage: showEarlier ? "chevron.up" : "chevron.down")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { offset, turn in
                FollowUpView(turn: turn, waiting: offset == shown.count - 1 && activity == .followUp,
                             lineLimit: compact ? Theme.Card.compactLines : nil,
                             retry: offset == shown.count - 1 ? { model.retryFollowUp(record.id) } : nil)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if canFollowUp || truncated {
            HStack(spacing: Theme.Space.regular) {
                if canFollowUp {
                    Button { withAnimation(.smooth(duration: 0.3)) { model.openConversation(record.id, compose: true) } } label: {
                        Label("追问", systemImage: "arrow.turn.down.right")
                    }
                }
                Spacer(minLength: 0)
                if truncated {
                    Button { withAnimation(.smooth(duration: 0.3)) { model.expand(record.id) } } label: {
                        Label("展开全文", systemImage: "sidebar.right")
                    }
                }
            }
            .font(Theme.actionFont)
            .foregroundStyle(record.color.ink)
            .buttonStyle(.plain)
        }
    }
}

private extension NoteCard {
    func answerText(_ text: String) -> some View {
        Text(text)
            .font(Theme.noteFont)
            .lineSpacing(Theme.lineSpacing)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
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
                        NoteTab(record: record) { withAnimation(.smooth(duration: 0.25)) { model.toggle(record.id) } }
                            .offset(x: layout.pageWidth + layout.columnInset, y: g.first.minY - 4)
                    }
                }
            }
        }
    }

    private func positions() -> [UUID: CGFloat] {
        let items = model.notes.compactMap { r -> MarginLayout.Item<UUID>? in
            guard let g = model.geometry[r.id] else { return nil }
            let h = model.isOpen(r.id) ? (model.cardHeights[r.id] ?? 90) : Theme.Tab.height
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

/// A small tab on the page edge for each note, like a sticky flag in a book: its colour and what kind of note it is.
struct NoteTab: View {
    let record: AnnotationRecord
    var active = false
    var action: () -> Void

    private var symbol: String {
        if record.inkData != nil { return "pencil.and.scribble" }
        switch record.taskRaw {
        case "translate": return "character.bubble"
        case "explain": return "text.magnifyingglass"
        default: return "questionmark"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Tab.font)
                .foregroundStyle(record.color.ink)
                .frame(width: Theme.Tab.width, height: Theme.Tab.height)
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: Theme.Tab.radius, bottomLeadingRadius: Theme.Tab.radius,
                                           bottomTrailingRadius: Theme.Tab.tipRadius, topTrailingRadius: Theme.Tab.tipRadius)
                        .fill(record.color.fill.opacity(active ? Theme.Tab.activeOpacity : Theme.Tab.idleOpacity))
                        .shadow(color: Theme.Tab.shadow, radius: Theme.Tab.shadowRadius, y: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(record.color.ink.opacity(Theme.Tab.edgeOpacity)).frame(width: Theme.Tab.edgeWidth)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.Tab.radius, bottomLeadingRadius: Theme.Tab.radius,
                                                  bottomTrailingRadius: Theme.Tab.tipRadius, topTrailingRadius: Theme.Tab.tipRadius))
                .padding(Theme.Space.small)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-Theme.Space.small)
        .accessibilityLabel(active ? "收起\(record.taskLabel)批注" : "打开\(record.taskLabel)批注")
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
                    NoteTab(record: record, active: model.isOpen(record.id)) {
                        withAnimation(.smooth(duration: 0.25)) { model.toggle(record.id) }
                    }
                    .offset(x: page.maxX - Theme.Tab.width - Theme.Tab.edgeInset, y: g.first.minY - 4)
                    if model.isOpen(record.id), model.expanded != record.id, let top = tops[record.id] {
                        NoteCard(model: model, record: record, width: layout.floatingCardWidth, floating: true, compact: true)
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
            guard model.isOpen(r.id), model.expanded != r.id, let g = model.geometry[r.id] else { return nil }
            return .init(id: r.id, anchorY: g.union.maxY + 8, height: model.cardHeights[r.id] ?? 100)
        }
        var tops = MarginLayout.stack(items, gap: 10)
        let bottom = layout.size.height - Theme.Space.large * 2
        let ceiling = Theme.Space.large * 3
        // A card that would run off the bottom of the screen goes above its passage instead...
        for item in items {
            guard let top = tops[item.id], top + item.height > bottom, let g = model.geometry[item.id] else { continue }
            tops[item.id] = max(ceiling, g.first.minY - item.height - 8)
        }
        // ...then the cards are restacked so none overlap, and pushed up from the bottom edge if they still overflow.
        let moved = items.compactMap { item in tops[item.id].map { MarginLayout.Item(id: item.id, anchorY: $0, height: item.height) } }
            .sorted { $0.anchorY < $1.anchorY }
        tops = MarginLayout.stack(moved, gap: 10)
        var limit = bottom
        for item in moved.reversed() {
            guard let top = tops[item.id] else { continue }
            let fitted = max(ceiling, min(top, limit - item.height))
            tops[item.id] = fitted
            limit = fitted - 10
        }
        return tops
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
