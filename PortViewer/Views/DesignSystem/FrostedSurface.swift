import SwiftUI

enum FrostedSurfaceKind {
    case chrome
    case content
    case raised
    case floating

    var background: Color {
        switch self {
        case .chrome, .raised: PVPalette.surfaceBento
        case .content: PVPalette.surfaceContent
        case .floating: PVPalette.surfaceRaised
        }
    }
}

struct PremiumCanvas: View {
    var body: some View {
        PVPalette.canvasBase
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

// Keep shared surface call sites, with opaque, neutral fills throughout the app.
private struct FrostedSurfaceModifier: ViewModifier {
    let kind: FrostedSurfaceKind
    let radius: CGFloat
    let showsOuterEdge: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(kind.background, in: shape)
            .overlay {
                if showsOuterEdge {
                    shape.strokeBorder(
                        contrast == .increased ? PVPalette.edgeOuterStrong : PVPalette.edgeOuter,
                        lineWidth: 1
                    )
                }
            }
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
                        AnyShapeStyle(PVPalette.surfaceRaised)
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
