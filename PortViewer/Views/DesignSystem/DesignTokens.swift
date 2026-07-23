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
    static let hover = Animation.easeOut(duration: 0.16)
    static let focus = Animation.easeOut(duration: 0.18)
    static let reveal = Animation.easeOut(duration: 0.24)
    static let selection = Animation.easeInOut(duration: 0.22)
}

enum PVPalette {
    static let canvasBase = dynamic(light: 0xE7E7EA, dark: 0x262628)
    static let canvasTop = dynamic(light: 0xF4F4F5, dark: 0x323236)
    static let canvasBottom = dynamic(light: 0xD8D8DC, dark: 0x1D1D1F)

    static let surfaceGlass = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.42, darkAlpha: 0.13)
    static let surfaceContent = dynamic(light: 0xECECEF, dark: 0x242426, lightAlpha: 0.70, darkAlpha: 0.56)
    static let surfaceControl = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.46, darkAlpha: 0.075)
    static let surfaceControlHover = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.60, darkAlpha: 0.13)
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.60, darkAlpha: 0.10)
    static let surfaceBento = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.50, darkAlpha: 0.08)

    static let textPrimary = dynamic(light: 0x16213A, dark: 0xF7F8FF)
    static let textSecondary = dynamic(light: 0x465571, dark: 0xC3CAE0)
    static let textTertiary = dynamic(light: 0x65718A, dark: 0x98A3BD)

    static let edgeOuter = dynamic(light: 0x60708F, dark: 0xFFFFFF, lightAlpha: 0.20, darkAlpha: 0.11)
    static let edgeOuterStrong = dynamic(light: 0x536481, dark: 0xFFFFFF, lightAlpha: 0.34, darkAlpha: 0.20)
    static let edgeSeparator = dynamic(light: 0x52617D, dark: 0xDCE4FA, lightAlpha: 0.17, darkAlpha: 0.14)
    static let shadowAmbient = dynamic(light: 0x42559A, dark: 0x000000, lightAlpha: 0.16, darkAlpha: 0.42)

    static let accentPrimary = dynamic(light: 0x287CFF, dark: 0x63A8FF)
    static let accentIndigo = dynamic(light: 0x7157E8, dark: 0x9685FF)
    static let accentCyan = dynamic(light: 0x159FBE, dark: 0x50D2DF)
    static let accentPink = dynamic(light: 0xD856C7, dark: 0xF07ADE)
    static let waiting = dynamic(light: 0x239B62, dark: 0x45D087)
    static let connected = dynamic(light: 0x1677E8, dark: 0x62AAFF)
    static let warning = dynamic(light: 0xC87512, dark: 0xFFB14A)
    static let danger = dynamic(light: 0xD64650, dark: 0xFF6B73)
    static let neutral = dynamic(light: 0x667389, dark: 0x97A4B6)

    static let accentGradient = LinearGradient(
        colors: [
            dynamic(light: 0x318BFF, dark: 0x62B0FF),
            dynamic(light: 0x7357EA, dark: 0x8B7BFF)
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
