import GinkgoCore
import PencilKit
import SwiftUI

/// What Apple Pencil does on the page. There is no writing mode: the Pencil uses the current tool while fingers
/// keep scrolling and selecting text. With no tool chosen the Pencil behaves like a finger.
enum PenTool: String, CaseIterable, Identifiable {
    /// Marker over the text; snaps to the lines it covers and becomes a highlight.
    case highlighter
    /// Straight or wavy rule under a line; snaps to the line.
    case underline
    /// Loop around a passage to select it and bring up translate, explain and ask.
    case lasso
    /// Free ink. Writing in the page margin becomes a handwritten question.
    case pen
    /// Erases ink, and plain marks it passes over.
    case eraser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .highlighter: "荧光笔"
        case .underline: "划线"
        case .lasso: "圈选"
        case .pen: "钢笔"
        case .eraser: "橡皮"
        }
    }

    var symbol: String {
        switch self {
        case .highlighter: "highlighter"
        case .underline: "underline"
        case .lasso: "lasso"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        }
    }

    /// Ink type each tool draws with, so strokes can be told apart when they are interpreted.
    var inkType: PKInkingTool.InkType? {
        switch self {
        case .highlighter: .marker
        case .underline: .monoline
        case .lasso: .pencil
        case .pen: .pen
        case .eraser: nil
        }
    }

    init?(inkType: PKInk.InkType) {
        switch inkType {
        case .marker: self = .highlighter
        case .monoline: self = .underline
        case .pencil: self = .lasso
        default: self = .pen
        }
    }

    /// Whether the tool picks one of the five highlight colours (the others use pen colours or none).
    var usesMarkColor: Bool { self == .highlighter || self == .underline }
}

/// Pen ink colours: a dark ink first, then the highlight inks.
enum InkColor: String, CaseIterable, Identifiable {
    case graphite, yellow, green, blue, pink, violet
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .graphite: Theme.penGraphite
        default: Theme.markLine(HighlightColor(rawValue: rawValue) ?? .blue)
        }
    }

    var name: String {
        switch self {
        case .graphite: "墨"
        default: (HighlightColor(rawValue: rawValue) ?? .blue).name
        }
    }
}

/// The tool choices, remembered between launches.
struct ToolSettings {
    private static let d = UserDefaults.standard

    static var tool: PenTool? {
        get {
            if let raw = d.string(forKey: "pen.tool") { return PenTool(rawValue: raw) }
            #if targetEnvironment(simulator)
            return nil  // the mouse is both finger and Pencil in the simulator; start with selecting text
            #else
            return .highlighter
            #endif
        }
        set { d.set(newValue?.rawValue ?? "none", forKey: "pen.tool") }
    }

    static var markColor: HighlightColor {
        get { d.string(forKey: "pen.markColor").flatMap(HighlightColor.init(rawValue:)) ?? .yellow }
        set { d.set(newValue.rawValue, forKey: "pen.markColor") }
    }

    static var inkColor: InkColor {
        get { d.string(forKey: "pen.inkColor").flatMap(InkColor.init(rawValue:)) ?? .graphite }
        set { d.set(newValue.rawValue, forKey: "pen.inkColor") }
    }

    static var underlineStyle: MarkStyle {
        get { d.string(forKey: "pen.underlineStyle").flatMap(MarkStyle.init(rawValue:)) ?? .underline }
        set { d.set(newValue.rawValue, forKey: "pen.underlineStyle") }
    }

    static var seenHint: Bool {
        get { d.bool(forKey: "pen.seenHint") }
        set { d.set(newValue, forKey: "pen.seenHint") }
    }
}

// MARK: - Tool tray

/// The always-visible tray at the top of the page: tools, then the current tool's options.
struct ToolTray: View {
    @Bindable var model: ReaderModel
    var vertical = false

    var body: some View {
        let content = Group {
            if !vertical {
                history
                Divider().frame(height: Theme.Tray.dividerLength)
            }
            tools
            if let tool = model.tool, tool != .lasso, tool != .eraser {
                Divider().frame(width: vertical ? Theme.Tray.dividerLength : nil, height: vertical ? nil : Theme.Tray.dividerLength)
                options(for: tool)
            }
        }
        Group {
            if vertical {
                VStack(spacing: Theme.Space.small) { content }
            } else {
                HStack(spacing: Theme.Space.small) { content }
            }
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.compact)
        .glassEffect(.regular.tint(Theme.glassTint).interactive(), in: .rect(cornerRadius: Theme.panelRadius))
    }

