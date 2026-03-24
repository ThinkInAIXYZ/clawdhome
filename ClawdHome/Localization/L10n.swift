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

    static func f(_ key: String, fallback: String, _ args: CVarArg...) -> String {
        String(format: k(key, fallback: fallback), arguments: args)
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
}
