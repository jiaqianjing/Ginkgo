import Foundation
import Testing
@testable import GinkgoAI

@Suite struct SSEParserTests {
    @Test func joinsFieldsUntilABlankLine() {
        var p = SSEParser()
        #expect(p.feed("event: content_block_delta") == nil)
        #expect(p.feed("data: {\"a\":1}") == nil)
        #expect(p.feed("") == SSEEvent(event: "content_block_delta", data: "{\"a\":1}"))
        #expect(p.feed(": keep-alive") == nil)
        #expect(p.feed("") == nil)
    }
}

@Suite struct ClientParsingTests {
    let request = AIRequest(system: "sys", user: "hello", maxTokens: 300)

    @Test func openAIRequestAndDeltas() throws {
        let c = OpenAIClient(apiKey: "k", model: "gpt-5.5", session: .shared)
        let r = try c.makeURLRequest(request)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try #require(jsonObject(String(decoding: r.httpBody!, as: UTF8.self)))
        #expect(body["instructions"] as? String == "sys")
        #expect(body["stream"] as? Bool == true)
        #expect((body["reasoning"] as? [String: String])?["effort"] == "low")
        #expect(try c.text(from: .init(data: #"{"type":"response.output_text.delta","delta":"Hi"}"#)) == "Hi")
        #expect(try c.text(from: .init(data: #"{"type":"response.created"}"#)) == nil)
        #expect(throws: AIError.refused) { try c.text(from: .init(data: #"{"type":"response.refusal.delta","delta":"no"}"#)) }
    }

    @Test func anthropicRequestAndDeltas() throws {
        let c = AnthropicClient(apiKey: "k", model: "claude-opus-5-5", session: .shared)
        let r = try c.makeURLRequest(request)
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = try #require(jsonObject(String(decoding: r.httpBody!, as: UTF8.self)))
        #expect(body["system"] as? String == "sys")
        #expect(body["max_tokens"] as? Int == 300)
        let delta = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}"#
        #expect(try c.text(from: .init(event: "content_block_delta", data: delta)) == "你好")
        let stop = #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#
        #expect(throws: AIError.refused) { try c.text(from: .init(data: stop)) }
    }

    @Test func geminiRequestAndDeltas() throws {
        let c = GeminiClient(apiKey: "k", model: "models/gemini-3.5-flash", session: .shared)
        let r = try c.makeURLRequest(request)
        #expect(r.url?.absoluteString.contains("models/gemini-3.5-flash:streamGenerateContent?alt=sse") == true)
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        let chunk = #"{"candidates":[{"content":{"parts":[{"text":"思","thought":true},{"text":"答"}]}}]}"#
        #expect(try c.text(from: .init(data: chunk)) == "答")
    }

    @Test func missingKeyFailsBeforeAnyRequest() {
        #expect(throws: AIError.missingKey) { try OpenAIClient(apiKey: "", model: "m", session: .shared).makeURLRequest(request) }
    }
}

@Suite struct PromptBuilderTests {
    let context = PassageContext(bookTitle: "A Living Fossil", passage: "It hedges against catastrophe.",
                                 surrounding: "What makes the ginkgo remarkable…", readerLanguage: "简体中文")

    @Test func translateAsksForTheReadersLanguage() {
        let r = PromptBuilder.request(for: .translate, context: context)
        #expect(r.user.contains("翻译成简体中文"))
        #expect(r.user.contains("It hedges against catastrophe."))
        #expect(r.system.contains("简短"))
    }

    @Test func questionsCarryTheQuestion() {
        let r = PromptBuilder.request(for: .ask("为什么说是对冲？"), context: context)
        #expect(r.user.contains("为什么说是对冲？"))
        #expect(r.user.contains("《A Living Fossil》"))
    }
}

/// Calls the real services. Runs only with GINKGO_LIVE_AI=1 and the matching *_API_KEY variables set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GINKGO_LIVE_AI"] == "1"))
struct LiveProviderTests {
    func answer(_ kind: AIProviderKind, key: String) async throws -> String {
        let context = PassageContext(bookTitle: "A Living Fossil", passage: "It hedges against catastrophe by doing many modest things well.",
                                     readerLanguage: "简体中文")
        var text = ""
        for try await chunk in kind.client(apiKey: key, model: "").stream(PromptBuilder.request(for: .translate, context: context)) {
            text += chunk
        }
        print("[\(kind.rawValue)] \(text)")
        return text
    }

