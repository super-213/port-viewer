import AppKit
import SwiftUI

enum PVRadius {
    static let micro: CGFloat = 5
    static let small: CGFloat = 7
    static let control: CGFloat = 10
    static let node: CGFloat = 12
    static let panel: CGFloat = 16
    static let floating: CGFloat = 18
}

enum PVSpacing {
    static let one: CGFloat = 4
    static let two: CGFloat = 8
    static let three: CGFloat = 12
    static let four: CGFloat = 16
    static let five: CGFloat = 20
    static let six: CGFloat = 24
}

enum PVMotion {
    static let hover = Animation.easeOut(duration: 0.10)
    static let focus = Animation.easeOut(duration: 0.14)
    static let reveal = Animation.easeOut(duration: 0.18)
    static let selection = Animation.easeInOut(duration: 0.20)
}

enum PVPalette {
    static let canvasBase = dynamic(light: 0xF3F4F6, dark: 0x0D1118)
    static let canvasTop = dynamic(light: 0xF8F9FB, dark: 0x151B26)
    static let canvasBottom = dynamic(light: 0xEEF0F3, dark: 0x0A0E15)

    static let surfaceContent = dynamic(light: 0xFCFDFF, dark: 0x161C27, lightAlpha: 0.94, darkAlpha: 0.94)
    static let surfaceControl = dynamic(light: 0xFFFFFF, dark: 0x2E3849, lightAlpha: 0.72, darkAlpha: 0.74)
    static let surfaceControlHover = dynamic(light: 0xFFFFFF, dark: 0x3C485C, lightAlpha: 0.88, darkAlpha: 0.84)
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x283142, lightAlpha: 0.90, darkAlpha: 0.90)
    static let surfaceBento = dynamic(light: 0xFFFFFF, dark: 0x202836, lightAlpha: 0.98, darkAlpha: 0.96)

    static let textPrimary = dynamic(light: 0x172033, dark: 0xF4F7FC)
    static let textSecondary = dynamic(light: 0x4F5C71, dark: 0xB8C2D1)
    static let textTertiary = dynamic(light: 0x6D798D, dark: 0x929EB0)

    static let edgeOuter = dynamic(light: 0x52627A, dark: 0xDCE7F8, lightAlpha: 0.16, darkAlpha: 0.18)
    static let edgeOuterStrong = dynamic(light: 0x40536E, dark: 0xE8F0FF, lightAlpha: 0.27, darkAlpha: 0.30)
    static let edgeInnerHighlight = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.66, darkAlpha: 0.10)
    static let edgeSeparator = dynamic(light: 0x3C4B60, dark: 0xD6E2F5, lightAlpha: 0.17, darkAlpha: 0.14)
    static let shadowNear = dynamic(light: 0x141E30, dark: 0x000000, lightAlpha: 0.07, darkAlpha: 0.24)
    static let shadowAmbient = dynamic(light: 0x192844, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0.36)

    static let accentPrimary = dynamic(light: 0x1677FF, dark: 0x5AA7FF)
    static let accentIndigo = dynamic(light: 0x5C66E8, dark: 0x858CFF)
    static let accentCyan = dynamic(light: 0x159FBE, dark: 0x4CCBE1)
    static let waiting = dynamic(light: 0x239B62, dark: 0x45D087)
    static let connected = dynamic(light: 0x1677E8, dark: 0x62AAFF)
    static let warning = dynamic(light: 0xC87512, dark: 0xFFB14A)
    static let danger = dynamic(light: 0xD64650, dark: 0xFF6B73)
    static let neutral = dynamic(light: 0x667389, dark: 0x97A4B6)

    static let accentGradient = LinearGradient(
        colors: [
            dynamic(light: 0x2387FF, dark: 0x55AAFF),
            dynamic(light: 0x596DFF, dark: 0x777EFF)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let usesDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(hex: usesDark ? dark : light, alpha: usesDark ? darkAlpha : lightAlpha)
        })
    }

    private static func nsColor(hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
