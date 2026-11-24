import Foundation

/// OpenAI Responses API, streamed.
struct OpenAIClient: StreamingClient {
    let apiKey: String
    let model: String
    let session: URLSession

    func makeURLRequest(_ r: AIRequest) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        var body: [String: Any] = [
            "model": model,
            "instructions": r.system,
            "input": r.user,
            "max_output_tokens": r.maxTokens,
            "stream": true,
            "store": false,
        ]
        // Reasoning models think before answering; margin notes need speed more than depth.
        if model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") || model.hasPrefix("o") {
            body["reasoning"] = ["effort": "low"]
        }
        return try postRequest(URL(string: "https://api.openai.com/v1/responses")!,
                               headers: ["Authorization": "Bearer \(apiKey)"], body: body)
    }

    func text(from event: SSEEvent) throws -> String? {
        guard let json = jsonObject(event.data), let type = json["type"] as? String else { return nil }
        switch type {
        case "response.output_text.delta": return json["delta"] as? String
        case "response.refusal.delta": throw AIError.refused
        case "error", "response.failed":
            let error = (json["error"] as? [String: Any]) ?? ((json["response"] as? [String: Any])?["error"] as? [String: Any])
            throw AIError.http(status: 500, message: error?["message"] as? String ?? "")
        default: return nil
        }
    }
}

/// Anthropic Messages API, streamed.
struct AnthropicClient: StreamingClient {
    let apiKey: String
    let model: String
    let session: URLSession

    func makeURLRequest(_ r: AIRequest) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": r.maxTokens,
            "system": r.system,
            "messages": [["role": "user", "content": r.user]],
            "stream": true,
            // Short margin answers: keep thinking light so the first words arrive quickly.
            "output_config": ["effort": "low"],
            // On a policy decline the API retries on a suitable fallback model inside the same call.
            "fallbacks": "default",
        ]
        return try postRequest(URL(string: "https://api.anthropic.com/v1/messages")!,
                               headers: ["x-api-key": apiKey,
                                         "anthropic-version": "2026-10-21",
                                         "anthropic-beta": "server-side-fallback-2026-07-01"],
                               body: body)
    }

    func text(from event: SSEEvent) throws -> String? {
        guard let json = jsonObject(event.data), let type = json["type"] as? String else { return nil }
        switch type {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        case "message_delta":
            if let delta = json["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                throw AIError.refused
            }
            return nil
        case "error":
            let error = json["error"] as? [String: Any]
            throw AIError.http(status: 500, message: error?["message"] as? String ?? "")
        default: return nil
        }
    }
}

/// Gemini generateContent, streamed as SSE.
struct GeminiClient: StreamingClient {
    let apiKey: String
    let model: String
    let session: URLSession

    func makeURLRequest(_ r: AIRequest) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": r.system]]],
            "contents": [["role": "user", "parts": [["text": r.user]]]],
            "generationConfig": ["maxOutputTokens": r.maxTokens],
        ]
        let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):streamGenerateContent?alt=sse")!
        return try postRequest(url, headers: ["x-goog-api-key": apiKey], body: body)
    }

    func text(from event: SSEEvent) throws -> String? {
        guard let json = jsonObject(event.data) else { return nil }
        if let error = json["error"] as? [String: Any] {
            throw AIError.http(status: error["code"] as? Int ?? 500, message: error["message"] as? String ?? "")
        }
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw AIError.refused
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        // Skip thought summaries if the model sends any.
        return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
    }
}
