import SwiftUI

struct PortActivityMap: View {
    let buckets: [PortMapBucket]
    let itemCount: Int
    let selectedID: ReadablePortItem.ID?
    let onSelect: (ReadablePortItem) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 12, maximum: 24), spacing: 5),
        count: 32
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Label("端口地图", systemImage: "square.grid.3x3.fill")
                    .font(.headline)
                    .foregroundStyle(PVPalette.textPrimary)

                Spacer(minLength: 12)

                legend("等待", color: PVPalette.waiting)
                legend("连接", color: PVPalette.connected)
                legend("其他", color: PVPalette.neutral)
                legend("混合", color: PVPalette.accentIndigo)
            }

            LazyVGrid(columns: columns, alignment: .center, spacing: 5) {
                ForEach(buckets) { bucket in
                    PortMapCell(
                        bucket: bucket,
                        isSelected: bucket.items.contains { $0.id == selectedID },
                        onSelect: onSelect
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Text("0")
                Spacer()
                Text("每格 \(PortMapLayout.bucketSize) 个端口")
                Spacer()
                Text("65,535")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(PVPalette.textTertiary)
        }
        .help("从左到右固定映射 0 到 65,535。每个格子代表 512 个连续端口；有边缘高亮的格子表示当前筛选条件下存在活动。")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("端口地图，共 \(itemCount) 项可见活动")
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(color.opacity(0.86), lineWidth: 1)
                }
                .frame(width: 11, height: 11)
            Text(title)
                .font(.callout)
                .foregroundStyle(PVPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PortMapCell: View {
    let bucket: PortMapBucket
    let isSelected: Bool
    let onSelect: (ReadablePortItem) -> Void

    @State private var isHovered = false
    @State private var showsPicker = false

    private var isActive: Bool { !bucket.items.isEmpty }
    private var activityClass: PortMapActivityClass? {
        let classes = Set(bucket.items.map(PortMapActivityClass.init(item:)))
        guard classes.count == 1 else { return classes.isEmpty ? nil : .mixed }
        return classes.first
    }
    private var color: Color { activityClass?.color ?? PVPalette.neutral }
    private var intensity: Double {
        min(0.12 + Double(max(0, bucket.items.count - 1)) * 0.025, 0.26)
    }

    var body: some View {
        Group {
            if isActive {
                Button(action: activate) {
                    cellShape
                }
                .buttonStyle(PortMapCellButtonStyle())
                .onHover { hovering in
                    isHovered = hovering
                }
                .help(helpText)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint(bucket.items.count == 1 ? "打开这项活动的详情" : "打开此区间的活动列表")
                .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                    PortMapBucketPopover(
                        bucket: bucket,
                        onSelect: { item in
                            showsPicker = false
                            onSelect(item)
                        }
                    )
                }
            } else {
                cellShape
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var cellShape: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return shape
            .fill(
                isActive
                    ? color.opacity(isHovered ? min(intensity + 0.09, 0.34) : intensity)
                    : PVPalette.surfaceControl.opacity(0.34)
            )
            .overlay {
                shape.strokeBorder(
                    isSelected
                        ? PVPalette.accentPrimary
                        : isActive
                            ? color.opacity(isHovered ? 1 : 0.82)
                            : PVPalette.edgeOuter.opacity(0.70),
                    lineWidth: isSelected ? 2 : isActive ? 1.15 : 0.65
                )
            }
            .overlay(alignment: .topTrailing) {
                if bucket.items.count > 1 {
                    Circle()
                        .fill(color)
                        .frame(width: 4, height: 4)
                        .padding(2)
                }
            }
            .shadow(
                color: isSelected ? PVPalette.accentPrimary.opacity(0.24) : .clear,
                radius: 4
            )
            .contentShape(shape)
    }

    private func activate() {
        if bucket.items.count == 1, let item = bucket.items.first {
            onSelect(item)
        } else {
            showsPicker = true
        }
    }

    private var helpText: String {
        "端口 \(bucket.rangeDescription) · \(bucket.items.count) 项活动 · \(portSummary)"
    }

    private var accessibilityText: String {
        "端口区间 \(bucket.rangeDescription)，\(activityClass?.title ?? "无")，\(bucket.items.count) 项活动"
    }

    private var portSummary: String {
        let ports = bucket.ports
        guard !ports.isEmpty else { return "没有活动" }
        let visible = ports.prefix(6).map(String.init).joined(separator: "、")
        return ports.count > 6 ? "端口 \(visible) 等" : "端口 \(visible)"
    }
}

private enum PortMapActivityClass: Hashable {
    case waiting
    case connected
    case other
    case mixed

    init(item: ReadablePortItem) {
        switch item.activityKind {
        case .waiting:
            self = .waiting
        case .connected, .transitioning:
            self = .connected
        case .other:
            self = .other
        }
    }

    var title: String {
        switch self {
        case .waiting: "等待连接"
        case .connected: "连接活动"
        case .other: "其他网络活动"
        case .mixed: "混合活动"
        }
    }

    var color: Color {
        switch self {
        case .waiting: PVPalette.waiting
        case .connected: PVPalette.connected
        case .other: PVPalette.neutral
        case .mixed: PVPalette.accentIndigo
        }
    }
}

private struct PortMapCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            label
                .scaleEffect(isPressed && !reduceMotion ? 0.88 : 1)
                .opacity(isPressed ? 0.78 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: isPressed)
        }
    }
}

private struct PortMapBucketPopover: View {
    let bucket: PortMapBucket
    let onSelect: (ReadablePortItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("端口 \(bucket.rangeDescription)")
                        .font(.headline)
                    Text("\(bucket.items.count) 项活动")
                        .font(.callout)
                        .foregroundStyle(PVPalette.textSecondary)
                }
                Spacer()
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(PVPalette.accentPrimary)
            }

            PremiumSeparator()

            ForEach(bucket.items.prefix(8)) { item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 10) {
                        Text(portText(for: item))
                            .font(.system(.callout, design: .monospaced, weight: .semibold))
                            .foregroundStyle(color(for: item))
                            .frame(width: 78, alignment: .leading)
                        ProcessIconView(record: item.representative, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.processName)
                                .foregroundStyle(PVPalette.textPrimary)
                                .lineLimit(1)
                            Text(item.friendlyStatusTitle)
                                .font(.caption)
                                .foregroundStyle(PVPalette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PVPalette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle(size: 36, horizontalPadding: 8))
                .accessibilityHint("在主列表中选择这项活动")
            }

            if bucket.items.count > 8 {
                Text("另有 \(bucket.items.count - 8) 项，请在主列表中查看")
                    .font(.callout)
                    .foregroundStyle(PVPalette.textSecondary)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .frostedSurface(.floating, radius: PVRadius.floating)
    }

    private func portText(for item: ReadablePortItem) -> String {
        let ports = item.localPorts.filter { bucket.lowerBound...bucket.upperBound ~= $0 }
        guard let first = ports.first else { return "—" }
        return ports.count > 1 ? ":\(first) +\(ports.count - 1)" : ":\(first)"
    }

    private func color(for item: ReadablePortItem) -> Color {
        PortMapActivityClass(item: item).color
    }
}
