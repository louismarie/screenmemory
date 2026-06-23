import Foundation

enum AppLanguage: String {
    case english = "en"
    case french = "fr"

    init(_ raw: String?) {
        let value = (raw ?? "").lowercased()
        if value.hasPrefix("fr") {
            self = .french
        } else {
            self = .english
        }
    }

    static var preferred: AppLanguage {
        AppLanguage(Locale.preferredLanguages.first)
    }

    var locale: Locale {
        switch self {
        case .english:
            return Locale(identifier: "en_US")
        case .french:
            return Locale(identifier: "fr_FR")
        }
    }

    var modelInstruction: String {
        t("modelInstruction", "Write all user-visible output in English.")
    }

    var notEnoughActivity: String {
        t("notEnoughActivityFull", "Not enough activity for this period, or Apple Intelligence is unavailable.")
    }

    var noMemoryFound: String {
        t("noMemoryFoundFull", "No memory found for this period.")
    }

    var notSeenOnScreen: String {
        t("notSeenOnScreen", "I did not see that on screen in the retrieved excerpts.")
    }

    func t(_ key: String, _ fallback: String) -> String {
        LocalizationCatalog.string(key, language: rawValue) ?? fallback
    }

    func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: t(key, fallback), locale: locale, arguments: arguments)
    }

    func heading(_ key: Heading) -> String {
        t("heading.\(key.rawValue)", key.fallback)
    }

    enum Heading: String {
        case highlights
        case unfinished
        case sessions
        case improve
        case keep
        case techRadar
        case numbers
        case achievements
        case patterns
        case time

        var fallback: String {
            switch self {
            case .highlights:
                return "Highlights"
            case .unfinished:
                return "To resume"
            case .sessions:
                return "Sessions"
            case .improve:
                return "Improve"
            case .keep:
                return "Keep doing"
            case .techRadar:
                return "Tech radar"
            case .numbers:
                return "Numbers"
            case .achievements:
                return "Achievements"
            case .patterns:
                return "Work patterns"
            case .time:
                return "Time"
            }
        }
    }
}

enum LocalizationCatalog {
    private static let catalogs: [String: [String: CatalogValue]] = {
        var loaded = [String: [String: CatalogValue]]()
        for language in ["en", "fr"] {
            guard let url = Bundle.module.url(forResource: language,
                                              withExtension: "json",
                                              subdirectory: "i18n"),
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            loaded[language] = object.reduce(into: [String: CatalogValue]()) { result, entry in
                if let string = entry.value as? String {
                    result[entry.key] = .string(string)
                } else if let strings = entry.value as? [String] {
                    result[entry.key] = .strings(strings)
                }
            }
        }
        return loaded
    }()

    static func string(_ key: String, language: String) -> String? {
        if case .string(let localized)? = catalogs[language]?[key] {
            return localized
        }
        if case .string(let fallback)? = catalogs["en"]?[key] {
            return fallback
        }
        return nil
    }

    static func stringArray(_ key: String, languages: [String] = ["en", "fr"]) -> [String] {
        languages.flatMap { language in
            if case .strings(let values)? = catalogs[language]?[key] {
                return values
            }
            return []
        }
    }

    private enum CatalogValue: Sendable {
        case string(String)
        case strings([String])
    }
}
