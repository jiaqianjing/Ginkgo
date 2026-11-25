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

    /// Where the user creates a key.
    public var keyPage: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    /// How the service treats what is sent to its API, shown where the reader agrees to send passages.
    public var privacyPolicy: URL {
        switch self {
        case .openAI: URL(string: "https://openai.com/policies/privacy-policy/")!
        case .anthropic: URL(string: "https://www.anthropic.com/legal/privacy")!
        case .gemini: URL(string: "https://ai.google.dev/gemini-api/terms")!
        }
    }

    public func client(apiKey: String, model: String, session: URLSession = .shared) -> AIClient {
        let model = model.trimmingCharacters(in: .whitespaces).isEmpty ? recommendedModel : model
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
    /// The model answered, but not in the shape asked for (a JSON card).
    case badFormat

    /// One short line for a margin card. The provider's own message stays in `detail`.
    public var errorDescription: String? {
        switch self {
        case .missingKey: "还没有填写 API key。请在设置里填好再试。"
        case .http(let status, let message):
            switch status {
            case 401, 403: "API key 无效或没有权限，请在设置里检查。"
            case 404: "找不到这个模型，请在设置里检查模型名称。"
            case 429: Self.rateLimitSummary(message)
            case 500...599: "服务暂时不可用（\(status)），稍后再试。"
            default: "服务返回错误 \(status)：\(Self.clip(message))"
            }
        case .refused: "模型拒绝回答这个问题。"
        case .empty: "模型没有返回内容。"
        case .badFormat: "回答的格式不对，可以重试或换个模型。"
        }
    }

    /// The provider's full message, for logs or a details view.
    public var detail: String? {
        if case .http(_, let message) = self, !message.isEmpty { return message }
        return nil
    }

    static func rateLimitSummary(_ message: String) -> String {
        let lower = message.lowercased()
        let quota = lower.contains("quota") || lower.contains("billing") || lower.contains("credit")
        var text = quota ? "额度用完了" : "请求太频繁"
        if let wait = retryDelay(in: message) { text += "，约 \(wait)后可以再试" } else { text += "，稍后再试" }
        return text + "。"
    }

    /// Reads "retry in 14382.5s" (Gemini) or "try again in 20s" style hints and renders them in Chinese.
    static func retryDelay(in message: String) -> String? {
        guard let match = message.firstMatch(of: /(?i)(?:retry|try again) in ([0-9]+(?:\.[0-9]+)?)\s*s/),
              let seconds = Double(match.1) else { return nil }
        let s = Int(seconds.rounded(.up))
        if s >= 3600 { return "\(Int((Double(s) / 3600).rounded())) 小时" }
        if s >= 60 { return "\(Int((Double(s) / 60).rounded(.up))) 分钟" }
        return "\(max(s, 1)) 秒"
    }

    static func clip(_ message: String, limit: Int = 80) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}

/// Streams the answer text as it is generated.
public protocol AIClient: Sendable {
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
}
