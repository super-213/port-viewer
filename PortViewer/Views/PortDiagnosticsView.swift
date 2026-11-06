import SwiftUI

struct PortEventTimelineView: View {
    let history: PortEventHistory
    let item: ReadablePortItem
    @State private var showsAll = false

    var body: some View {
        let events = history.events(for: item).reversed().map { $0 }
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.string("端口事件时间线"), systemImage: "clock.arrow.circlepath")
                .font(.callout.weight(.semibold))
            Text(L10n.string("最近 30 分钟 · 本次会话 · 时间为采样观察时间"))
                .font(.caption).foregroundStyle(.secondary)
            if events.isEmpty {
                Text(L10n.string("尚未观察到变化；首次完整采样建立基线。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(showsAll ? events : Array(events.prefix(8))) { event in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(event.kind)).foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.observedAt, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(event.summary).font(.caption).textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(event.observedAt.formatted(date: .omitted, time: .standard) + " · " + event.summary)
            }
            if events.count > 8 {
                Button(L10n.string(showsAll ? "收起事件" : "显示全部事件")) { showsAll.toggle() }
                    .font(.caption)
            }
            if history.discardedEventCount > 0 {
                Text(L10n.string("事件达到容量上限，较早的事件已移除。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(_ kind: PortEvent.Kind) -> String {
        switch kind {
        case .appeared: "plus.circle"
        case .disappeared: "minus.circle"
        case .occupantsChanged: "person.2"
        case .scopeChanged: "network"
        case .interruption: "pause.circle"
        case .containerChanged: "shippingbox"
        }
    }
}

struct DockerStatusDetailsView: View {
    let portViewModel: PortViewModel
    let service: ManagedService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let snapshot = portViewModel.dockerStatus
            let known = portViewModel.dockerLastKnownStatus
            let current = snapshot?.serviceID == service.id ? snapshot : nil
            let lastKnown = known?.serviceID == service.id ? known : nil
            let stale = portViewModel.isPaused || (current.map { context.date.timeIntervalSince($0.observedAt) > 45 || $0.availability != .available } ?? true)
            VStack(alignment: .leading, spacing: 8) {
                Label("Docker", systemImage: "shippingbox").font(.callout.weight(.semibold))
                Text(service.name).font(.callout)
                if let current {
                    if current.availability == .removed {
                        Label(L10n.string("原容器已删除，重建后需重新关联"), systemImage: "minus.circle")
                    } else if current.availability == .unavailable {
                        Label(L10n.string("无法读取容器状态"), systemImage: "questionmark.circle")
                    }
                } else {
                    ProgressView(L10n.string("正在读取容器状态…")).controlSize(.small)
                }
                if let container = lastKnown?.container {
                    if stale {
                        Label(L10n.string("以下为上次观察结果，当前状态待确认"), systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(PVPalette.warning)
                    }
                    LabeledContent(L10n.string("生命周期"), value: lifecycleTitle(container.lifecycle))
                    LabeledContent(L10n.string("健康检查"), value: healthTitle(container))
                    if let count = container.restartCount {
                        LabeledContent(L10n.string("重启计数"), value: String(count))
                    }
                    if let startedAt = container.startedAt {
                        Text(L10n.format("启动时间 · %@", startedAt)).textSelection(.enabled)
                    }
                    if let observedAt = lastKnown?.observedAt {
                        Text(L10n.format("状态观测时间 · %@", observedAt.formatted(date: .omitted, time: .standard)))
                            .foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup(L10n.string("容器身份")) {
                    Text(service.target).textSelection(.enabled)
                    Text(service.endpoint).textSelection(.enabled)
                }
                Text(L10n.string("选中详情期间每 15 秒读取状态；运行状态、健康检查与端口监听分别观察。"))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func lifecycleTitle(_ value: String?) -> String {
        switch value {
        case "running": L10n.string("运行中")
        case "restarting": L10n.string("重启中")
        case "exited": L10n.string("已退出")
        case "paused": L10n.string("已暂停")
        case "created": L10n.string("已创建")
        case "dead": L10n.string("已停止（dead）")
        case "removing": L10n.string("删除中")
        default: value ?? L10n.string("未知")
        }
    }

    private func healthTitle(_ container: DockerContainerStatus) -> String {
        switch container.health {
        case "healthy": L10n.string("健康检查通过")
        case "unhealthy": L10n.string("健康检查未通过")
        case "starting": L10n.string("健康检查启动中")
        default: container.health ?? L10n.string(container.healthConfigured == false ? "未配置健康检查" : "健康状态未知")
        }
    }
}

/// Extra local relationships with their own evidence and observation times.
struct PortMappingTopologyView: View {
    let portViewModel: PortViewModel
    let item: ReadablePortItem
    let historical: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 10) {
                if !historical {
                    ForEach(portViewModel.tunnelAssociations(for: item.rawRecords, at: context.date)) { association in
                        path(source: association.route.hostname + (association.route.path.map { " · " + $0 } ?? ""),
                             target: association.route.service,
                             evidence: L10n.string("Tunnel 配置映射") + " · " + association.statusTitle,
                             uncertain: association.stale || association.ambiguous || association.connector.identity == nil)
                        if association.connector.identity == nil || association.ambiguous {
                            Text(L10n.string("映射候选，归属尚未唯一确认"))
                                .font(.caption).foregroundStyle(PVPalette.warning)
                        }
                    }
                    if let snapshot = portViewModel.dockerStatus,
                       snapshot.availability == .available,
                       context.date.timeIntervalSince(snapshot.observedAt) <= 45,
                       let container = snapshot.container,
                       item.rawRecords.contains(where: { $0.context.managedService?.id == snapshot.serviceID }) {
                        ForEach(container.mappings.filter { mapping in
                            item.rawRecords.contains { record in
                                guard let service = record.context.managedService else { return false }
                                let binding = ManagedServiceController.Binding(address: mapping.hostAddress, port: mapping.hostPort,
                                                                               transport: mapping.transport)
                                return ManagedServiceController.matches(record, container: .init(service: service, bindings: [binding]))
                            }
                        }, id: \.self) { mapping in
                            path(source: "\(mapping.hostAddress):\(mapping.hostPort)",
                                 target: "\(container.name) · \(mapping.containerPort)/\(mapping.transport.rawValue)",
                                 evidence: L10n.string("Docker 发布端口映射"), uncertain: false)
                        }
                        Text(L10n.format("映射观测时间 · %@", snapshot.observedAt.formatted(date: .omitted, time: .standard)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    let connections = observedConnections
                    ForEach(Array(connections.prefix(6)), id: \.self) { connection in
                        path(source: connection.remoteEndpoint, target: connection.localEndpoint,
                             evidence: L10n.string("已观察到的 TCP 连接"), uncertain: false)
                    }
                    if connections.count > 6 {
                        Text(L10n.format("另有 %lld 个连接端点", connections.count - 6)).font(.caption)
                    }
                }
                Text(L10n.string(historical ? "上方保留最后观察到的监听关系。" : "箭头说明连接或配置映射关系，实际可达性需单独验证。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var observedConnections: [PortRecord] {
        guard item.representative.isListening else { return [] }
        return portViewModel.records.filter { connection in
            connection.isActiveConnection && item.rawRecords.contains { listener in
                listener.context.identity != nil && listener.context.identity == connection.context.identity
                    && listener.localPort == connection.localPort && listener.ipVersion == connection.ipVersion
                    && (["*", "0.0.0.0", "::"].contains(listener.localAddress) || listener.localAddress == connection.localAddress)
            }
        }.sorted { $0.id < $1.id }
    }

    private func path(source: String, target: String, evidence: String, uncertain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(evidence).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 8) {
                Text(source).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: uncertain ? "questionmark" : "arrow.right").foregroundStyle(.secondary)
                Text(target).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.monospaced()).textSelection(.enabled)
            .padding(8)
            .background(PVPalette.surfaceControl, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                PVPalette.edgeOuter, style: StrokeStyle(lineWidth: 1, dash: uncertain ? [3, 3] : [])))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(evidence + " · " + source + " → " + target)
    }
}
