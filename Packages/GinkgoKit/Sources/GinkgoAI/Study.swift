import Foundation

// MARK: - Follow-up thread

/// One follow-up question on a note and its answer. Stored in order on the annotation.
public struct FollowUp: Codable, Hashable, Sendable {
    public var question: String
    /// Grows as the answer streams in; empty while waiting.
    public var answer: String
    /// Set when the answer failed; the card offers a retry.
    public var error: String?

    public init(question: String, answer: String = "", error: String? = nil) {
        self.question = question
        self.answer = answer
        self.error = error
    }
}

// MARK: - Learner

/// How well the reader knows the language they are reading. Decides what a translation points out.
public enum LearnerLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    case beginner, intermediate, advanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .beginner: String(localized: "入门", bundle: L10n.bundle)
        case .intermediate: String(localized: "中级", bundle: L10n.bundle)
        case .advanced: String(localized: "高级", bundle: L10n.bundle)
        }
    }

    public var detail: String {
        switch self {
        case .beginner: String(localized: "常用词还在积累，长句容易卡住", bundle: L10n.bundle)
        case .intermediate: String(localized: "能读懂大意，生词和复杂句式需要帮忙", bundle: L10n.bundle)
        case .advanced: String(localized: "读原版书没问题，只想留意地道表达", bundle: L10n.bundle)
        }
    }

    var promptDescription: String {
        switch self {
        case .beginner: "入门水平的学习者（约 CEFR A2）"
        case .intermediate: "中级水平的学习者（约 CEFR B1–B2）"
        case .advanced: "高级水平的学习者（约 CEFR C1）"
        }
    }
}

/// A word or short phrase gets a dictionary card; anything longer is a sentence to translate.
public enum PassageShape {
    public static func isLookup(_ passage: String) -> Bool {
        let text = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { return false }
        // Sentence punctuation inside the selection means it spans a clause.
        let body = text.dropLast()
        if body.contains(where: { ".!?;。！？；".contains($0) }) { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count > 1 { return words.count <= 4 }
        // One run with no spaces: a word, or a short CJK phrase.
        let cjk = text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        return cjk ? text.count <= 6 : true
    }
}

// MARK: - Study cards

/// Dictionary card for a selected word, read in its context.
public struct WordCard: Codable, Hashable, Sendable {
    public struct Sense: Codable, Hashable, Sendable {
        public var pos: String?
        public var meaning: String?
        public init(pos: String? = nil, meaning: String? = nil) { self.pos = pos; self.meaning = meaning }
    }
    public struct Example: Codable, Hashable, Sendable {
        public var source: String?
        public var target: String?
        public init(source: String? = nil, target: String? = nil) { self.source = source; self.target = target }
    }

    public var term: String?
    public var lemma: String?
    public var phonetic: String?
    public var contextMeaning: String?
    public var senses: [Sense]?
    public var example: Example?
    public var note: String?

    public init() {}

    /// Plain text for copying, exporting and the follow-up prompt.
    public var summary: String {
        var lines: [String] = []
        var head = term ?? ""
        if let phonetic, !phonetic.isEmpty { head += " \(phonetic)" }
        if let lemma, !lemma.isEmpty, lemma != term { head += String(localized: "（原形 \(lemma)）", bundle: L10n.bundle) }
        if !head.isEmpty { lines.append(head) }
        if let contextMeaning, !contextMeaning.isEmpty { lines.append(String(localized: "这里的意思：\(contextMeaning)", bundle: L10n.bundle)) }
        for sense in senses ?? [] {
            guard let meaning = sense.meaning, !meaning.isEmpty else { continue }
            lines.append([sense.pos, meaning].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " "))
        }
        if let source = example?.source, !source.isEmpty {
            lines.append(String(localized: "例句：\(source)", bundle: L10n.bundle) + (example?.target.map { "（\($0)）" } ?? ""))
        }
        if let note, !note.isEmpty { lines.append(String(localized: "提示：\(note)", bundle: L10n.bundle)) }
        return lines.joined(separator: "\n")
    }
}

