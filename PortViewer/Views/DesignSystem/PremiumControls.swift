import SwiftUI

struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        AccentButtonBody(label: configuration.label, isPressed: configuration.isPressed, height: height)
    }

    private struct AccentButtonBody<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: height)
                .background(PVPalette.accentGradient, in: RoundedRectangle(cornerRadius: PVRadius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PVRadius.control, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
                }
                .shadow(color: PVPalette.accentPrimary.opacity(isPressed ? 0.02 : 0.10), radius: 8, y: 4)
                .opacity(isEnabled ? (isPressed ? 0.88 : 1) : 0.50)
                .offset(y: isPressed ? 0.5 : 0)
        }
    }
}

struct GlassButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = 11

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            height: height,
            horizontalPadding: horizontalPadding
        )
    }

    private struct GlassButtonBody<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let height: CGFloat
        let horizontalPadding: CGFloat
        @State private var isHovered = false

        var body: some View {
            label
                .font(.callout.weight(.medium))
                .foregroundStyle(PVPalette.textPrimary)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: height)
                .premiumControlSurface(isHovered: isHovered, isPressed: isPressed)
                .contentShape(RoundedRectangle(cornerRadius: PVRadius.control, style: .continuous))
                .onHover { hovering in
                    withAnimation(PVMotion.hover) { isHovered = hovering }
                }
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var horizontalPadding: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            size: size,
            horizontalPadding: horizontalPadding
        )
    }

    private struct QuietButtonBody<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let size: CGFloat
        let horizontalPadding: CGFloat
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .font(.callout.weight(.medium))
                .foregroundStyle(PVPalette.textSecondary)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: size, minHeight: size)
                .background(
                    (isHovered ? PVPalette.textPrimary.opacity(0.065) : Color.clear),
                    in: RoundedRectangle(cornerRadius: PVRadius.small, style: .continuous)
                )
                .opacity(isEnabled ? (isPressed ? 0.70 : 1) : 0.48)
                .offset(y: isPressed ? 0.5 : 0)
                .contentShape(RoundedRectangle(cornerRadius: PVRadius.small, style: .continuous))
                .onHover { hovering in
                    withAnimation(PVMotion.hover) { isHovered = hovering }
                }
        }
    }
}

struct DangerButtonStyle: ButtonStyle {
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        DangerButtonBody(label: configuration.label, isPressed: configuration.isPressed, height: height)
    }

    private struct DangerButtonBody<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let height: CGFloat
        @State private var isHovered = false

        var body: some View {
            label
                .font(.callout.weight(.medium))
                .foregroundStyle(PVPalette.danger)
                .padding(.horizontal, 11)
                .frame(minHeight: height)
                .premiumControlSurface(
                    isHovered: isHovered,
                    isPressed: isPressed,
                    isSelected: true,
                    accent: PVPalette.danger
                )
                .onHover { hovering in
                    withAnimation(PVMotion.hover) { isHovered = hovering }
                }
        }
    }
}

struct FilterChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FilterChipBody(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct FilterChipBody<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @State private var isHovered = false

        var body: some View {
            label
                .font(.caption.weight(.medium))
                .foregroundStyle(PVPalette.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .premiumControlSurface(
                    radius: 8,
                    isHovered: isHovered,
                    isPressed: isPressed,
                    isSelected: true,
                    accent: PVPalette.accentPrimary
                )
                .onHover { hovering in
                    withAnimation(PVMotion.hover) { isHovered = hovering }
                }
        }
    }
}

struct PremiumPicker<Option: Hashable>: View {
    let title: String
    let symbol: String?
    let options: [Option]
    @Binding var selection: Option
    let optionText: (Option) -> String

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        symbol: String? = nil,
        options: [Option],
        selection: Binding<Option>,
        optionText: @escaping (Option) -> String
    ) {
        self.title = title
        self.symbol = symbol
        self.options = options
        _selection = selection
        self.optionText = optionText
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if selection == option {
                        Label(optionText(option), systemImage: "checkmark")
                    } else {
                        Text(optionText(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PVPalette.textSecondary)
                }
                Text(optionText(selection))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PVPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 5)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PVPalette.textSecondary)
                    .frame(width: 20, height: 22)
                    .background(PVPalette.textPrimary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .frame(height: 32)
            .premiumControlSurface(isHovered: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: PVRadius.control, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering in
            withAnimation(PVMotion.hover) { isHovered = hovering }
        }
        .opacity(isEnabled ? 1 : 0.52)
        .accessibilityLabel(title)
        .accessibilityValue(optionText(selection))
    }
}

struct PremiumSearchField: View {
    @Binding var text: String
    let prompt: String
    var compact = false
    var focusRequest: Binding<Bool> = .constant(false)

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? PVPalette.accentPrimary : PVPalette.textSecondary)
                .frame(width: 16)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .foregroundStyle(PVPalette.textPrimary)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(QuietButtonStyle(size: 20, horizontalPadding: 0))
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: compact ? 30 : 32)
        .premiumControlSurface(isHovered: isHovered, isFocused: isFocused)
        .onHover { hovering in
            withAnimation(PVMotion.hover) { isHovered = hovering }
        }
        .onChange(of: focusRequest.wrappedValue) { _, requested in
            if requested { isFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { focusRequest.wrappedValue = false }
        }
        .animation(PVMotion.focus, value: isFocused)
    }
}
