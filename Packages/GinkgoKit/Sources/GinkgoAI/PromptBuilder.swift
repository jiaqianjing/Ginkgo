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
    /// `learning`: the passage is in a language the reader is learning, so key expressions follow separately and
    /// the translation itself stays bare.
    public static func request(for task: AITask, context: PassageContext, learning: Bool = false) -> AIRequest {
        let system = """
        你在读者的书页边上写批注，像一位博学、克制的老师。规则：
        - 用\(context.readerLanguage)回答（翻译任务除外，见下）。
        - 简短：通常一到三句话，最多一百二十字左右；不要开场白，不要复述问题。
        - 纯文本：不要 Markdown 标题、列表符号、加粗或代码块。
        - 只依据给出的原文和上下文；不确定就直说。
        """
        var parts = passageParts(context)

        switch task {
        case .translate where learning:
            parts.append("""
            任务：把划出的原文翻译成通顺、地道的\(context.readerLanguage)，忠实于原意和语气。\
            原文可能从句子中间开始或结束，只翻译划出的部分。只给译文，不加说明。
            """)
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

// MARK: - Learning a language

extension PromptBuilder {
    static func passageParts(_ context: PassageContext) -> [String] {
        var parts: [String] = []
        if !context.bookTitle.isEmpty { parts.append("书名：《\(context.bookTitle)》") }
        if !context.surrounding.isEmpty { parts.append("上下文（只用来消除歧义，不要翻译它）：\n\(context.surrounding)") }
        parts.append("划出的原文：\n\(context.passage)")
        return parts
    }

    /// A word or short phrase: a learner's dictionary card that reads the word in its context. Answers in JSON.
    public static func wordCard(context: PassageContext, level: LearnerLevel) -> AIRequest {
        let lang = context.readerLanguage
        let system = """
        你是一本懂上下文的学习词典。读者是母语为\(lang)的\(level.promptDescription)，正在读外语书，划出了一个词或短语。

        只返回一个 JSON 对象，不要任何其他文字：
        {
          "term": "划出的词或短语，照原样",
          "lemma": "词典形式，比如 ran 的原形是 run；已经是原形就和 term 相同",
          "phonetic": "读音：英语用 IPA，如 /rʌn/；中文用带声调的拼音；日语用平假名；其他语言用该语言学习者常用的标注；没有就空字符串",
          "context_meaning": "在这段上下文里的确切意思，用\(lang)，越短越好",
          "senses": [{"pos": "词性缩写，如 n. / v. / adj.", "meaning": "常见义项，用\(lang)"}],
          "example": {"source": "上下文里含这个词的那句原文；没有上下文就给一句简短自然的例句", "target": "这句的\(lang)译文"},
          "note": "一条对这个水平的读者真正有用的提示（搭配、易混词、语体），用\(lang)；没有就空字符串"
        }
        规则：senses 最多 4 条，最常见的在前；context_meaning 必须贴合上下文，不是只给最常见的义项。
        """
        return AIRequest(system: system, user: passageParts(context).joined(separator: "\n\n"), maxTokens: 1500)
    }

    /// The expressions in a translated sentence worth remembering, and whether a grammar walk-through would help.
    public static func keyItems(context: PassageContext, translation: String, level: LearnerLevel) -> AIRequest {
        let lang = context.readerLanguage
        let system = """
        你是一位语言老师。读者是母语为\(lang)的\(level.promptDescription)，正在读外语书。\
        从划出的原文里挑出对这位读者真正值得记住的表达。

        挑选规则：
        - 优先挑多词单位：短语动词、固定搭配、习语、句型、地道的口语说法。
        - 单个词只在超出读者水平、或在这里用的不是常见意思时才挑。
        - 读者肯定认识的词、人名、数字和填充词不要挑。一个都不挑也可以。
        - 最多 5 个，按有用程度排序。照原文的形式写，动词和短语动词可以写原形。
        - "meaning" 必须贴合这句话，用\(lang)写；"note" 可选，很短（用法、语体、常见错误），不是真有帮助就留空。

        然后判断语法分析是否真的有帮助。只有下面两种情况才把 "analysis_worthy" 设为 true：
        (a) 结构确实难：长句套从句、倒装、省略、前置、分词或独立结构、修饰关系有歧义、语序特殊；
        (b) 日常或口语的句子，自然的意思、语气或言外之意和字面不同。
        简单清楚的句子设为 false。"analysis_hint" 用\(lang)写一个短语，说明值得看什么（比如"倒装 + 非限定性定语从句"），false 时留空。

        只返回 JSON，不要其他文字：
        {"items":[{"text":"...","kind":"word|phrase|phrasal_verb|collocation|idiom|pattern|slang","phonetic":"英语给 IPA，其他留空","meaning":"...","note":"..."}],"analysis_worthy":true,"analysis_hint":"..."}
        """
        var parts = passageParts(context)
        parts.append("译文：\n\(translation)")
        return AIRequest(system: system, user: parts.joined(separator: "\n\n"), maxTokens: 1500)
    }

    /// A grammar walk-through of a hard sentence, asked for by the reader. Answers in JSON.
    public static func analysis(context: PassageContext, translation: String, hint: String?, level: LearnerLevel) -> AIRequest {
        let lang = context.readerLanguage
        let system = """
        你是一位优秀的语言老师。读者是母语为\(lang)的\(level.promptDescription)。\
        讲解划出的原文：抓住真正难或有意思的地方，不要机械地给每个词贴标签。所有讲解用\(lang)。

        先选类型：
        - "structure"：结构复杂的句子。给出主干（用原文的词写出核心的主谓宾），再把句子分成 3 到 7 个有意义的块，说明每块的语法角色和作用。
        - "expression"：日常或口语的句子。讲语气、言外之意、什么场合这么说，在 "usage" 里给两三个自然的替代说法；chunks 可以为空。

        只返回 JSON，不要其他文字：
        {
          "kind": "structure|expression",
          "skeleton": "用原文的词写出句子主干；expression 类型没必要就留空",
          "skeleton_translation": "主干的译文",
          "chunks": [{"text": "原文片段", "role": "如 主语 / 谓语 / 宾语从句 / 非谓语作状语 / 插入语", "explain": "它做什么、为什么这么写"}],
          "insights": ["一到三条要点：真正的难点、可以照着用的句型、要避开的坑"],
          "usage": "expression 类型写语气、场合和替代说法，否则留空",
          "paraphrase": "用更简单的同一种语言把这句话重写一遍"
        }
        """
        var parts = passageParts(context)
        parts.append("译文：\n\(translation)")
        if let hint, !hint.isEmpty { parts.append("重点关注：\(hint)") }
        return AIRequest(system: system, user: parts.joined(separator: "\n\n"), maxTokens: 2500)
    }
}

// MARK: - Follow-up questions

/// What the card already shows, handed to the model with each follow-up.
public struct FollowUpMaterial: Sendable {
    public var task: String
    public var question: String?
    public var answer: String
    public var keyItems: [KeyItem]
    public var analysis: String?

    public init(task: String, question: String? = nil, answer: String, keyItems: [KeyItem] = [], analysis: String? = nil) {
        self.task = task
        self.question = question
        self.answer = answer
        self.keyItems = keyItems
        self.analysis = analysis
    }
}

extension PromptBuilder {
    /// Requests are single-turn, so earlier rounds are packed into the message.
    public static func followUp(context: PassageContext, material: FollowUpMaterial, history: [FollowUp],
                                question: String, level: LearnerLevel?) -> AIRequest {
        var system = """
        你在读者的书页边上写批注，像一位博学、克制的老师。读者针对一段原文已经得到了一条批注，现在接着追问。规则：
        - 用\(context.readerLanguage)回答，除非读者明确要求别的语言。引用的原文词句保持原样。
        - 紧扣原文和上下文；"这里""这个""它"指划出的原文，除非之前的对话另有所指。
        - 直接回答，不要开场白，不要重复之前说过的内容。通常两到五句话；需要举例时每个例子附简短译文。
        - 纯文本：不要 Markdown 标题、加粗、表格或代码块；可以用"- "开头的短行。
        """
        if let level { system += "\n- 读者学这门外语的水平：\(level.promptDescription)，讲解深浅照这个来。" }

        var parts = passageParts(context)
        var first = "最初的批注（\(material.task)）"
        if let q = material.question, !q.isEmpty { first += "，读者问：\(q)" }
        parts.append("\(first)\n\(material.answer)")
        if !material.keyItems.isEmpty {
            let lines = material.keyItems.map { item in
                "- \(item.text)" + (item.meaning.map { "：\($0)" } ?? "") + (item.note.flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? "")
            }
            parts.append("重点表达：\n" + lines.joined(separator: "\n"))
        }
        if let analysis = material.analysis, !analysis.isEmpty { parts.append("语法分析：\n\(analysis)") }
        let earlier = history.filter { !$0.answer.isEmpty }
        if !earlier.isEmpty {
            parts.append("之前的追问：\n" + earlier.map { "读者：\($0.question)\n你：\($0.answer)" }.joined(separator: "\n\n"))
        }
        parts.append("读者现在追问：\(question)")
        return AIRequest(system: system, user: parts.joined(separator: "\n\n"))
    }
}
