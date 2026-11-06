import SwiftUI

/// A compact reading of the same relationship shown in the inspector.
/// Arrows describe socket relationships, not live packet direction or throughput.
struct CompactTopologyView: View {
    let item: ReadablePortItem
    let listenerProcessCount: Int

    private var isListening: Bool { item.representative.isListening }
    private var portColor: Color { isListening ? PVPalette.waiting : PVPalette.connected }

    var body: some View {
        HStack(spacing: 5) {
            if isListening {
                node(item.serviceConnections.isEmpty ? sourceTitle : L10n.format("%lld 条接入连接", item.serviceConnections.count), symbol: item.serviceConnections.isEmpty ? sourceSymbol : "person.2")
                connector(bidirectional: !item.serviceConnections.isEmpty, dashed: item.serviceConnections.isEmpty && item.accessScope != .localOnly)
                portNode
                connector()
                node(
                    listenerProcessCount > 1
                        ? L10n.format("%lld 个进程", listenerProcessCount)
                        : item.processName,
                    symbol: listenerProcessCount > 1 ? "person.2" : "app"
                )
            } else {
                node(item.serviceName ?? item.processName, symbol: "app")
                connector(bidirectional: true)
                portNode
                connector(bidirectional: true, dashed: item.representative.remoteAddress == nil)
                node(targetTitle, symbol: item.remoteTargetCount > 0 ? "network" : "questionmark.circle")
            }
        }
        .help(item.textualRelationshipDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.textualRelationshipDescription)
    }

    private var portNode: some View {
        VStack(spacing: 3) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 12))
                .foregroundStyle(portColor)
            Text(portTitle)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(minWidth: 52)
        .background(portColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
    }

    private func node(_ title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minWidth: 48, maxWidth: .infinity)
    }

    private func connector(bidirectional: Bool = false, dashed: Bool = false) -> some View {
        HStack(spacing: 0) {
            if bidirectional {
                Image(systemName: "arrowtriangle.left.fill")
                    .font(.system(size: 5))
            }
            Path { path in
                path.move(to: CGPoint(x: 0, y: 3))
                path.addLine(to: CGPoint(x: 14, y: 3))
            }
            .stroke(style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : []))
            .frame(width: 14, height: 6)
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 5))
        }
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }

    private var portTitle: String {
        guard let port = item.localPorts.first else { return "*" }
        let suffix = item.localPorts.count > 1 ? " +\(item.localPorts.count - 1)" : ""
        return ":\(port)" + suffix
    }

    private var sourceTitle: String {
        switch item.accessScope {
        case .localOnly: return L10n.string("仅本机")
        case .networkPossible: return L10n.string("本机/网络")
        case .unknown: return L10n.string("来源未知")
        }
    }

    private var sourceSymbol: String {
        switch item.accessScope {
        case .localOnly: return "laptopcomputer"
        case .networkPossible: return "network"
        case .unknown: return "questionmark.circle"
        }
    }

    private var targetTitle: String {
        if item.serviceName != nil {
            return item.remoteTargetCount > 1 ? L10n.format("%lld 个客户端端点", item.remoteTargetCount) : item.remoteEndpoints.first ?? L10n.string("客户端")
        }
        if item.remoteTargetCount > 1 {
            return L10n.format("%lld 个目标", item.remoteTargetCount)
        }
        return item.remoteEndpoints.first
            ?? L10n.string(item.transport == .udp ? "对象不固定" : "连接对象未知")
    }
}
