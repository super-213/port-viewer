import Foundation

enum TransportProtocol: String, CaseIterable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

enum IPVersion: String, CaseIterable, Sendable {
    case v4 = "IPv4"
    case v6 = "IPv6"
    case unknown = "未知"
}

struct PortRecord: Identifiable, Hashable, Sendable {
    let processName: String
    let pid: Int32
    let user: String
    let fileDescriptor: String
    let ipVersion: IPVersion
    let transport: TransportProtocol
    let localAddress: String
    let localPort: Int?
    let remoteAddress: String?
    let remotePort: Int?
    let state: String?
    let executablePath: String?
    let parentPID: Int32?
    let updatedAt: Date

    var id: String {
        [
            String(pid), fileDescriptor, transport.rawValue, ipVersion.rawValue,
            localEndpoint, remoteEndpoint
        ].joined(separator: "|")
    }

    var localPortSortValue: Int { localPort ?? Int.max }
    var transportSortValue: String { transport.rawValue }
    var statusSortValue: String { state ?? "" }
    var isListening: Bool { transport == .tcp && state == "LISTEN" }

    var isActiveConnection: Bool {
        transport == .tcp && !isListening && remoteAddress != nil
    }

    var localPortText: String { localPort.map(String.init) ?? "*" }
    var remotePortText: String { remotePort.map(String.init) ?? "*" }
    var statusDisplay: String { state ?? "—" }

    var localEndpoint: String {
        Self.formatEndpoint(address: localAddress, port: localPort)
    }

    var remoteEndpoint: String {
        guard let remoteAddress else { return "—" }
        return Self.formatEndpoint(address: remoteAddress, port: remotePort)
    }

    var protocolDisplay: String {
        "\(transport.rawValue) · \(ipVersion.rawValue)"
    }

    var belongsToCurrentUser: Bool {
        user == NSUserName()
    }

    func withExecutablePath(_ path: String?) -> PortRecord {
        PortRecord(
            processName: processName,
            pid: pid,
            user: user,
            fileDescriptor: fileDescriptor,
            ipVersion: ipVersion,
            transport: transport,
            localAddress: localAddress,
            localPort: localPort,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            state: state,
            executablePath: path,
            parentPID: parentPID,
            updatedAt: updatedAt
        )
    }

    private static func formatEndpoint(address: String, port: Int?) -> String {
        let addressText: String
        if address.contains(":") && !address.hasPrefix("[") {
            addressText = "[\(address)]"
        } else {
            addressText = address
        }
        return "\(addressText):\(port.map(String.init) ?? "*")"
    }
}

struct PortSnapshot: Sendable {
    let records: [PortRecord]
    let capturedAt: Date
    let duration: TimeInterval
    let isPartial: Bool
}

struct PortSearch {
    static func rank(of record: PortRecord, query: String) -> Int? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return 0 }

        if value.hasPrefix(":"), let port = Int(value.dropFirst()) {
            return record.localPort == port ? 0 : nil
        }

        if Int(value) != nil {
            let portText = record.localPort.map(String.init) ?? ""
            let pidText = String(record.pid)
            if portText == value || pidText == value { return 0 }
            if portText.contains(value) || pidText.contains(value) { return 1 }
            return nil
        }

        return record.processName.localizedCaseInsensitiveContains(value) ? 0 : nil
    }
}
