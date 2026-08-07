import Foundation

enum L10n {
    private static let resourceBundle = Bundle(for: LocalizationBundleToken.self)

    static func string(_ key: String) -> String {
        resourceBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}

private final class LocalizationBundleToken {}