    private var history: some View {
        Group {
            Button { withAnimation(.smooth(duration: 0.2)) { model.undo() } } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(Theme.Tray.iconFont)
                    .frame(width: Theme.Tray.button, height: Theme.Tray.button)
                    .contentShape(Rectangle())
            }
            .disabled(!model.canUndo)
            .accessibilityLabel("撤销")
            Button { withAnimation(.smooth(duration: 0.2)) { model.redo() } } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(Theme.Tray.iconFont)
                    .frame(width: Theme.Tray.button, height: Theme.Tray.button)
                    .contentShape(Rectangle())
            }
            .disabled(!model.canRedo)
            .accessibilityLabel("重做")
        }
        .foregroundStyle(Theme.ink)
    }

    private var tools: some View {
        ForEach(PenTool.allCases) { tool in
            let on = model.tool == tool
            Button { withAnimation(.smooth(duration: 0.2)) { model.select(tool) } } label: {
                Image(systemName: tool.symbol)
                    .font(Theme.Tray.iconFont)
                    .foregroundStyle(on ? Theme.accent : Theme.ink)
                    .frame(width: Theme.Tray.button, height: Theme.Tray.button)
                    .background {
                        if on { RoundedRectangle(cornerRadius: Theme.Tray.selectionRadius).fill(Theme.accent.opacity(Theme.Tray.selectionOpacity)) }
                    }
                    .overlay(alignment: .bottom) {
                        if on, let tint = toolTint(tool) {
                            Capsule().fill(tint).frame(width: Theme.Tray.tintWidth, height: Theme.Tray.tintHeight).offset(y: -Theme.Space.tiny)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(tool.label)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityHint(on ? "再点一次放下工具，Pencil 恢复选字" : "")
        }
    }

    private func toolTint(_ tool: PenTool) -> Color? {
        switch tool {
        case .highlighter: model.markColor.fill
        case .underline: Theme.markLine(model.markColor)
        case .pen: model.inkColor.color
        default: nil
        }
    }

    @ViewBuilder private func options(for tool: PenTool) -> some View {
        if tool == .underline {
            ForEach([MarkStyle.underline, .squiggly], id: \.self) { style in
                let on = model.underlineStyle == style
                Button { model.underlineStyle = style } label: {
                    UnderlineGlyph(style: style)
                        .stroke(on ? Theme.accent : Theme.secondaryInk, lineWidth: Theme.Tray.glyphWidth)
                        .frame(width: Theme.Tray.glyph, height: Theme.Tray.glyphHeight)
                        .frame(width: Theme.Tray.button, height: Theme.Tray.button)
                        .background {
                            if on { RoundedRectangle(cornerRadius: Theme.Tray.selectionRadius).fill(Theme.accent.opacity(Theme.Tray.selectionOpacity)) }
                        }
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(style == .underline ? "直线" : "波浪线")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Divider().frame(width: vertical ? Theme.Tray.dividerLength : nil, height: vertical ? nil : Theme.Tray.dividerLength)
        }
        if tool.usesMarkColor {
            ForEach(HighlightColor.allCases, id: \.self) { c in
                swatch(fill: tool == .highlighter ? c.fill : Theme.markLine(c), selected: model.markColor == c, label: "\(c.name)色") {
                    model.markColor = c
                }
            }
        } else if tool == .pen {
            ForEach(InkColor.allCases) { c in
                swatch(fill: c.color, selected: model.inkColor == c, label: "\(c.name)色") { model.inkColor = c }
            }
        }
    }

    private func swatch(fill: Color, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(fill)
                .overlay { Circle().strokeBorder(Theme.ink.opacity(selected ? Theme.Swatch.selectedOpacity : 0), lineWidth: Theme.Swatch.selectedBorder) }
                .frame(width: Theme.swatchSize, height: Theme.swatchSize)
                .frame(width: Theme.swatchHitWidth, height: Theme.Tray.button)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A straight or wavy rule, for the underline style buttons and for drawing marks.
nonisolated struct UnderlineGlyph: Shape {
    var style: MarkStyle

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if style == .squiggly {
            p.addWave(from: CGPoint(x: rect.minX, y: rect.midY), to: CGPoint(x: rect.maxX, y: rect.midY),
                      amplitude: rect.height / 2, wavelength: max(rect.width / 3, 4))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        return p
    }
}

nonisolated extension Path {
    /// A smooth wave along a horizontal run.
    mutating func addWave(from a: CGPoint, to b: CGPoint, amplitude: CGFloat, wavelength: CGFloat) {
        move(to: a)
        let half = wavelength / 2
        var x = a.x
        var up = true
        while x < b.x {
            let next = min(x + half, b.x)
            addQuadCurve(to: CGPoint(x: next, y: a.y), control: CGPoint(x: (x + next) / 2, y: a.y + (up ? -amplitude : amplitude) * 2))
            x = next
            up.toggle()
        }
    }
}

/// First-run hint under the tray: how the Pencil and fingers share the page.
struct ToolHint: View {
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.rhythm) {
            Text("Apple Pencil 直接用上面的工具，手指照常滚动和选字。再点一次当前工具可以放下它。")
                .font(Theme.footnoteFont)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("知道了", action: dismiss).font(Theme.doneFont)
        }
        .padding(.horizontal, Theme.cardInset)
        .padding(.vertical, Theme.rhythm)
        .frame(maxWidth: Theme.menuWidth)
        .glassEffect(.regular.tint(Theme.glassTint).interactive(), in: .rect(cornerRadius: Theme.panelRadius))
    }
}

/// Shown at the Pencil tip on a squeeze (Apple Pencil Pro): the same tools, in a column.
struct SqueezePalette: View {
    let model: ReaderModel
    let point: CGPoint
    let bounds: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { withAnimation(.smooth(duration: 0.2)) { model.paletteAt = nil } }
            ToolTray(model: model, vertical: true)
                .fixedSize()
                .shadow(color: Theme.panelShadowColor, radius: Theme.Tray.paletteShadow, y: 4)
                .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
                .offset(x: min(max(point.x + Theme.Tray.paletteOffset, Theme.rhythm), bounds.width - size.width - Theme.rhythm),
                        y: min(max(point.y - size.height / 2, Theme.rhythm), bounds.height - size.height - Theme.rhythm))
        }
        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
    }

    @State private var size: CGSize = .zero
}