/// An expression in a sentence worth remembering.
public struct KeyItem: Codable, Hashable, Sendable {
    public var text: String
    public var kind: String?
    public var phonetic: String?
    public var meaning: String?
    public var note: String?

    public init(text: String, kind: String? = nil, phonetic: String? = nil, meaning: String? = nil, note: String? = nil) {
        self.text = text
        self.kind = kind
        self.phonetic = phonetic
        self.meaning = meaning
        self.note = note
    }

    /// Short label for the kind, e.g. "搭配".
    public var kindLabel: String? {
        switch kind {
        case "phrase": String(localized: "短语", bundle: L10n.bundle)
        case "phrasal_verb": String(localized: "短语动词", bundle: L10n.bundle)
        case "collocation": String(localized: "搭配", bundle: L10n.bundle)
        case "idiom": String(localized: "习语", bundle: L10n.bundle)
        case "pattern": String(localized: "句型", bundle: L10n.bundle)
        case "slang": String(localized: "口语", bundle: L10n.bundle)
        case "word": String(localized: "词", bundle: L10n.bundle)
        default: nil
        }
    }
}

public struct KeyItems: Codable, Hashable, Sendable {
    public var items: [KeyItem]
    /// The model thinks a grammar walk-through would really help with this sentence.
    public var analysisWorthy: Bool?
    public var analysisHint: String?

    public init(items: [KeyItem], analysisWorthy: Bool? = nil, analysisHint: String? = nil) {
        self.items = items
        self.analysisWorthy = analysisWorthy
        self.analysisHint = analysisHint
    }
}

/// A teacher's walk through a hard sentence.
public struct SentenceAnalysis: Codable, Hashable, Sendable {
    public struct Chunk: Codable, Hashable, Sendable {
        public var text: String?
        public var role: String?
        public var explain: String?
    }

    public var kind: String?
    public var skeleton: String?
    public var skeletonTranslation: String?
    public var chunks: [Chunk]?
    public var insights: [String]?
    public var usage: String?
    public var paraphrase: String?

    public var summary: String {
        var lines: [String] = []
        if let skeleton, !skeleton.isEmpty {
            lines.append(String(localized: "主干：\(skeleton)", bundle: L10n.bundle) + (skeletonTranslation.map { "（\($0)）" } ?? ""))
        }
        for chunk in chunks ?? [] {
            guard let text = chunk.text, !text.isEmpty else { continue }
            lines.append("- \(text)｜\(chunk.role ?? "")：\(chunk.explain ?? "")")
        }
        for insight in insights ?? [] where !insight.isEmpty { lines.append(String(localized: "要点：\(insight)", bundle: L10n.bundle)) }
        if let usage, !usage.isEmpty { lines.append(String(localized: "用法：\(usage)", bundle: L10n.bundle)) }
        if let paraphrase, !paraphrase.isEmpty { lines.append(String(localized: "换个说法：\(paraphrase)", bundle: L10n.bundle)) }
        return lines.joined(separator: "\n")
    }
}

/// What a learner-oriented translation adds to a note. Stored on the annotation as JSON.
public struct StudyNote: Codable, Hashable, Sendable {
    public var word: WordCard?
    public var keyItems: KeyItems?
    public var keyItemsError: String?
    public var analysis: SentenceAnalysis?
    public var analysisError: String?

    public init(word: WordCard? = nil, keyItems: KeyItems? = nil) {
        self.word = word
        self.keyItems = keyItems
    }

    public var isEmpty: Bool { self == StudyNote() }
}

// MARK: - JSON answers

public enum StudyJSON {
    /// Snake-case from the model and camel-case from our own storage both decode.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Decodes the JSON object in a model's answer, ignoring code fences or words around it.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { throw AIError.badFormat }
        do { return try decoder.decode(type, from: data) } catch { throw AIError.badFormat }
    }

    public static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }

    public static func load<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        data.flatMap { try? decoder.decode(type, from: $0) }
    }
}

extension AIClient {
    /// The whole answer at once, for JSON replies that only make sense when complete.
    public func collect(_ request: AIRequest) async throws -> String {
        var text = ""
        for try await chunk in stream(request) { text += chunk }
        return text
    }
}
