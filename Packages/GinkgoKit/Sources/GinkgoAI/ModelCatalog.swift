import Foundation

/// One hand-picked model the settings menu offers before anything is fetched.
public struct ModelChoice: Hashable, Sendable {
    public enum Tier: Sendable { case fast, balanced, strongest }

    public var id: String
    public var tier: Tier

    /// One line under the model id in the menu.
    public var note: String {
        switch tier {
        case .fast: String(localized: "推荐 · 速度快、费用低", bundle: L10n.bundle)
        case .balanced: String(localized: "均衡 · 回答更细", bundle: L10n.bundle)
        case .strongest: String(localized: "能力最强 · 较慢、较贵", bundle: L10n.bundle)
        }
    }
}

extension AIProviderKind {
    /// Margin answers are short, so time to first word matters more than raw capability: each provider's
    /// fast tier comes first and is the recommendation. Checked 2026-11-22 against the providers' model pages
    /// (OpenAI: gpt-6-luna is the efficient tier; Gemini: aistudio.google.com/docs/models recommends
    /// 3.5 Flash-Lite for low-latency, cost-efficient work).
    public var curatedModels: [ModelChoice] {
        switch self {
        case .openAI:
            [.init(id: "gpt-6-luna", tier: .fast), .init(id: "gpt-6.1-terra", tier: .balanced),
             .init(id: "gpt-6.1-sol", tier: .strongest)]
        case .anthropic:
            [.init(id: "claude-haiku-5-5", tier: .fast), .init(id: "claude-sonnet-5-5", tier: .balanced),
             .init(id: "claude-opus-5-5", tier: .strongest)]
        case .gemini:
            [.init(id: "gemini-3.5-flash-lite", tier: .fast), .init(id: "gemini-3.8-flash", tier: .balanced),
             .init(id: "gemini-4-hydrogen", tier: .strongest)]
        }
    }

    /// Used whenever the user hasn't picked a model, so it follows future recommendations.
    public var recommendedModel: String { curatedModels[0].id }
}

/// One entry from a provider's list-models endpoint.
public struct ModelInfo: Hashable, Sendable {
    public var id: String
    /// Release time when the provider reports one (OpenAI `created`, Anthropic `created_at`).
    public var created: Date?
    /// Gemini `supportedGenerationMethods`; nil when the provider doesn't report capabilities.
    public var generationMethods: [String]?
    /// Flagged by the provider (Anthropic `lifecycle`, OpenAI `shutdown_date`).
    public var deprecated: Bool

    public init(id: String, created: Date? = nil, generationMethods: [String]? = nil, deprecated: Bool = false) {
        self.id = id
        self.created = created
        self.generationMethods = generationMethods
        self.deprecated = deprecated
    }
}

/// Turns a raw model listing into the short "more models" list: chat models only, no deprecated models or
/// dated snapshots, nothing already curated, newest first. Rules don't parse model families, so new names keep working.
public enum ModelCatalog {
    public static func moreModels(_ listed: [ModelInfo], kind: AIProviderKind) -> [String] {
        var seen = Set(kind.curatedModels.map(\.id))
        let usable = listed.filter { m in
            !m.id.isEmpty && !m.deprecated && !isKnownDeprecated(m.id, kind: kind) && isChatModel(m, kind: kind)
        }
        let snapshots = hiddenSnapshots(usable)
        let kept = usable.filter { !snapshots.contains($0.id) && seen.insert($0.id).inserted }
        return newestFirst(kept).map(\.id)
    }

    // MARK: Deprecation

    /// Gemini's Model resource has no deprecation field. Source: aistudio.google.com/docs/models, checked 2026-11-17.
    private static let knownDeprecated: [AIProviderKind: Set<String>] = [
        .gemini: [
            "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-image", "gemini-omni-1.1-flash",
            "gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-3-pro-preview", "gemini-3.1-flash-lite-preview",
        ],
    ]

    static func isKnownDeprecated(_ id: String, kind: AIProviderKind) -> Bool {
        guard let list = knownDeprecated[kind] else { return false }
        let id = id.lowercased()
        return list.contains(id) || snapshotStamp(id)?.aliases.contains(where: list.contains) == true
    }

    // MARK: Purpose

    private static let nonChatSubstrings = [
        "embedding", "whisper", "transcribe", "audio", "realtime", "moderation",
        "image", "dall-e", "imagen", "sora", "search", "computer-use", "robotics",
    ]
    private static let nonChatTokens: Set<String> = ["embed", "tts", "veo"]

    /// Whether the model answers a plain text prompt through the endpoint Ginkgo calls.
    static func isChatModel(_ model: ModelInfo, kind: AIProviderKind) -> Bool {
        let id = model.id.lowercased()
        var substrings = nonChatSubstrings
        var tokens = nonChatTokens
        switch kind {
        case .gemini:
            if let methods = model.generationMethods, !methods.contains("generateContent") { return false }
            // TTS, image and Live models also answer generateContent but don't return text for a prompt.
            tokens.formUnion(["live", "aqa"])
        case .openAI:
            substrings += ["codex", "deep-research", "instruct", "babbage", "davinci"]
        case .anthropic:
            break
        }
        if substrings.contains(where: { id.contains($0) }) { return false }
        let parts = id.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return !parts.contains(where: tokens.contains)
    }

    // MARK: Snapshots

