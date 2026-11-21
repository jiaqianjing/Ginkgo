import SwiftUI

// MARK: - Marks on the page

/// Hand-drawn marks over the PDF text: marker strokes, a pencil circle, a wavy underline.
struct MarksLayer: View {
    let model: ReaderModel

    var body: some View {
        Canvas { ctx, _ in
            for note in model.notes {
                guard let g = model.geometry[note.id] else { continue }
                let active = model.active == note.id
                let faint = model.mode == .reading && !active && model.peeked != note.id
                switch note.mark {
                case .marker:
                    for (i, r) in g.lines.enumerated() {
                        var path = Path()
                        let h = r.height * 0.78
                        let y = r.midY - h / 2 + r.height * 0.06
                        let wobble = CGFloat((i * 37 + Int(r.minX)) % 5) * 0.4
                        path.move(to: CGPoint(x: r.minX - 2, y: y + wobble))
                        path.addLine(to: CGPoint(x: r.maxX + 2, y: y))
                        path.addLine(to: CGPoint(x: r.maxX + 1, y: y + h))
                        path.addLine(to: CGPoint(x: r.minX - 1, y: y + h - wobble))
                        path.closeSubpath()
                        ctx.fill(path, with: .color(note.kind.highlight.opacity(faint ? 0.45 : (active ? 1.3 : 1))))
                    }
                case .circle:
                    let r = g.union.insetBy(dx: -4, dy: -4)
                    var path = Path()
                    let steps = 48
                    for s in 0...steps + 5 {
                        let t = CGFloat(s) / CGFloat(steps) * 2 * .pi - 0.5
                        let grow = 1 + 0.06 * CGFloat(s) / CGFloat(steps)
                        let p = CGPoint(x: r.midX + cos(t) * r.width / 2 * grow, y: r.midY + sin(t) * r.height / 2 * grow)
                        s == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    ctx.fill(Path(ellipseIn: r), with: .color(note.kind.highlight.opacity(active ? 1 : 0.6)))
                    ctx.stroke(path, with: .color(note.kind.accent.opacity(faint ? 0.35 : 0.85)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                case .underline:
                    for r in g.lines {
                        var path = Path()
                        let y = r.maxY + 1
                        path.move(to: CGPoint(x: r.minX, y: y))
                        var x = r.minX
                        var up = true
                        while x < r.maxX {
                            let nx = min(x + 7, r.maxX)
                            path.addQuadCurve(to: CGPoint(x: nx, y: y), control: CGPoint(x: (x + nx) / 2, y: y + (up ? -2.2 : 2.2)))
                            x = nx; up.toggle()
                        }
                        ctx.stroke(path, with: .color(note.kind.accent.opacity(faint ? 0.35 : 0.9)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        if active { ctx.fill(Path(r), with: .color(note.kind.highlight.opacity(0.6))) }
                    }
                }
            }
        }
        .blendMode(.multiply)
    }
}

// MARK: - A. Sidenotes

struct SidenoteColumn: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        let positions = sidenotePositions(model)
        ZStack(alignment: .topLeading) {
            ForEach(model.notes) { note in
                if let y = positions[note.id] {
                    Group {
                        if model.isOpen(note) {
                            NoteCard(note: note, active: model.active == note.id) { model.delete(note.id) }
                                .frame(width: layout.cardWidth, alignment: .leading)
                        } else {
                            MarginTick(note: note)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.cardHeights[note.id] = $0 }
                    .onTapGesture { select(note) }
                    .offset(x: layout.pageWidth + layout.columnInset, y: y)
                    .transition(.opacity)
                }
            }
        }
    }

    private func select(_ note: Note) {
        withAnimation(.smooth(duration: 0.3)) {
            model.active = model.active == note.id ? nil : note.id
            if model.mode == .reading { model.peeked = model.peeked == note.id ? nil : note.id }
        }
    }
}

func sidenotePositions(_ model: ReaderModel) -> [UUID: CGFloat] {
    let items = model.notes.compactMap { n in model.geometry[n.id].map { (id: n.id, y: $0.first.minY - 8) } }
    return stack(items, heights: model.cardHeights)
}

/// Thin curves from the end of each anchored line to its card.
struct ConnectorLayer: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        let positions = sidenotePositions(model)
        Canvas { ctx, _ in
            for note in model.notes {
                guard let g = model.geometry[note.id], let y = positions[note.id] else { continue }
                let open = model.isOpen(note)
                let start = CGPoint(x: g.first.maxX + 4, y: g.first.midY)
                let end = CGPoint(x: layout.pageWidth + layout.columnInset - 2, y: y + (open ? 18 : 9))
                var path = Path()
                path.move(to: start)
                let dx = max(40, (end.x - start.x) * 0.5)
                path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                let active = model.active == note.id
                ctx.stroke(path, with: .color(note.kind.accent.opacity(active ? 0.8 : (open ? 0.4 : 0.18))),
                           style: StrokeStyle(lineWidth: active ? 1.3 : 0.9, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: start.x - 2, y: start.y - 2, width: 4, height: 4)),
                         with: .color(note.kind.accent.opacity(open ? 0.7 : 0.3)))
            }
        }
    }
}

private struct MarginTick: View {
    let note: Note
    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(note.kind.accent).frame(width: 14, height: 3)
            Text(note.kind.label).font(.caption2.weight(.medium)).foregroundStyle(note.kind.accent.opacity(0.8))
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

struct NoteCard: View {
    let note: Note
    var active = false
    var onDelete: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(note.kind.accent).frame(width: 6, height: 6)
                Text(note.kind.label).font(.caption.weight(.semibold)).foregroundStyle(note.kind.accent)
                Spacer(minLength: 0)
            }
            if let ink = note.ink {
                InkImage(drawing: ink, maxWidth: 220)
            } else if let q = note.question {
                Text(q).font(HandFont.font(size: 17)).foregroundStyle(Palette.graphite)
            }
            if note.pending {
                ThinkingDots(color: note.kind.accent)
            } else {
                Text(note.body)
                    .font(.system(size: 14, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.paper, in: .rect(cornerRadius: 12))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(note.kind.accent)
                .frame(width: 3)
        }
        .shadow(color: .black.opacity(active ? 0.14 : 0.06), radius: active ? 14 : 6, y: active ? 6 : 2)
        .scaleEffect(active ? 1.015 : 1, anchor: .leading)
        .contextMenu { Button("删除批注", systemImage: "trash", role: .destructive, action: onDelete) }
    }
}

struct ThinkingDots: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { t in
            let phase = t.date.timeIntervalSinceReferenceDate * 3
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(color.opacity(0.35 + 0.5 * max(0, sin(phase - Double(i) * 0.7))))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - B. Folded mark → card

struct FoldedMarksLayer: View {
    let model: ReaderModel
    let layout: ReaderLayout

