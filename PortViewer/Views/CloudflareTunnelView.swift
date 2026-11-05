import AppKit
import SwiftUI

struct TunnelSummaryView: View {
    let portViewModel: PortViewModel
    let records: [PortRecord]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let associations = portViewModel.tunnelAssociations(for: records, at: context.date)
            if let first = associations.first {
                let titles = Set(associations.map(\.statusTitle))
                let status = titles.count == 1 ? first.statusTitle : L10n.string("状态不一")
                let domains = Set(associations.map(\.route.hostname))
                let suffix = domains.count > 1 ? " +\(domains.count - 1)" : ""
                Label("Cloudflare · \(first.route.hostname)\(suffix) · \(status)", systemImage: "cloud")
                    .font(.caption2)
                    .foregroundStyle(PVPalette.textSecondary)
                    .lineLimit(1)
                    .help(L10n.string("隧道连接状态不代表公网访问已验证"))
            }
        }
    }
}

struct TunnelDetailsView: View {
    let portViewModel: PortViewModel
    let records: [PortRecord]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let associations = portViewModel.tunnelAssociations(for: records, at: context.date)
            if !associations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Cloudflare Tunnel", systemImage: "cloud")
                        .font(.callout.weight(.semibold))
                    ForEach(associations) { association in
                        routeDetails(association)
                    }
                    Text(L10n.string("公网访问未检测；隧道已连接不代表源站或域名可用。"))
                        .font(.caption)
                        .foregroundStyle(PVPalette.textSecondary)
                }
                .textSelection(.enabled)
                Divider()
            }
        }
    }

    private func routeDetails(_ association: TunnelAssociation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(association.route.hostname).font(.callout.weight(.medium))
            Text(association.route.service).font(.caption.monospaced())
            Label(association.statusTitle,
                  systemImage: association.stale || association.connector.state == .unknown
                    ? "questionmark.circle" : association.connector.state == .connected ? "checkmark.circle" : "xmark.circle")
                .font(.caption)
            if let path = association.route.path {
                Text(L10n.format("路径规则：%@", path)).font(.caption)
                Text(L10n.string("路径匹配受 ingress 规则顺序限制")).font(.caption)
            }
            if association.ambiguous {
                Text(L10n.string("地址或监听者可能有多个候选，未确认唯一归属"))
                    .font(.caption).foregroundStyle(PVPalette.warning)
            }
            if association.connector.identity == nil {
                Text(L10n.string("端点可读，进程归属未确认"))
                    .font(.caption).foregroundStyle(PVPalette.warning)
            }
            if let issue = association.connector.issue {
                Text(L10n.string(issue)).font(.caption).foregroundStyle(PVPalette.warning)
            }
            HStack {
                Button(L10n.string("复制域名")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(association.route.hostname, forType: .string)
                }
                if let url = association.route.browserURL {
                    Link(L10n.string("打开域名"), destination: url)
                }
            }
            .font(.caption)
            DisclosureGroup(L10n.string("隧道技术信息")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(association.connector.endpoint.absoluteString)
                    if let identity = association.connector.identity { Text("PID \(identity.pid)") }
                    if let version = association.connector.configVersion {
                        Text(L10n.format("配置版本：%lld", version))
                    }
                    if let date = association.connector.routesObservedAt {
                        Text(L10n.format("映射观测时间：%@", date.formatted(date: .omitted, time: .standard)))
                    }
                    if let date = association.connector.observedAt {
                        Text(L10n.format("状态观测时间：%@", date.formatted(date: .omitted, time: .standard)))
                    }
                    Text(L10n.string("来源：本机运行接口"))
                }
                .font(.caption).foregroundStyle(PVPalette.textSecondary)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