    @Test(arguments: [(AIProviderKind.openAI, "OPENAI_API_KEY"), (.gemini, "GEMINI_API_KEY"), (.anthropic, "ANTHROPIC_API_KEY")])
    func streamsATranslation(kind: AIProviderKind, env: String) async throws {
        guard let key = ProcessInfo.processInfo.environment[env], !key.isEmpty else { return }
        #expect(try await answer(kind, key: key).count > 4)
    }
}

@Suite struct AIErrorMessageTests {
    @Test func quotaWithRetryHintIsShortChinese() {
        let gemini = "You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits. * Quota exceeded for metric: generate_content_free_tier_requests, limit: 20\nPlease retry in 14382.5s."
        let error = AIError.http(status: 429, message: gemini)
        #expect(error.errorDescription == "额度用完了，约 4 小时后可以再试。")
        #expect(error.detail == gemini)
    }

    @Test func rateLimitWithoutHint() {
        #expect(AIError.http(status: 429, message: "Rate limit reached").errorDescription == "请求太频繁，稍后再试。")
        #expect(AIError.http(status: 429, message: "Please try again in 20s").errorDescription == "请求太频繁，约 20 秒后可以再试。")
    }

    @Test func authErrorKeepsSettingsHintAndDropsDetail() {
        let text = AIError.http(status: 401, message: String(repeating: "x", count: 500)).errorDescription ?? ""
        #expect(text.contains("API key"))
        #expect(text.count < 40)
    }

    @Test func unknownStatusClipsProviderMessage() {
        let text = AIError.http(status: 400, message: String(repeating: "a", count: 300) + "\nmore").errorDescription ?? ""
        #expect(text.count < 100)
        #expect(text.hasSuffix("…"))
    }
}

@Suite struct ModelCatalogTests {
    @Test func everyProviderRecommendsItsFastTierFirst() {
        for kind in AIProviderKind.allCases {
            #expect(kind.curatedModels.first?.tier == .fast)
            #expect(kind.recommendedModel == kind.curatedModels[0].id)
            #expect(Set(kind.curatedModels.map(\.id)).count == kind.curatedModels.count)
        }
    }

    @Test func openAIListingDropsNonChatSnapshotsAndCurated() {
        let listed = [
            ModelInfo(id: "gpt-6-luna", created: Date(timeIntervalSince1970: 300)),
            ModelInfo(id: "gpt-5.4-mini", created: Date(timeIntervalSince1970: 200)),
            ModelInfo(id: "gpt-5.4-mini-2026-03-01", created: Date(timeIntervalSince1970: 199)),
            ModelInfo(id: "gpt-5.5", created: Date(timeIntervalSince1970: 250)),
            ModelInfo(id: "text-embedding-3-large"), ModelInfo(id: "whisper-1"), ModelInfo(id: "gpt-realtime"),
            ModelInfo(id: "gpt-6-codex"), ModelInfo(id: "tts-1-hd"),
            ModelInfo(id: "gpt-4.1", created: Date(timeIntervalSince1970: 100), deprecated: true),
        ]
        #expect(ModelCatalog.moreModels(listed, kind: .openAI) == ["gpt-5.5", "gpt-5.4-mini"])
    }

    @Test func anthropicKeepsTheNewestOfDatedOnlySnapshots() {
        let listed = [
            ModelInfo(id: "claude-sonnet-4-5-20250929"), ModelInfo(id: "claude-sonnet-4-5-20250514"),
            ModelInfo(id: "claude-haiku-5-5"), ModelInfo(id: "claude-opus-4-1-20250805", deprecated: true),
        ]
        #expect(ModelCatalog.moreModels(listed, kind: .anthropic) == ["claude-sonnet-4-5-20250929"])
    }

    @Test func geminiUsesGenerationMethodsAndTheDeprecationList() {
        let chat = ["generateContent", "countTokens"]
        let listed = [
            ModelInfo(id: "gemini-3.5-flash", generationMethods: chat),
            ModelInfo(id: "gemini-3.5-flash-001", generationMethods: chat),
            ModelInfo(id: "gemini-2.5-flash", generationMethods: chat),
            ModelInfo(id: "gemini-2.0-flash-001", generationMethods: chat),
            ModelInfo(id: "gemini-3.5-flash-live", generationMethods: chat),
            ModelInfo(id: "gemini-embedding-001", generationMethods: ["embedContent"]),
            ModelInfo(id: "gemini-3.5-flash-lite", generationMethods: chat),
        ]
        #expect(ModelCatalog.moreModels(listed, kind: .gemini) == ["gemini-3.5-flash"])
    }

