import SwiftUI

enum FrostedSurfaceKind {
    case chrome
    case content
    case raised
    case floating

    var tint: Color {
        switch self {
        case .chrome: PVPalette.surfaceGlass
        case .content: PVPalette.surfaceContent
        case .raised: PVPalette.surfaceBento
        case .floating: PVPalette.surfaceRaised
        }
    }

    var solidFallback: Color {
        switch self {
        case .chrome, .raised: PVPalette.surfaceBento
        case .content: PVPalette.surfaceContent
        case .floating: PVPalette.surfaceRaised
        }
    }

    var material: Material {
        switch self {
        case .chrome: .regularMaterial
        case .content: .thickMaterial
        case .raised: .thinMaterial
        case .floating: .ultraThickMaterial
        }
    }

    var tintOpacity: Double {
        switch self {
        case .chrome: 0.36
        case .content: 0.30
        case .raised: 0.24
        case .floating: 0.38
        }
    }
}

struct PremiumCanvas: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PVPalette.canvasTop, PVPalette.canvasBase, PVPalette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            if !reduceTransparency {
                Circle()
                    .fill(PVPalette.ambientBlue.opacity(0.24))
                    .frame(width: 560, height: 560)
                    .blur(radius: 110)
                    .offset(x: 420, y: -300)

                RoundedRectangle(cornerRadius: 180, style: .continuous)
                    .fill(PVPalette.ambientIndigo.opacity(0.18))
                    .frame(width: 640, height: 360)
                    .rotationEffect(.degrees(-12))
                    .blur(radius: 120)
                    .offset(x: -360, y: 330)

                Circle()
                    .fill(PVPalette.ambientMint.opacity(0.11))
                    .frame(width: 420, height: 420)
                    .blur(radius: 100)
                    .offset(x: 340, y: 380)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct FrostedSurfaceModifier: ViewModifier {
    let kind: FrostedSurfaceKind
    let radius: CGFloat
    let showsOuterEdge: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let usesMaterial = !reduceTransparency
        let outerEdge = contrast == .increased ? PVPalette.edgeOuterStrong : PVPalette.edgeOuter
        let ambientOpacity = controlActiveState == .inactive ? 0.45 : 1.0

        content
            .background {
                shape
                    .fill(usesMaterial ? AnyShapeStyle(kind.material) : AnyShapeStyle(kind.solidFallback))
                    .overlay { shape.fill(kind.tint.opacity(usesMaterial ? kind.tintOpacity : 1)) }
            }
            .overlay {
                if showsOuterEdge {
                    shape.strokeBorder(outerEdge, lineWidth: 0.75)
                }
            }
            .overlay {
                if showsOuterEdge && !reduceTransparency {
                    shape
                        .inset(by: 1)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.24), Color.white.opacity(0.025)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            }
            .shadow(
                color: kind == .floating || kind == .content
                    ? PVPalette.shadowAmbient.opacity((kind == .floating ? 0.34 : 0.13) * ambientOpacity)
                    : .clear,
                radius: kind == .floating ? 22 : 12,
                y: kind == .floating ? 12 : 5
            )
    }
}

private struct PremiumControlSurfaceModifier: ViewModifier {
    let radius: CGFloat
    let isHovered: Bool
    let isPressed: Bool
    let isSelected: Bool
    let isFocused: Bool
    let accent: Color
    let raised: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let edge = isSelected ? accent.opacity(0.70) : PVPalette.edgeOuterStrong
        let fill = isHovered ? PVPalette.surfaceControlHover : PVPalette.surfaceControl
        let pressedTint = isPressed ? PVPalette.textPrimary.opacity(0.06) : .clear

        content
            .background {
                shape
                    .fill(
                        reduceTransparency
                            ? AnyShapeStyle(PVPalette.surfaceRaised)
                            : AnyShapeStyle(.thinMaterial)
                    )
                    .overlay { shape.fill(fill) }
                    .overlay { shape.fill(isSelected ? accent.opacity(0.11) : .clear) }
                    .overlay { shape.fill(pressedTint) }
            }
            .overlay {
                shape.strokeBorder(
                    edge.opacity(contrast == .increased ? 1 : 0.72),
                    lineWidth: contrast == .increased || isSelected ? 1 : 0.75
                )
            }
            .overlay {
                if isSelected {
                    shape.fill(accent.opacity(0.06))
                }
            }
            .overlay {
                if isFocused {
                    shape
                        .inset(by: -3)
                        .stroke(accent.opacity(0.82), lineWidth: 2)
                }
            }
            .overlay {
                if !reduceTransparency {
                    shape
                        .inset(by: 1)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.20), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            }
            .shadow(
                color: raised ? PVPalette.shadowAmbient.opacity(isPressed ? 0.05 : 0.11) : .clear,
                radius: raised ? 5 : 0,
                y: raised ? 2 : 0
            )
            .opacity(isEnabled ? (isPressed ? 0.88 : 1) : 0.52)
    }
}

struct PremiumSeparator: View {
    var body: some View {
        Rectangle()
            .fill(PVPalette.edgeSeparator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

extension View {
    func frostedSurface(
        _ kind: FrostedSurfaceKind,
        radius: CGFloat,
        showsOuterEdge: Bool = true
    ) -> some View {
        modifier(FrostedSurfaceModifier(kind: kind, radius: radius, showsOuterEdge: showsOuterEdge))
    }

    func premiumControlSurface(
        radius: CGFloat = PVRadius.control,
        isHovered: Bool = false,
        isPressed: Bool = false,
        isSelected: Bool = false,
        isFocused: Bool = false,
        accent: Color = PVPalette.accentPrimary,
        raised: Bool = false
    ) -> some View {
        modifier(PremiumControlSurfaceModifier(
            radius: radius,
            isHovered: isHovered,
            isPressed: isPressed,
            isSelected: isSelected,
            isFocused: isFocused,
            accent: accent,
            raised: raised
        ))
    }
}
