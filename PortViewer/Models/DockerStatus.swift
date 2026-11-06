import Foundation

struct DockerPortMapping: Hashable, Sendable {
    let hostAddress: String
    let hostPort: Int
    let containerPort: Int
    let transport: TransportProtocol
    var title: String {
        let address = hostAddress.contains(":") ? "[\(hostAddress)]" : hostAddress
        return "\(address):\(hostPort) → \(containerPort)/\(transport.rawValue)"
    }
}

struct DockerContainerStatus: Sendable {
    let containerID: String
    let name: String
    let lifecycle: String?
    let health: String?
    let healthConfigured: Bool?
    let startedAt: String?
    let restartCount: Int?
    let mappings: [DockerPortMapping]

    static func parse(_ data: Data, expectedID: String) throws -> DockerContainerStatus {
        struct Inspection: Decodable {
            let Id: String
            let Name: String?
            let State: StateInfo?
            let RestartCount: Int?
            let NetworkSettings: NetworkInfo?
            let Config: ConfigInfo?
            struct StateInfo: Decodable {
                let Status: String?
                let StartedAt: String?
                let Health: HealthInfo?
            }
            struct HealthInfo: Decodable { let Status: String? }
            struct ConfigInfo: Decodable { let Healthcheck: HealthcheckInfo? }
            struct HealthcheckInfo: Decodable { let Test: [String]? }
            struct NetworkInfo: Decodable { let Ports: [String: [Binding]?]? }
            struct Binding: Decodable { let HostIp: String; let HostPort: String }
        }
        let values = try JSONDecoder().decode([Inspection].self, from: data)
        guard values.count == 1, let value = values.first, value.Id == expectedID,
              ManagedServiceController.validContainerID(value.Id) else { throw ManagedServiceError.changed }
        let mappings = (value.NetworkSettings?.Ports ?? [:]).flatMap { key, bindings -> [DockerPortMapping] in
            let parts = key.split(separator: "/")
            guard parts.count == 2, let port = Int(parts[0]), (1...65535).contains(port),
                  let transport = TransportProtocol(rawValue: parts[1].uppercased()) else { return [] }
            return (bindings ?? []).compactMap { binding in
                guard let hostPort = Int(binding.HostPort), (1...65535).contains(hostPort) else { return nil }
                return .init(hostAddress: binding.HostIp, hostPort: hostPort, containerPort: port, transport: transport)
            }
        }.sorted { $0.title < $1.title }
        let healthConfigured: Bool?
        if value.State?.Health != nil { healthConfigured = true }
        else if let config = value.Config {
            healthConfigured = config.Healthcheck?.Test.map { !$0.isEmpty && $0.first != "NONE" } ?? false
        } else { healthConfigured = nil }
        return .init(containerID: value.Id, name: value.Name?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? value.Id,
                     lifecycle: value.State?.Status, health: value.State?.Health?.Status,
                     healthConfigured: healthConfigured, startedAt: value.State?.StartedAt,
                     restartCount: value.RestartCount.flatMap { $0 >= 0 ? $0 : nil }, mappings: mappings)
    }
}

struct DockerStatusSnapshot: Sendable {
    enum Availability: Sendable { case available, removed, unavailable }
    let serviceID: String
    let observedAt: Date
    let availability: Availability
    let container: DockerContainerStatus?
}
