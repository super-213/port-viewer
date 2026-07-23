import SwiftUI

enum FrostedSurfaceKind {
    case chrome
    case content
    case raised
    case floating

    var tint: Color {
        switch self {
        case .chrome: PVPalette.surfaceBento
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
        case .chrome: .thinMaterial
        case .floating: .regularMaterial
        case .content, .raised: .ultraThinMaterial
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
                RadialGradient(
                    colors: [PVPalette.accentPrimary.opacity(0.055), .clear],
                    center: .topTrailing,
                    startRadius: 10,
                    endRadius: 440
                )
                RadialGradient(
                    colors: [PVPalette.accentIndigo.opacity(0.04), .clear],
                    center: .bottomLeading,
                    startRadius: 10,
                    endRadius: 520
                )
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
        let usesMaterial = !reduceTransparency && kind == .floating
        let outerEdge = contrast == .increased ? PVPalette.edgeOuterStrong : PVPalette.edgeOuter
        let ambientOpacity = controlActiveState == .inactive ? 0.45 : 1.0
        let tintOpacity = usesMaterial ? 0.46 : 0.0

        content
            .background {
                shape
                    .fill(usesMaterial ? AnyShapeStyle(kind.material) : AnyShapeStyle(kind.solidFallback))
                    .overlay { shape.fill(kind.tint.opacity(tintOpacity)) }
                    .overlay { shape.fill(kind == .floating ? Color.white.opacity(0.035) : .clear) }
            }
            .overlay {
                if showsOuterEdge && kind == .floating {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [PVPalette.edgeInnerHighlight, outerEdge.opacity(0.55), outerEdge],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: kind == .floating ? 1.25 : 1
                    )
                }
            }
            .overlay {
                if showsOuterEdge && kind == .floating {
                    shape
                        .inset(by: 1)
                        .strokeBorder(
                            LinearGradient(
                                colors: [PVPalette.edgeInnerHighlight.opacity(0.64), .clear, .clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 0.5
                        )
                }
            }
            .shadow(color: nearShadow(for: kind).opacity(ambientOpacity), radius: nearRadius(for: kind), y: nearY(for: kind))
            .shadow(
                color: ambientShadow(for: kind).opacity(ambientOpacity),
                radius: kind == .floating ? 22 : 14,
                y: kind == .floating ? 12 : 6
            )
    }

    private func nearShadow(for kind: FrostedSurfaceKind) -> Color {
        switch kind {
        case .chrome, .raised: return PVPalette.shadowNear.opacity(0.42)
        case .floating: return PVPalette.shadowNear
        case .content: return .clear
        }
    }

    private func ambientShadow(for kind: FrostedSurfaceKind) -> Color {
        switch kind {
        case .chrome: return PVPalette.shadowAmbient.opacity(0.055)
        case .raised: return PVPalette.shadowAmbient.opacity(0.09)
        case .floating: return PVPalette.shadowAmbient
        case .content: return .clear
        }
    }

    private func nearRadius(for kind: FrostedSurfaceKind) -> CGFloat { kind == .floating ? 5 : 2 }
    private func nearY(for kind: FrostedSurfaceKind) -> CGFloat { kind == .floating ? 2 : 1 }
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
        let edge = isSelected ? accent.opacity(0.65) : PVPalette.edgeOuterStrong
        let fill = isHovered ? PVPalette.surfaceBento : PVPalette.surfaceBento.opacity(0.92)
        let pressedTint = isPressed ? Color.black.opacity(0.04) : .clear

        content
            .background {
                shape
                    .fill(reduceTransparency ? PVPalette.surfaceRaised : fill)
                    .overlay { shape.fill(isSelected ? accent.opacity(0.11) : .clear) }
                    .overlay { shape.fill(pressedTint) }
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(edge, lineWidth: 1)
                }
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
            .shadow(color: PVPalette.shadowNear.opacity(isPressed ? 0.22 : 0.48), radius: isPressed ? 1 : 3, y: 1)
            .shadow(
                color: raised && !isPressed ? PVPalette.shadowAmbient.opacity(isHovered ? 0.15 : 0.10) : .clear,
                radius: 10,
                y: 5
            )
            .opacity(isEnabled ? 1 : 0.52)
            .offset(y: isPressed ? 0.5 : 0)
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
