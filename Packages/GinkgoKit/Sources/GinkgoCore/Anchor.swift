import CoreGraphics
import Foundation

/// Where an annotation is attached. One case per document format, so reflowable formats can be added later
/// without touching annotations, AI or export.
public enum Anchor: Codable, Hashable, Sendable {
    case pdf(PDFAnchor)

    /// The passage the annotation refers to, for display, prompts and re-anchoring.
    public var quote: String {
        switch self {
        case .pdf(let a): a.quote
        }
    }

    /// Sort key that follows reading order.
    public var readingOrder: ReadingOrder {
        switch self {
        case .pdf(let a): ReadingOrder(page: a.pageIndex, offset: a.range?.location ?? 0,
                                       top: -(a.rects.map(\.maxY).max() ?? 0))
        }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decoded(from data: Data) throws -> Anchor { try JSONDecoder().decode(Anchor.self, from: data) }
}

/// A passage on a fixed-layout PDF page.
public struct PDFAnchor: Codable, Hashable, Sendable {
    public var pageIndex: Int
    /// One rectangle per text line, in page space (PDF points, origin bottom-left).
    public var rects: [CGRect]
    /// Character range in the page's text, if the page has a text layer.
    public var range: NSRange?
    public var quote: String

    public init(pageIndex: Int, rects: [CGRect], range: NSRange? = nil, quote: String) {
        self.pageIndex = pageIndex
        self.rects = rects
        self.range = range
        self.quote = quote
    }

    /// The union of all line rectangles.
    public var bounds: CGRect { rects.reduce(CGRect.null) { $0.union($1) } }
}

// MARK: - How two passages relate

extension PDFAnchor {
    /// Both on one page with a known text range: the only case where passages can be compared.
    private func ranges(with other: PDFAnchor) -> (NSRange, NSRange)? {
        guard pageIndex == other.pageIndex, let a = range, let b = other.range, a.length > 0, b.length > 0 else { return nil }
        return (a, b)
    }

    /// The same characters on the same page.
    public func sameText(as other: PDFAnchor) -> Bool {
        guard let (a, b) = ranges(with: other) else { return false }
        return NSEqualRanges(a, b)
    }

    /// The other passage lies inside this one and is shorter: a word in its sentence.
    public func encloses(_ other: PDFAnchor) -> Bool {
        guard let (a, b) = ranges(with: other), !NSEqualRanges(a, b) else { return false }
        return a.location <= b.location && NSMaxRange(b) <= NSMaxRange(a)
    }

    /// The passages share at least one character.
    public func overlaps(_ other: PDFAnchor) -> Bool {
        guard let (a, b) = ranges(with: other) else { return false }
        return NSIntersectionRange(a, b).length > 0
    }

    /// The smallest range covering both, when they are on the same page.
    public func union(with other: PDFAnchor) -> NSRange? {
        guard let (a, b) = ranges(with: other) else { return nil }
        return NSUnionRange(a, b)
    }
}

public struct ReadingOrder: Comparable, Sendable {
    public var page: Int
    public var offset: Int
    public var top: CGFloat

    public static func < (l: ReadingOrder, r: ReadingOrder) -> Bool {
        (l.page, l.offset, l.top) < (r.page, r.offset, r.top)
    }
}
