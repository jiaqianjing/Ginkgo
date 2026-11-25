import Foundation

/// User-facing text from this package's string catalog (`Resources/Localizable.xcstrings`). The keys are the Chinese
/// text; English is the fallback for languages without a translation. Prompts sent to the model are not localized.
enum L10n {
    /// Tests pin a language with `L10n.$language.withValue("en") { … }`; the app leaves it nil and follows the system.
    @TaskLocal static var language: String?

    static var bundle: Bundle {
        if let language, let path = Bundle.module.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path) { return bundle }
        return .module
    }
}
