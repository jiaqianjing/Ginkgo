import Foundation
import GinkgoAI
import Observation

/// The reader's AI choices. Keys live in the keychain; everything else in user defaults.
@Observable
final class AISettings {
    static let shared = AISettings()

    private let defaults = UserDefaults.standard
    private let keys = KeyStore()

    var provider: AIProviderKind {
        didSet { defaults.set(provider.rawValue, forKey: "ai.provider") }
    }
    var readerLanguage: String {
        didSet { defaults.set(readerLanguage, forKey: "ai.readerLanguage") }
    }
    /// Bumped when a key changes so views re-read `hasKey`.
    private(set) var keyRevision = 0

    static let languages = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español"]

    private init() {
        provider = AIProviderKind(rawValue: defaults.string(forKey: "ai.provider") ?? "") ?? .openAI
        readerLanguage = defaults.string(forKey: "ai.readerLanguage") ?? Self.systemLanguage
    }

    func model(for p: AIProviderKind) -> String {
        defaults.string(forKey: "ai.model.\(p.rawValue)") ?? ""
    }

    func setModel(_ model: String, for p: AIProviderKind) {
        defaults.set(model.trimmingCharacters(in: .whitespaces), forKey: "ai.model.\(p.rawValue)")
        keyRevision += 1
    }

    func effectiveModel(for p: AIProviderKind) -> String {
        let m = model(for: p)
        return m.isEmpty ? p.defaultModel : m
    }

    func key(for p: AIProviderKind) -> String? {
        if let stored = keys.key(for: p) { return stored }
        #if DEBUG
        // Simulator convenience: launch with SIMCTL_CHILD_OPENAI_API_KEY etc. Never in release builds.
        let env = ["openAI": "OPENAI_API_KEY", "anthropic": "ANTHROPIC_API_KEY", "gemini": "GEMINI_API_KEY"][p.rawValue]!
        if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty { return value }
        #endif
        return nil
    }

    func setKey(_ key: String, for p: AIProviderKind) {
        keys.setKey(key, for: p)
        keyRevision += 1
    }

    var hasKey: Bool {
        _ = keyRevision
        return key(for: provider) != nil
    }

    func client() throws -> (AIClient, label: String) {
        guard let key = key(for: provider) else { throw AIError.missingKey }
        let model = effectiveModel(for: provider)
        return (provider.client(apiKey: key, model: model), "\(provider.displayName) · \(model)")
    }

    private static var systemLanguage: String {
        let id = Locale.preferredLanguages.first ?? "zh-Hans"
        if id.hasPrefix("zh-Hant") || id.hasPrefix("zh-TW") || id.hasPrefix("zh-HK") { return "繁體中文" }
        if id.hasPrefix("zh") { return "简体中文" }
        if id.hasPrefix("ja") { return "日本語" }
        if id.hasPrefix("ko") { return "한국어" }
        if id.hasPrefix("fr") { return "Français" }
        if id.hasPrefix("de") { return "Deutsch" }
        if id.hasPrefix("es") { return "Español" }
        return "English"
    }
}
