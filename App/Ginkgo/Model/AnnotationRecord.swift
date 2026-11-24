import Foundation
import GinkgoAI
import GinkgoCore
import SwiftData

/// Stored form of an annotation. The anchor is kept as encoded data so new anchor kinds need no schema change.
@Model
final class AnnotationRecord {
    var id: UUID = UUID()
    var kindRaw: String = AnnotationKind.highlight.rawValue
    var colorRaw: String = HighlightColor.yellow.rawValue
    /// `MarkStyle` raw value; nil means a highlight (records from before underlines existed).
    var styleRaw: String?
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
    /// Follow-up questions and answers after the first reply (`[FollowUp]` as JSON).
    var threadData: Data?
    /// Word card, key expressions and grammar analysis for a translation (`StudyNote` as JSON).
    var studyData: Data?
    var book: Book?

    init(kind: AnnotationKind, anchor: Anchor, color: HighlightColor = .yellow) {
        kindRaw = kind.rawValue
        colorRaw = color.rawValue
        anchorData = try? anchor.encoded()
    }

    var kind: AnnotationKind { AnnotationKind(rawValue: kindRaw) ?? .highlight }
    var color: HighlightColor { HighlightColor(rawValue: colorRaw) ?? .yellow }
    var style: MarkStyle { styleRaw.flatMap(MarkStyle.init(rawValue:)) ?? .highlight }
    var anchor: Anchor? { anchorData.flatMap { try? Anchor.decoded(from: $0) } }

    var replyState: ReplyState {
        get { replyStateRaw.flatMap(ReplyState.init(rawValue:)) ?? .none }
        set { replyStateRaw = newValue.rawValue }
    }

    var thread: [FollowUp] {
        get { StudyJSON.load([FollowUp].self, from: threadData) ?? [] }
        set { threadData = newValue.isEmpty ? nil : StudyJSON.encode(newValue) }
    }

    var study: StudyNote {
        get { StudyJSON.load(StudyNote.self, from: studyData) ?? StudyNote() }
        set { studyData = newValue.isEmpty ? nil : StudyJSON.encode(newValue) }
    }

    /// Has a margin note (an AI task or a handwritten question), not just a mark on the text or free ink.
    var hasNote: Bool { kind != .ink && (taskRaw != nil || question != nil) }

    var taskLabel: String {
        switch taskRaw {
        case "translate": studyData != nil && study.word != nil ? "查词" : "翻译"
        case "explain": "解释"
        default: "提问"
        }
    }
}

enum ReplyState: String {
    case none, pending, streaming, done, failed
}
