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
