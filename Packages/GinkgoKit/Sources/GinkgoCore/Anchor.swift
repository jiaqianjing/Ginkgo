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

public struct ReadingOrder: Comparable, Sendable {
    public var page: Int
    public var offset: Int
    public var top: CGFloat

    public static func < (l: ReadingOrder, r: ReadingOrder) -> Bool {
        (l.page, l.offset, l.top) < (r.page, r.offset, r.top)
    }
}
