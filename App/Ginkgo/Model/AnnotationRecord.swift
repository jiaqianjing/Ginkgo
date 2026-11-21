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
    /// The AI task behind this note (`AITask.tag`), nil for a plain highlight or ink.
    var taskRaw: String?
    var replyText: String?
    var replyStateRaw: String?
    var replyError: String?
    /// Which model wrote the reply, e.g. "OpenAI · gpt-5.5".
    var replyModel: String?
    var book: Book?

    init(kind: AnnotationKind, anchor: Anchor, color: HighlightColor = .yellow) {
        kindRaw = kind.rawValue
        colorRaw = color.rawValue
        anchorData = try? anchor.encoded()
    }

    var kind: AnnotationKind { AnnotationKind(rawValue: kindRaw) ?? .highlight }
    var color: HighlightColor { HighlightColor(rawValue: colorRaw) ?? .yellow }
    var anchor: Anchor? { anchorData.flatMap { try? Anchor.decoded(from: $0) } }

    var replyState: ReplyState {
        get { replyStateRaw.flatMap(ReplyState.init(rawValue:)) ?? .none }
        set { replyStateRaw = newValue.rawValue }
    }

    /// Has a margin note (an AI task or a handwritten question), not just a mark on the text.
    var hasNote: Bool { taskRaw != nil || question != nil || inkData != nil }

    var taskLabel: String {
        switch taskRaw {
        case "translate": "翻译"
        case "explain": "解释"
        default: "提问"
        }
    }
}

enum ReplyState: String {
    case none, pending, streaming, done, failed
}
