import AppKit
import SwiftUI

enum PVRadius {
    static let micro: CGFloat = 4
    static let small: CGFloat = 6
    static let control: CGFloat = 7
    static let node: CGFloat = 9
    static let panel: CGFloat = 11
    static let floating: CGFloat = 13
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
    static let hover = Animation.easeOut(duration: 0.14)
    static let focus = Animation.easeOut(duration: 0.16)
    static let reveal = Animation.easeOut(duration: 0.20)
    static let selection = Animation.spring(response: 0.32, dampingFraction: 0.92)
}

enum PVPalette {
    static let canvasBase = dynamic(light: 0xF0F0F2, dark: 0x1E1E20)
    static let canvasTop = dynamic(light: 0xF7F7F8, dark: 0x272729)
    static let canvasBottom = dynamic(light: 0xE9E9EB, dark: 0x19191B)

    static let surfaceGlass = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.52, darkAlpha: 0.065)
    static let surfaceContent = dynamic(light: 0xF8F8F9, dark: 0x222224, lightAlpha: 0.96, darkAlpha: 0.96)
    static let surfaceControl = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.58, darkAlpha: 0.065)
    static let surfaceControlHover = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.86, darkAlpha: 0.11)
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x303034, lightAlpha: 0.94, darkAlpha: 0.94)
    static let surfaceBento = dynamic(light: 0xFAFAFB, dark: 0x29292C, lightAlpha: 0.92, darkAlpha: 0.92)

    static let textPrimary = dynamic(light: 0x1C1C1E, dark: 0xF5F5F7)
    static let textSecondary = dynamic(light: 0x515156, dark: 0xC7C7CC)
    static let textTertiary = dynamic(light: 0x737378, dark: 0x98989F)

    static let edgeOuter = dynamic(light: 0x3C3C43, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.085)
    static let edgeOuterStrong = dynamic(light: 0x3C3C43, dark: 0xFFFFFF, lightAlpha: 0.28, darkAlpha: 0.16)
    static let edgeSeparator = dynamic(light: 0x3C3C43, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.10)
    static let shadowAmbient = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.34)

    static let accentPrimary = dynamic(light: 0x007AFF, dark: 0x0A84FF)
    static let accentIndigo = dynamic(light: 0x5856D6, dark: 0x5E5CE6)
    static let accentCyan = dynamic(light: 0x159FBE, dark: 0x50D2DF)
    static let accentPink = dynamic(light: 0xD856C7, dark: 0xF07ADE)
    static let ambientBlue = dynamic(light: 0x5B9DFF, dark: 0x247BDE)
    static let ambientIndigo = dynamic(light: 0x9B8CFF, dark: 0x6756C7)
    static let ambientMint = dynamic(light: 0x83D8CE, dark: 0x2E8D88)
    static let waiting = dynamic(light: 0x239B62, dark: 0x45D087)
    static let connected = dynamic(light: 0x1677E8, dark: 0x62AAFF)
    static let warning = dynamic(light: 0xC87512, dark: 0xFFB14A)
    static let danger = dynamic(light: 0xD64650, dark: 0xFF6B73)
    static let neutral = dynamic(light: 0x667389, dark: 0x97A4B6)

    static let accentGradient = LinearGradient(
        colors: [
            dynamic(light: 0x0A84FF, dark: 0x2997FF),
            dynamic(light: 0x007AFF, dark: 0x0A84FF)
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