    @Test func parsesEachProvidersListing() {
        let openAI = #"{"data":[{"id":"gpt-5.5","created":1700000000,"shutdown_date":null},{"id":"old","shutdown_date":"2026-01-01"}]}"#
        let o = AIProviderKind.parseModels(openAI, kind: .openAI)
        #expect(o.map(\.id) == ["gpt-5.5", "old"] && o[0].created != nil && o[1].deprecated)
        let anthropic = #"{"data":[{"id":"claude-haiku-5-5","created_at":"2026-08-01T00:00:00Z"},{"id":"x","created_at":"1970-01-01T00:00:00Z","lifecycle":"deprecated"}]}"#
        let a = AIProviderKind.parseModels(anthropic, kind: .anthropic)
        #expect(a[0].created != nil && a[1].created == nil && a[1].deprecated)
        let gemini = #"{"models":[{"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]}]}"#
        #expect(AIProviderKind.parseModels(gemini, kind: .gemini).first?.id == "gemini-3.5-flash")
    }

    @Test func latencySummaryReadsInSeconds() {
        let l = AnswerLatency(firstWord: .milliseconds(620), total: .milliseconds(1440))
        #expect(l.summary == "首字 0.6 秒 · 完成 1.4 秒")
        #expect(AnswerLatency.seconds(.seconds(12.4)) == "12 秒")
    }
}

@Suite struct StudyTests {
    @Test func wordsAndShortPhrasesAreLookedUp() {
        #expect(PassageShape.isLookup("hedges"))
        #expect(PassageShape.isLookup("living fossil"))
        #expect(PassageShape.isLookup("give up on"))
        #expect(PassageShape.isLookup("銀杏"))
        #expect(!PassageShape.isLookup("It hedges against catastrophe by doing many things."))
        #expect(!PassageShape.isLookup("one two three four five"))
        #expect(!PassageShape.isLookup("Stop. Go"))
    }

    @Test func jsonIsFoundInsideFencesAndProse() throws {
        let text = """
        Here you go:
        ```json
        {"term": "hedge", "context_meaning": "分散风险", "senses": [{"pos": "v.", "meaning": "对冲"}]}
        ```
        """
        let card = try StudyJSON.decode(WordCard.self, from: text)
        #expect(card.term == "hedge")
        #expect(card.contextMeaning == "分散风险")
        #expect(card.summary.contains("这里的意思：分散风险"))
        #expect(throws: AIError.badFormat) { try StudyJSON.decode(WordCard.self, from: "no json here") }
    }

    @Test func storedNotesRoundTrip() throws {
        var note = StudyNote(keyItems: KeyItems(items: [KeyItem(text: "hedge against", kind: "collocation")],
                                                analysisWorthy: true, analysisHint: "比喻"))
        note.analysisError = "x"
        let back = StudyJSON.load(StudyNote.self, from: StudyJSON.encode(note))
        #expect(back == note)
        #expect(back?.keyItems?.items.first?.kindLabel == "搭配")
        let parsed = try StudyJSON.decode(KeyItems.self, from: #"{"items":[],"analysis_worthy":false,"analysis_hint":""}"#)
        #expect(parsed.analysisWorthy == false)
    }

    @Test func followUpCarriesTheNoteAndEarlierRounds() {
        let context = PassageContext(bookTitle: "B", passage: "It hedges.", readerLanguage: "简体中文")
        let request = PromptBuilder.followUp(
            context: context,
            material: FollowUpMaterial(task: "翻译", answer: "它在对冲。", keyItems: [KeyItem(text: "hedge", meaning: "对冲")]),
            history: [FollowUp(question: "为什么？", answer: "因为……"), FollowUp(question: "失败的", error: "x")],
            question: "再举个例子", level: .intermediate)
        #expect(request.user.contains("它在对冲。"))
        #expect(request.user.contains("- hedge：对冲"))
        #expect(request.user.contains("读者：为什么？"))
        #expect(!request.user.contains("失败的"))
        #expect(request.user.hasSuffix("读者现在追问：再举个例子"))
        #expect(request.system.contains("中级"))
    }

    @Test func learningTranslationsStayBare() {
        let context = PassageContext(bookTitle: "", passage: "It hedges.", readerLanguage: "简体中文")
        #expect(PromptBuilder.request(for: .translate, context: context, learning: true).user.contains("不加说明"))
        #expect(PromptBuilder.request(for: .translate, context: context).user.contains("关键词"))
    }
}
