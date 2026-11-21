import Foundation

/// What the reader asked for.
public enum AITask: Codable, Hashable, Sendable {
    case translate
    case explain
    case ask(String)
    /// A question written by hand in the margin, already recognized as text.
    case handwritten(String)

    /// Stored tag; the question itself is kept on the annotation.
    public var tag: String {
        switch self {
        case .translate: "translate"
        case .explain: "explain"
        case .ask: "ask"
        case .handwritten: "handwritten"
        }
    }

    public var label: String {
        switch self {
        case .translate: "翻译"
        case .explain: "解释"
        case .ask, .handwritten: "提问"
        }
    }
}

/// Everything around the passage that helps the model answer well.
public struct PassageContext: Sendable, Equatable {
    public var bookTitle: String
    public var passage: String
    /// Text just before and after the passage on the page.
    public var surrounding: String
    /// The reader's language, e.g. "简体中文" or "English".
    public var readerLanguage: String

    public init(bookTitle: String, passage: String, surrounding: String = "", readerLanguage: String) {
        self.bookTitle = bookTitle
        self.passage = passage
        self.surrounding = surrounding
        self.readerLanguage = readerLanguage
    }
}

/// Builds prompts that produce margin notes: short, plain, in the reader's language.
public enum PromptBuilder {
    public static func request(for task: AITask, context: PassageContext) -> AIRequest {
        let system = """
        你在读者的书页边上写批注，像一位博学、克制的老师。规则：
        - 用\(context.readerLanguage)回答（翻译任务除外，见下）。
        - 简短：通常一到三句话，最多一百二十字左右；不要开场白，不要复述问题。
        - 纯文本：不要 Markdown 标题、列表符号、加粗或代码块。
        - 只依据给出的原文和上下文；不确定就直说。
        """
        var parts: [String] = []
        if !context.bookTitle.isEmpty { parts.append("书名：《\(context.bookTitle)》") }
        if !context.surrounding.isEmpty { parts.append("上下文：\n\(context.surrounding)") }
        parts.append("划出的原文：\n\(context.passage)")

        switch task {
        case .translate:
            parts.append("""
            任务：把划出的原文翻译成\(context.readerLanguage)。如果原文已经是\(context.readerLanguage)，就翻译成英文。\
            只给译文；如有一个关键词值得点明，可在译文后用一句话说明。
            """)
        case .explain:
            parts.append("任务：解释这段话在说什么、为什么这么说；必要时点出难懂的词或背景。")
        case .ask(let question), .handwritten(let question):
            parts.append("读者的问题：\(question)\n任务：结合原文回答这个问题。")
        }
        return AIRequest(system: system, user: parts.joined(separator: "\n\n"))
    }
}
