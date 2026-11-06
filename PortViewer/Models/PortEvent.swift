import Foundation

struct PortEvent: Identifiable, Sendable {
    enum Kind: Sendable { case appeared, disappeared, occupantsChanged, scopeChanged, interruption, containerChanged }
    let id = UUID()
    let observedAt: Date
    let kind: Kind
    let port: Int?
    let transport: TransportProtocol?
    let summary: String
}

/// Session-only observations. Complete samples establish continuity, never exact system event times.
struct PortEventHistory {
    private(set) var events: [PortEvent] = []
    private(set) var archivedListeners: [PortRecord] = []
    private(set) var discardedEventCount = 0
    private var baseline: [Endpoint: Set<Occupant>]?
    private var lastSampleAt: Date?
    private let lifetime: TimeInterval = 30 * 60
    private let capacity = 1_000

    private struct Endpoint: Hashable {
        let port: Int
        let address: String
        let version: IPVersion
        let transport: TransportProtocol
        init?(_ record: PortRecord) {
            guard record.isListening, let port = record.localPort else { return nil }
            self.port = port
            version = record.ipVersion
            transport = record.transport
            address = record.localAddress == "*" ? (version == .v6 ? "::" : "0.0.0.0") : record.localAddress
        }
        var title: String { "\(transport.rawValue) \(address.contains(":") ? "[\(address)]" : address):\(port)" }
    }

    private struct Occupant: Hashable {
        let identity: ProcessIdentity?
        let pid: Int32
        let name: String
        // Metadata enrichment can change labels without changing an occupant.
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity && lhs.pid == rhs.pid }
        func hash(into hasher: inout Hasher) { hasher.combine(identity); hasher.combine(pid) }
    }

    mutating func interrupt(at date: Date, reason: String) {
        guard baseline != nil else { return }
        baseline = nil
        lastSampleAt = nil
        append(.init(observedAt: date, kind: .interruption, port: nil, transport: nil, summary: reason))
    }

    mutating func observe(_ snapshot: PortSnapshot, maximumGap: TimeInterval = 120) {
        prune(at: snapshot.capturedAt)
        guard !snapshot.isPartial else {
            interrupt(at: snapshot.capturedAt, reason: L10n.string("采样中断 · 查询结果不完整"))
            return
        }
        if let lastSampleAt, snapshot.capturedAt.timeIntervalSince(lastSampleAt) > maximumGap {
            interrupt(at: snapshot.capturedAt, reason: L10n.string("采样中断 · 两次观察间隔过长"))
        }
        let listeners = snapshot.records.filter(\.isListening)
        var current: [Endpoint: Set<Occupant>] = [:]
        for record in listeners {
            guard let endpoint = Endpoint(record) else { continue }
            current[endpoint, default: []].insert(.init(identity: record.context.identity, pid: record.pid, name: record.displayName))
        }
        if let baseline {
            let endpoints = Set(baseline.keys).union(current.keys).sorted { $0.title < $1.title }
            for endpoint in endpoints {
                let old = baseline[endpoint] ?? []
                let new = current[endpoint] ?? []
                guard old != new else { continue }
                let kind: PortEvent.Kind = old.isEmpty ? .appeared : new.isEmpty ? .disappeared : .occupantsChanged
                let text: String
                if old.isEmpty {
                    text = L10n.format("新观察到监听 · %@ · %@", endpoint.title, labels(new))
                } else if new.isEmpty {
                    text = L10n.format("不再观察到监听 · %@ · %@", endpoint.title, labels(old))
                } else {
                    text = L10n.format("占用记录变化 · %@ · %@ → %@", endpoint.title, labels(old), labels(new))
                }
                append(.init(observedAt: snapshot.capturedAt, kind: kind, port: endpoint.port,
                             transport: endpoint.transport, summary: text))
            }
            // Address-set changes require the same verified process instance and port.
            for port in Set(current.keys.map(\.port)).sorted() {
                let identities = Set(current.filter { $0.key.port == port }.values.flatMap { $0 }.compactMap(\.identity))
                for identity in identities.sorted(by: { $0.pid < $1.pid }) {
                    let old = Set(baseline.filter { $0.key.port == port && $0.value.contains { $0.identity == identity } }.keys.map(\.title))
                    let new = Set(current.filter { $0.key.port == port && $0.value.contains { $0.identity == identity } }.keys.map(\.title))
                    if !old.isEmpty, old != new {
                        append(.init(observedAt: snapshot.capturedAt, kind: .scopeChanged, port: port, transport: .tcp,
                                     summary: L10n.format("监听地址集合变化 · PID %d · %@ → %@", identity.pid,
                                                          old.sorted().joined(separator: ", "), new.sorted().joined(separator: ", "))))
                    }
                }
            }
        }
        baseline = current
        lastSampleAt = snapshot.capturedAt
        // Keep bounded last-seen metadata for disappeared-port navigation. Strip command arguments.
        var archived = Dictionary(grouping: archivedListeners, by: archiveKey).compactMapValues(\.first)
        for record in listeners {
            var context = record.context
            context.arguments = []
            archived[archiveKey(record)] = record.withContext(context)
        }
        archivedListeners = Array(archived.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(512))
    }

    mutating func append(_ event: PortEvent) {
        events.append(event)
        prune(at: event.observedAt)
    }

    func events(for item: ReadablePortItem) -> [PortEvent] {
        let ports = Set(item.localPorts)
        return events.filter { $0.port == nil || ($0.transport == item.transport && $0.port.map(ports.contains) == true) }
    }

    private func labels(_ occupants: Set<Occupant>) -> String {
        occupants.sorted { $0.pid < $1.pid }.map {
            let label = "\($0.name) · PID \($0.pid)"
            return $0.identity == nil ? label + L10n.string("（归属待确认）") : label
        }.joined(separator: ", ")
    }

    private func archiveKey(_ record: PortRecord) -> String {
        "\(record.id)|\(record.context.identity?.startSeconds ?? 0)|\(record.context.identity?.startMicroseconds ?? 0)"
    }

    private mutating func prune(at date: Date) {
        let cutoff = date.addingTimeInterval(-lifetime)
        events.removeAll { $0.observedAt < cutoff }
        archivedListeners.removeAll { $0.updatedAt < cutoff }
        if events.count > capacity {
            discardedEventCount += events.count - capacity
            events.removeFirst(events.count - capacity)
        }
    }
}
