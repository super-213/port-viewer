import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "appLanguage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.string("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        // Bundle and native menus read this application-specific override at launch.
        // Removing it restores the user's system language preferences.
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
