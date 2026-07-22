import Foundation

enum PortQueryPolicy: Sendable, Equatable {
    case reuseInFlight
    case fresh
}

protocol PortQuerying: Sendable {
    func query(policy: PortQueryPolicy) async throws -> PortSnapshot
    func cancelCurrentQuery() async
}

extension PortQuerying {
    func query() async throws -> PortSnapshot {
        try await query(policy: .reuseInFlight)
    }

    func cancelCurrentQuery() async {}
}
