import Foundation

enum TunnelDefaults {
    static let endpoint = "http://127.0.0.1:20241"

    static func resolvedEndpoint(_ savedEndpoint: String?) -> String {
        let value = savedEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? endpoint : value
    }
}

enum TunnelConnectionState: String, Sendable {
    case connected, disconnected, unknown

    var title: String {
        switch self {
        case .connected: L10n.string("隧道已连接")
        case .disconnected: L10n.string("隧道未连接")
        case .unknown: L10n.string("连接状态未知")
        }
    }
}

struct TunnelRoute: Hashable, Sendable, Identifiable {
    let hostname: String
    let path: String?
    let service: String
    let order: Int
    let shadowed: Bool

    var id: String { "\(order)|\(hostname)|\(path ?? "")|\(service)" }
    var target: URLComponents? { URLComponents(string: service) }
    var port: Int? {
        guard let target, ["http", "https"].contains(target.scheme) else { return nil }
        return target.port ?? (target.scheme == "https" ? 443 : 80)
    }
    var browserURL: URL? {
        guard !hostname.contains("*"), path == nil,
              let port, port > 0 else { return nil }
        return URL(string: "https://\(hostname)")
    }

    static func validHostname(_ hostname: String) -> Bool {
        let value = hostname.hasPrefix("*.") ? String(hostname.dropFirst(2)) : hostname
        guard value.count <= 253, value.contains("."), !value.hasSuffix(".") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

struct TunnelConnector: Hashable, Sendable, Identifiable {
    let endpoint: URL
    let identity: ProcessIdentity?
    var routes: [TunnelRoute] = []
    var configVersion: Int?
    var connectorID: String?
    var state: TunnelConnectionState = .unknown
    var readyConnections = 0
    var observedAt: Date?
    var routesObservedAt: Date?
    var issue: String?
    var id: String { endpoint.absoluteString }

    func isStale(at date: Date, maximumAge: TimeInterval) -> Bool {
        guard let observedAt else { return false }
        return date.timeIntervalSince(observedAt) > maximumAge
    }
}

struct TunnelAssociation: Identifiable, Sendable {
    let connector: TunnelConnector
    let route: TunnelRoute
    let ambiguous: Bool
    let stale: Bool
    var id: String { connector.id + "|" + route.id }
    var statusTitle: String {
        if stale { return L10n.string("数据已过期") }
        return connector.state.title
    }
}

struct TunnelSnapshot: Sendable {
    var connectors: [TunnelConnector] = []
    var capturedAt = Date()
    static let empty = TunnelSnapshot()

    func associations(for records: [PortRecord], at date: Date, maximumAge: TimeInterval) -> [TunnelAssociation] {
        connectors.flatMap { connector in
            connector.routes.compactMap { route in
                guard !route.shadowed else { return nil }
                let matched = records.filter { TunnelMatching.matches(route, record: $0) }
                guard !matched.isEmpty else { return nil }
                // localhost can select either address family. Do not assign a unique owner.
                let ambiguous = route.target?.host == "localhost"
                    || Set(matched.compactMap(\.context.identity)).count > 1
                let routesStale = connector.routesObservedAt.map { date.timeIntervalSince($0) > maximumAge } ?? true
                return TunnelAssociation(connector: connector, route: route, ambiguous: ambiguous,
                                         stale: routesStale || connector.isStale(at: date, maximumAge: maximumAge))
            }
        }.sorted { ($0.route.port ?? 0, $0.route.hostname, $0.id) < ($1.route.port ?? 0, $1.route.hostname, $1.id) }
    }
}

enum TunnelMatching {
    static func matches(_ route: TunnelRoute, record: PortRecord) -> Bool {
        guard record.isListening, record.context.identity != nil,
              route.port == record.localPort, let host = route.target?.host?.lowercased() else { return false }
        let hostValue = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let address = record.localAddress
        if hostValue == "localhost" {
            return (record.ipVersion == .v4 && ["127.0.0.1", "0.0.0.0", "*"].contains(address))
                || (record.ipVersion == .v6 && ["::1", "::", "*"].contains(address))
        }
        if hostValue == "127.0.0.1" {
            return record.ipVersion == .v4 && ["127.0.0.1", "0.0.0.0", "*"].contains(address)
        }
        if hostValue == "::1" {
            return record.ipVersion == .v6 && ["::1", "::", "*"].contains(address)
        }
        // Non-loopback origins require interface/namespace validation; do not guess.
        return false
    }
}

enum TunnelParser {
    private struct Configuration: Decodable {
        let version: Int?
        let config: IngressConfiguration
    }
    private struct IngressConfiguration: Decodable { let ingress: [Rule] }
    private struct Rule: Decodable { let hostname: String?; let path: String?; let service: String }
    private struct Quick: Decodable { let hostname: String }
    private struct Ready: Decodable { let status: Int; let readyConnections: Int; let connectorId: String? }

    static func configuration(_ data: Data, quickHostname: String?) throws -> (Int?, [TunnelRoute]) {
        let value = try JSONDecoder().decode(Configuration.self, from: data)
        guard value.config.ingress.count <= 1024 else { throw TunnelDiscoveryError.responseTooLarge }
        var routes: [TunnelRoute] = []
        var previous: [Rule] = []
        for (index, rule) in value.config.ingress.enumerated() {
            defer { previous.append(rule) }
            let hostname = ((rule.hostname?.isEmpty == false ? rule.hostname : quickHostname) ?? "").lowercased()
            guard TunnelRoute.validHostname(hostname), let components = URLComponents(string: rule.service),
                  components.user == nil, components.password == nil, components.query == nil,
                  components.fragment == nil, let host = components.host, !host.isEmpty,
                  ["http", "https"].contains(components.scheme),
                  components.port.map({ (1...65535).contains($0) }) ?? true else { continue }
            let shadowed = previous.contains { prior in
                guard prior.path == nil || prior.path == rule.path else { return false }
                guard let priorHost = prior.hostname, !priorHost.isEmpty else { return true }
                return priorHost.lowercased() == hostname
                    || (priorHost.hasPrefix("*.") && hostname.hasSuffix(String(priorHost.dropFirst())))
            }
            routes.append(TunnelRoute(hostname: hostname, path: rule.path, service: rule.service,
                                      order: index, shadowed: shadowed))
        }
        return (value.version, routes)
    }

    static func quickHostname(_ data: Data) throws -> String? {
        let value = try JSONDecoder().decode(Quick.self, from: data).hostname.lowercased()
        return TunnelRoute.validHostname(value) ? value : nil
    }

    static func readiness(_ data: Data, httpStatus: Int) throws -> (TunnelConnectionState, Int, String?) {
        let value = try JSONDecoder().decode(Ready.self, from: data)
        guard value.status == httpStatus, value.readyConnections >= 0,
              (httpStatus == 200 && value.readyConnections > 0) || (httpStatus == 503 && value.readyConnections == 0)
        else { throw TunnelDiscoveryError.invalidResponse }
        return (httpStatus == 200 ? .connected : .disconnected, value.readyConnections, value.connectorId)
    }
}
