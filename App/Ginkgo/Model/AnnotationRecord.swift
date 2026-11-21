import Foundation
import GinkgoCore
import SwiftData

/// Stored form of an annotation. The anchor is kept as encoded data so new anchor kinds need no schema change.
@Model
final class AnnotationRecord {
    var id: UUID = UUID()
    var kindRaw: String = AnnotationKind.highlight.rawValue
    var colorRaw: String = HighlightColor.yellow.rawValue
    var anchorData: Data?
    var createdAt: Date = Date.now
    /// PencilKit drawing data for ink and handwritten questions.
    @Attribute(.externalStorage) var inkData: Data?
    /// Typed question, or the text recognized from a handwritten one.
    var question: String?
    var book: Book?

    init(kind: AnnotationKind, anchor: Anchor, color: HighlightColor = .yellow) {
        kindRaw = kind.rawValue
        colorRaw = color.rawValue
        anchorData = try? anchor.encoded()
    }

    var kind: AnnotationKind { AnnotationKind(rawValue: kindRaw) ?? .highlight }
    var color: HighlightColor { HighlightColor(rawValue: colorRaw) ?? .yellow }
    var anchor: Anchor? { anchorData.flatMap { try? Anchor.decoded(from: $0) } }
}
