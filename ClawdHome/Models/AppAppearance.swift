import SwiftUI

/// 外观模式：跟随系统 → 浅色 → 深色，三态循环
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var label: String {
        switch self {
        case .system: return L10n.k("model.appearance.system", fallback: "跟随系统")
        case .light:  return L10n.k("model.appearance.light", fallback: "浅色")
        case .dark:   return L10n.k("model.appearance.dark", fallback: "深色")
        }
    }

    /// 循环到下一个模式
    var next: AppAppearance {
        switch self {
        case .system: return .light
        case .light:  return .dark
        case .dark:   return .system
        }
    }
}
