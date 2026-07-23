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
        case .chrome: .thinMaterial
        case .floating: .regularMaterial
        case .content, .raised: .ultraThinMaterial
        }
    }

    var tintOpacity: Double {
        switch self {
        case .chrome: 0.64
        case .content: 0.78
        case .raised: 0.58
        case .floating: 0.70
        }
    }
}

struct PremiumCanvas: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PVPalette.canvasTop, PVPalette.canvasBase, PVPalette.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if !reduceTransparency {
                RadialGradient(
                    colors: [Color.white.opacity(0.075), .clear],
                    center: UnitPoint(x: 0.22, y: 0.02),
                    startRadius: 0,
                    endRadius: 760
                )
                RadialGradient(
                    colors: [Color.black.opacity(0.11), .clear],
                    center: UnitPoint(x: 0.84, y: 0.98),
                    startRadius: 0,
                    endRadius: 900
                )
                Rectangle()
                    .fill(.ultraThinMaterial)
                PVPalette.canvasBase.opacity(0.22)
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
                    shape.strokeBorder(outerEdge, lineWidth: 1)
                }
            }
            .shadow(
                color: kind == .floating
                    ? PVPalette.shadowAmbient.opacity(0.46 * ambientOpacity)
                    : .clear,
                radius: 18,
                y: 10
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
                    .fill(reduceTransparency ? PVPalette.surfaceRaised : fill)
                    .overlay { shape.fill(isSelected ? accent.opacity(0.11) : .clear) }
                    .overlay { shape.fill(pressedTint) }
            }
            .overlay {
                shape.strokeBorder(
                    edge.opacity(contrast == .increased ? 1 : 0.66),
                    lineWidth: contrast == .increased || isSelected ? 1.2 : 1
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
