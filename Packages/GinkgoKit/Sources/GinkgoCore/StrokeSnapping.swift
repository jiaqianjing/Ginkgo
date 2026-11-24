import CoreGraphics

/// Snaps a stroke drawn with an explicit tool to the text it was meant for. Same coordinate space as
/// `StrokeClassifier`: canvas points, y growing downwards.
public enum StrokeSnapping {
    /// A run of text from `start` to `end`, where each point lies on the text line it belongs to.
    public struct Span: Equatable, Sendable {
        public var start: CGPoint
        public var end: CGPoint
    }

    /// Highlighter: the text the stroke passes over, from its leftmost point on the first line it touches to its
    /// rightmost point on the last. Nil when the stroke misses the text.
    public static func highlight(points: [CGPoint], textLines: [CGRect]) -> Span? {
        guard let box = box(points) else { return nil }
        let band = box.insetBy(dx: 0, dy: -2)
        let hit = textLines.filter { $0.intersects(band) && overlap($0, box) > min(4, box.width / 2) }
            .sorted { $0.minY < $1.minY }
        guard let first = hit.first, let last = hit.last else { return nil }
        let x0 = max(first.minX, hit.count == 1 ? box.minX : startX(points, on: first) ?? box.minX)
        let x1 = min(last.maxX, hit.count == 1 ? box.maxX : endX(points, on: last) ?? box.maxX)
        guard hit.count > 1 || x1 - x0 >= 4 else { return nil }
        return Span(start: CGPoint(x: x0 + 1, y: first.midY), end: CGPoint(x: x1 - 1, y: last.midY))
    }

    /// Underline or wave: the line just above (or under) the stroke, between the stroke's ends.
    public static func underline(points: [CGPoint], textLines: [CGRect]) -> Span? {
        guard let box = box(points), box.width >= 12 else { return nil }
        let candidates = textLines.filter { overlap($0, box) > 4 && box.midY >= $0.minY && box.midY <= $0.maxY + 14 }
        guard let line = candidates.min(by: { abs($0.maxY - box.midY) < abs($1.maxY - box.midY) }) else { return nil }
        let x0 = max(line.minX, box.minX), x1 = min(line.maxX, box.maxX)
        guard x1 - x0 >= 4 else { return nil }
        return Span(start: CGPoint(x: x0 + 1, y: line.midY), end: CGPoint(x: x1 - 1, y: line.midY))
    }

    /// Lasso: the area the loop encloses, if it covers any text.
    public static func lasso(points: [CGPoint], textLines: [CGRect]) -> CGRect? {
        guard let box = box(points), box.width >= 8, box.height >= 6,
              textLines.contains(where: { $0.intersects(box) }) else { return nil }
        return box
    }

    static func box(_ points: [CGPoint]) -> CGRect? {
        guard points.count >= 2 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func overlap(_ line: CGRect, _ box: CGRect) -> CGFloat {
        min(line.maxX, box.maxX) - max(line.minX, box.minX)
    }

    private static func startX(_ points: [CGPoint], on line: CGRect) -> CGFloat? {
        points.filter { $0.y >= line.minY - 2 && $0.y <= line.maxY + 2 }.map(\.x).min()
    }

    private static func endX(_ points: [CGPoint], on line: CGRect) -> CGFloat? {
        points.filter { $0.y >= line.minY - 2 && $0.y <= line.maxY + 2 }.map(\.x).max()
    }
}