    private let cardWidth: CGFloat = 300

    var body: some View {
        let open = model.notes.filter { model.isOpen($0) }
        let items = open.compactMap { n in model.geometry[n.id].map { (id: n.id, y: $0.union.maxY + 8) } }
        let positions = stack(items, heights: model.cardHeights)
        ZStack(alignment: .topLeading) {
            ForEach(model.notes) { note in
                if let g = model.geometry[note.id], let page = model.pageFrames[note.lines.first?.pageIndex ?? -1] {
                    let markX = markX(for: page)
                    // The fold: a short colored rule in the page margin, as tall as the passage.
                    Capsule()
                        .fill(note.kind.accent.opacity(model.active == note.id ? 1 : 0.75))
                        .frame(width: 3, height: max(10, g.union.height))
                        .padding(10)
                        .contentShape(.rect)
                        .onTapGesture { toggle(note) }
                        .offset(x: markX - 11.5, y: g.union.minY - 10)

                    if let y = positions[note.id] {
                        NoteCard(note: note, active: model.active == note.id) { model.delete(note.id) }
                            .frame(width: cardWidth)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.cardHeights[note.id] = $0 }
                            .onTapGesture { toggle(note) }
                            .offset(x: min(page.maxX, layout.pageWidth) - cardWidth - 18, y: y)
                            .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .topTrailing).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
            }
        }
    }

    /// Middle of the page's right margin (the sample PDF's text block leaves 54 pt of 432).
    private func markX(for page: CGRect) -> CGFloat {
        page.maxX - page.width * (27.0 / 432.0)
    }

