import Foundation

/// The model services a user can bring their own key for.
public enum AIProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAI, anthropic, gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        }
    }

    /// A good default for short margin answers; the user can type any model id in settings.
    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-5.5"
        case .anthropic: "claude-opus-5-5"
        case .gemini: "gemini-3.5-flash"
        }
    }

    /// Where the user creates a key.
    public var keyPage: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    public func client(apiKey: String, model: String, session: URLSession = .shared) -> AIClient {
        let model = model.trimmingCharacters(in: .whitespaces).isEmpty ? defaultModel : model
        switch self {
        case .openAI: return OpenAIClient(apiKey: apiKey, model: model, session: session)
        case .anthropic: return AnthropicClient(apiKey: apiKey, model: model, session: session)
        case .gemini: return GeminiClient(apiKey: apiKey, model: model, session: session)
        }
    }
}

/// One prompt: instructions plus the user's message.
public struct AIRequest: Sendable, Equatable {
    public var system: String
    public var user: String
    public var maxTokens: Int

    public init(system: String, user: String, maxTokens: Int = 2000) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
    }
}

public enum AIError: LocalizedError, Equatable {
    case missingKey
    case http(status: Int, message: String)
    case refused
    case empty

    public var errorDescription: String? {
        switch self {
        case .missingKey: "还没有填写 API key。请在设置里填好再试。"
        case .http(let status, let message):
            switch status {
            case 401, 403: "API key 无效或没有权限（\(status)）。\(message)"
            case 404: "找不到这个模型，请在设置里检查模型名称。\(message)"
            case 429: "请求太频繁或额度用完了（429）。\(message)"
            default: "服务返回错误 \(status)。\(message)"
            }
        case .refused: "模型拒绝回答这个问题。"
        case .empty: "模型没有返回内容。"
        }
    }
}

/// Streams the answer text as it is generated.
public protocol AIClient: Sendable {
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
}