    /// Date or version stamps that pin a snapshot of an alias; the capture group is a sortable key.
    nonisolated(unsafe) private static let stampPatterns: [(Regex<(Substring, Substring)>, (Substring) -> Int?)] = [
        (/-(20\d{2}-\d{2}-\d{2})$/, { Int($0.replacingOccurrences(of: "-", with: "")) }),   // gpt-5-2025-08-07
        (/-(20\d{6})$/, { Int($0) }),                                                       // claude-x-20250929
        (/-(\d{2}-20\d{2})$/, { s in                                                        // …-preview-09-2025
            let p = s.split(separator: "-")
            return Int(p[1] + p[0])
        }),
        (/-preview-(\d{2}-\d{2})$/, { Int($0.replacingOccurrences(of: "-", with: "")) }),   // …-preview-05-20
        (/[a-z]-(\d{3})$/, { Int($0) }),                                                    // gemini-2.0-flash-001
    ]

    /// "gpt-5-2025-08-07" → (["gpt-5", "gpt-5-latest"], 20250807); nil when the id has no stamp.
    static func snapshotStamp(_ id: String) -> (aliases: [String], key: Int)? {
        let lower = id.lowercased()
        for (regex, key) in stampPatterns {
            guard let match = lower.firstMatch(of: regex), let k = key(match.1) else { continue }
            // Keep a leading letter the 3-digit pattern had to match.
            var alias = String(lower[..<match.range.lowerBound])
            if lower[match.range].first?.isLetter == true { alias.append(lower[match.range].first!) }
            var aliases = [alias, alias + "-latest"]
            if alias.hasSuffix("-preview") { aliases.append(String(alias.dropLast("-preview".count))) }
            return (aliases, k)
        }
        return nil
    }

    /// Snapshots whose alias is also listed, and all but the newest snapshot where no alias is listed.
    static func hiddenSnapshots(_ models: [ModelInfo]) -> Set<String> {
        let ids = Set(models.map { $0.id.lowercased() })
        var hidden = Set<String>()
        var orphans: [String: [(id: String, key: Int)]] = [:]
        for m in models {
            guard let stamp = snapshotStamp(m.id) else { continue }
            if stamp.aliases.contains(where: ids.contains) {
                hidden.insert(m.id)
            } else {
                orphans[stamp.aliases[0], default: []].append((m.id, stamp.key))
            }
        }
        for group in orphans.values where group.count > 1 {
            let newest = group.max { $0.key < $1.key }!.id
            for entry in group where entry.id != newest { hidden.insert(entry.id) }
        }
        return hidden
    }

    // MARK: Ordering

    /// Newest release first; models without a date follow by the first version number in the name, descending.
    static func newestFirst(_ models: [ModelInfo]) -> [ModelInfo] {
        Array(models.enumerated()).sorted { a, b in
            switch (a.element.created, b.element.created) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let va = version(a.element.id), vb = version(b.element.id)
                if va != vb { return !va.lexicographicallyPrecedes(vb) }
                return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// "gemini-2.5-flash" → [2, 5].
    static func version(_ id: String) -> [Int] {
        guard let match = id.firstMatch(of: /\d+(\.\d+)*/) else { return [] }
        return match.0.split(separator: ".").compactMap { Int($0) }
    }
}

// MARK: Listing

extension AIProviderKind {
    /// Fetches the provider's model list with the user's key.
    public func listModels(apiKey: String, session: URLSession = .shared) async throws -> [ModelInfo] {
        var request: URLRequest
        switch self {
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            throw AIError.http(status: status, message: OpenAIClient.errorMessage(in: body))
        }
        return Self.parseModels(body, kind: self)
    }

    static func parseModels(_ body: String, kind: AIProviderKind) -> [ModelInfo] {
        guard let json = jsonObject(body) else { return [] }
        switch kind {
        case .openAI:
            return (json["data"] as? [[String: Any]] ?? []).compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                let created = (m["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let shutdown = m["shutdown_date"] as? String
                return ModelInfo(id: id, created: created, deprecated: shutdown?.isEmpty == false)
            }
        case .anthropic:
            return (json["data"] as? [[String: Any]] ?? []).compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                // `created_at` may be the epoch when the release date is unknown.
                let created = (m["created_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
                    .flatMap { $0.timeIntervalSince1970 > 86_400 ? $0 : nil }
                return ModelInfo(id: id, created: created, deprecated: m["lifecycle"] as? String == "deprecated")
            }
        case .gemini:
            return (json["models"] as? [[String: Any]] ?? []).compactMap { m in
                guard let name = m["name"] as? String else { return nil }
                return ModelInfo(id: name.replacingOccurrences(of: "models/", with: ""),
                                 generationMethods: m["supportedGenerationMethods"] as? [String] ?? [])
            }
        }
    }
}

// MARK: Latency

/// How long a test answer took: time to the first word (what a reader waits for) and to the end.
public struct AnswerLatency: Equatable, Sendable {
    public var firstWord: Duration
    public var total: Duration

    public init(firstWord: Duration, total: Duration) {
        self.firstWord = firstWord
        self.total = total
    }

    /// "首字 0.6 秒 · 完成 1.4 秒"
    public var summary: String {
        String(localized: "首字 \(Self.seconds(firstWord)) · 完成 \(Self.seconds(total))", bundle: L10n.bundle)
    }

    static func seconds(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        let value = s < 10 ? String(format: "%.1f", s) : "\(Int(s.rounded()))"
        return String(localized: "\(value) 秒", bundle: L10n.bundle)
    }

    /// Streams `request` and times it; returns the text and the latency.
    public static func measure(_ client: AIClient, _ request: AIRequest) async throws -> (String, AnswerLatency) {
        let clock = ContinuousClock()
        let start = clock.now
        var first: Duration?
        var text = ""
        for try await chunk in client.stream(request) {
            if first == nil { first = clock.now - start }
            text += chunk
        }
        let total = clock.now - start
        return (text, AnswerLatency(firstWord: first ?? total, total: total))
    }
}