    private func toggle(_ note: Note) {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            model.active = note.id
            model.toggleFold(note.id)
        }
    }
}

// MARK: - C. Handwritten replies

struct HandColumn: View {
    let model: ReaderModel
    let layout: ReaderLayout

    var body: some View {
        let items = model.notes.compactMap { n in model.geometry[n.id].map { (id: n.id, y: $0.first.minY - 6) } }
        let positions = stack(items, heights: model.cardHeights, gap: 18)
        ZStack(alignment: .topLeading) {
            ForEach(model.notes) { note in
                if let y = positions[note.id] {
                    HandReply(note: note, open: model.isOpen(note), active: model.active == note.id, width: layout.cardWidth)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.cardHeights[note.id] = $0 }
                        .onTapGesture {
                            withAnimation(.smooth(duration: 0.3)) {
                                model.active = note.id
                                if model.mode == .reading { model.peeked = model.peeked == note.id ? nil : note.id }
                            }
                        }
                        .contextMenu { Button("删除批注", systemImage: "trash", role: .destructive) { model.delete(note.id) } }
                        .offset(x: layout.pageWidth + layout.columnInset, y: y)
                }
            }
        }
    }
}

private struct HandReply: View {
    let note: Note
    let open: Bool
    let active: Bool
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ink = note.ink {
                InkImage(drawing: ink, maxWidth: width)
            } else if let q = note.question {
                Text(q)
                    .font(HandFont.font(size: 21))
                    .foregroundStyle(Palette.graphite)
                    .rotationEffect(.degrees(-1.2), anchor: .leading)
            }
            if open {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    LeafGlyph().frame(width: 11, height: 11).offset(y: 1)
                    if note.pending {
                        ThinkingDots(color: Palette.gold)
                    } else {
                        Text(note.body)
                            .font(.system(size: note.question == nil && note.ink == nil ? 13 : 14, design: .serif))
                            .italic(note.question == nil && note.ink == nil)
                            .lineSpacing(3.5)
                            .foregroundStyle(note.question == nil && note.ink == nil ? Palette.inkMuted : Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, note.question == nil && note.ink == nil ? 0 : 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                LeafGlyph().frame(width: 11, height: 11).opacity(0.8)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.vertical, 2)
        .background(alignment: .leading) {
            if active {
                Rectangle().fill(note.kind.accent.opacity(0.5)).frame(width: 2).offset(x: -10)
            }
        }
        .contentShape(.rect)
    }
}

struct LeafGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 24
            var p = Path()
            p.move(to: CGPoint(x: 12 * s, y: 21 * s))
            p.addCurve(to: CGPoint(x: 12 * s, y: 14 * s), control1: CGPoint(x: 12 * s, y: 18 * s), control2: CGPoint(x: 12.3 * s, y: 16 * s))
            p.addCurve(to: CGPoint(x: 4 * s, y: 7 * s), control1: CGPoint(x: 8.5 * s, y: 13.8 * s), control2: CGPoint(x: 4 * s, y: 11.6 * s))
            p.addCurve(to: CGPoint(x: 10 * s, y: 5 * s), control1: CGPoint(x: 6 * s, y: 7.4 * s), control2: CGPoint(x: 8 * s, y: 6 * s))
            p.addCurve(to: CGPoint(x: 12 * s, y: 7 * s), control1: CGPoint(x: 10.7 * s, y: 6.3 * s), control2: CGPoint(x: 11.3 * s, y: 6.8 * s))
            p.addCurve(to: CGPoint(x: 14 * s, y: 5 * s), control1: CGPoint(x: 12.7 * s, y: 6.8 * s), control2: CGPoint(x: 13.3 * s, y: 6.3 * s))
            p.addCurve(to: CGPoint(x: 20 * s, y: 7 * s), control1: CGPoint(x: 16 * s, y: 6 * s), control2: CGPoint(x: 18 * s, y: 7.4 * s))
            p.addCurve(to: CGPoint(x: 12 * s, y: 14 * s), control1: CGPoint(x: 20 * s, y: 11.6 * s), control2: CGPoint(x: 15.5 * s, y: 13.8 * s))
            ctx.fill(p, with: .color(Palette.gold))
        }
    }
}
