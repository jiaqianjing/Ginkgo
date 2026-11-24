import CoreGraphics

/// Decides what a finished Pencil stroke means. Pure geometry: input is the stroke's points and the text lines
/// of the page, all in one coordinate space with y growing downwards (the overlay canvas's space).
public enum StrokeIntent: Equatable, Sendable {
    /// A roughly straight horizontal stroke along a text line: highlight from `start` to `end` on that line.
    case underline(line: CGRect, start: CGFloat, end: CGFloat)
    /// A closed loop around some text: select what it encloses.
    case circle(bounds: CGRect)
    /// Writing in the empty margin beside a text line: a handwritten question for that line.
    case marginNote(nearLine: CGRect)
    /// Anything else stays as ink.
    case ink
}

public enum StrokeClassifier {
    public static func classify(points: [CGPoint], textLines: [CGRect], textColumn: CGRect) -> StrokeIntent {
        guard points.count >= 2 else { return .ink }
        let bounds = boundingBox(points)

        // Margin first: writing entirely outside the text column, next to some line.
        if !textColumn.isNull, bounds.minX > textColumn.maxX + 4 || bounds.maxX < textColumn.minX - 4 {
            if let line = nearestLine(toY: bounds.midY, in: textLines, within: 80) { return .marginNote(nearLine: line) }
            return .ink
        }

        // Underline: wide, flat, and roughly monotonic in x, lying on or just below a text line.
        let flatness = bounds.height / max(bounds.width, 1)
        if bounds.width >= 24, flatness < 0.22, isMostlyMonotonicInX(points),
           let line = textLines.first(where: { $0.minY - 6 <= bounds.midY && bounds.midY <= $0.maxY + 10 &&
                                               $0.maxX > bounds.minX && $0.minX < bounds.maxX }) {
            return .underline(line: line, start: max(bounds.minX, line.minX), end: min(bounds.maxX, line.maxX))
        }

        // Circle: the stroke comes back near where it started and encloses some text.
        let gap = hypot(points.first!.x - points.last!.x, points.first!.y - points.last!.y)
        let size = max(bounds.width, bounds.height)
        // Loops around a phrase are flat ellipses (perimeter about 2.1 × width), so the length test is loose; the
        // height test rules out a line drawn there and back.
        if size >= 30, min(bounds.width, bounds.height) >= 10, gap < size * 0.35, pathLength(points) > size * 1.8,
           textLines.contains(where: { $0.intersects(bounds) }) {
            return .circle(bounds: bounds)
        }
        return .ink
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// True when the stroke mostly moves in one horizontal direction (a scribble back and forth is not an underline).
    static func isMostlyMonotonicInX(_ points: [CGPoint]) -> Bool {
        var forward: CGFloat = 0, backward: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x
            if dx > 0 { forward += dx } else { backward -= dx }
        }
        return min(forward, backward) < max(forward, backward) * 0.15
    }

    static func nearestLine(toY y: CGFloat, in lines: [CGRect], within limit: CGFloat) -> CGRect? {
        lines.min { abs($0.midY - y) < abs($1.midY - y) }.flatMap { abs($0.midY - y) <= limit ? $0 : nil }
    }
}
