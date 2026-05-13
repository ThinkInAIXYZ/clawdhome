import Foundation

enum L10n {
    // Legacy API: chinese sentence as key
    static func t(_ key: String) -> String {
        localizedString(forKey: key, fallback: key, tableName: nil)
    }

    // Stable-key API: recommended for product copy
    static func k(_ key: String, fallback: String) -> String {
        localizedString(forKey: key, fallback: fallback, tableName: "Stable")
    }

    // Stable-key API with bilingual fallback to avoid mixed-language UI when a key misses at runtime.
    static func k(_ key: String, zh: String, en: String) -> String {
        localizedString(forKey: key, fallback: fallbackForCurrentLanguage(zh: zh, en: en), tableName: "Stable")
    }

    static func f(_ key: String, fallback: String, _ args: CVarArg...) -> String {
        String(format: k(key, fallback: fallback), arguments: args)
    }

    static func f(_ key: String, zh: String, en: String, _ args: CVarArg...) -> String {
        String(format: k(key, zh: zh, en: en), arguments: args)
    }

    private static func localizedString(forKey key: String, fallback: String, tableName: String?) -> String {
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        guard let appLanguage = AppLanguage(rawValue: selected), appLanguage != .system else {
            return NSLocalizedString(key, tableName: tableName, bundle: .main, value: fallback, comment: "")
        }

        let bundleLanguage: String
        switch appLanguage {
        case .english:
            bundleLanguage = "en"
        case .chineseSimplified:
            bundleLanguage = "zh-Hans"
        case .system:
            bundleLanguage = "Base"
        }

        guard let path = Bundle.main.path(forResource: bundleLanguage, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return NSLocalizedString(key, tableName: tableName, bundle: .main, value: fallback, comment: "")
        }
        return bundle.localizedString(forKey: key, value: fallback, table: tableName)
    }

    private static func fallbackForCurrentLanguage(zh: String, en: String) -> String {
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        guard let appLanguage = AppLanguage(rawValue: selected) else {
            return en
        }

        switch appLanguage {
        case .english:
            return en
        case .chineseSimplified:
            return zh
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("zh") ? zh : en
        }
    }
}
