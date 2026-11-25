import Foundation
import GinkgoAI
import NaturalLanguage
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
    /// How well the reader knows the languages they read in. Shapes word cards, key expressions and analysis.
    var learnerLevel: LearnerLevel {
        didSet { defaults.set(learnerLevel.rawValue, forKey: "ai.learnerLevel") }
    }
    /// Bumped when a key changes so views re-read `hasKey`.
    private(set) var keyRevision = 0

    static let languages = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español"]

    private init() {
        provider = AIProviderKind(rawValue: defaults.string(forKey: "ai.provider") ?? "") ?? .openAI
        readerLanguage = defaults.string(forKey: "ai.readerLanguage") ?? Self.systemLanguage
        learnerLevel = LearnerLevel(rawValue: defaults.string(forKey: "ai.learnerLevel") ?? "") ?? .intermediate
    }

    /// Whether a passage is in a language other than the reader's own, so a translation should teach as well.
    func isLearning(_ passage: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(passage)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return false }
        return !Self.sameLanguage(language, readerLanguage)
    }

    static func sameLanguage(_ language: NLLanguage, _ reader: String) -> Bool {
        switch reader {
        // A short CJK word is easily taken for Japanese or the other Chinese script; only kana makes it Japanese.
        case "简体中文", "繁體中文": [.simplifiedChinese, .traditionalChinese].contains(language)
        case "日本語": language == .japanese
        case "한국어": language == .korean
        case "Français": language == .french
        case "Deutsch": language == .german
        case "Español": language == .spanish
        default: language == .english
        }
    }

    func model(for p: AIProviderKind) -> String {
        defaults.string(forKey: "ai.model.\(p.rawValue)") ?? ""
    }

    /// Picking the recommended model stores nothing, so the choice follows future recommendations.
    func setModel(_ model: String, for p: AIProviderKind) {
        let model = model.trimmingCharacters(in: .whitespaces)
        defaults.set(model == p.recommendedModel ? "" : model, forKey: "ai.model.\(p.rawValue)")
        keyRevision += 1
    }

    func effectiveModel(for p: AIProviderKind) -> String {
        let m = model(for: p)
        return m.isEmpty ? p.recommendedModel : m
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

    // MARK: Consent

    /// Bumped when consent changes so views re-read it.
    private(set) var consentRevision = 0

    /// Whether the reader agreed to send passages to this service. Asked once per service, before its first request.
    func hasConsent(for p: AIProviderKind) -> Bool {
        _ = consentRevision
        return defaults.bool(forKey: Self.consentKey(p))
    }

    func setConsent(_ on: Bool, for p: AIProviderKind) {
        defaults.set(on, forKey: Self.consentKey(p))
        consentRevision += 1
    }

    /// A request would go out now but the reader hasn't agreed yet. Without a key it fails as before instead.
    var needsConsent: Bool { hasKey && !hasConsent(for: provider) }

    static func consentKey(_ p: AIProviderKind) -> String { "ai.consent.\(p.rawValue)" }

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

/// What the reader is told before passages leave the device.
enum ConsentText {
    static func message(_ p: AIProviderKind) -> String {
        "AI 回答由 \(p.displayName) 生成。Ginkgo 会用你自己的 key，把选中的原文、它前后的几段文字、书名和你的问题直接发给 "
            + "\(p.displayName)。Ginkgo 没有自己的服务器，看不到也不保存这些内容；\(p.displayName) 按它的隐私政策处理。"
            + "可以随时在设置里关掉。"
    }
}
