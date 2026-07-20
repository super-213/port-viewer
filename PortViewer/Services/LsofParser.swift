import Foundation

struct LsofParser: Sendable {
    private struct ProcessFields {
        var pid: Int32
        var command = "未知进程"
        var uid = "未知"
        var login: String?
        var parentPID: Int32?
    }

    private struct FileFields {
        var descriptor: String
        var type: String?
        var transport: TransportProtocol?
        var name: String?
        var state: String?
    }

    struct Endpoint: Equatable {
        let address: String
        let port: Int?
    }

    func parse(_ data: Data, timestamp: Date = Date()) -> [PortRecord] {
        var process: ProcessFields?
        var file: FileFields?
        var records: [PortRecord] = []

        func appendCurrentFile() {
            guard let process, let file,
                  let transport = file.transport,
                  let name = file.name else { return }

            let pair = Self.parseEndpointPair(name)
            guard let local = pair.local else { return }

            let ipVersion: IPVersion
            switch file.type {
            case "IPv4": ipVersion = .v4
            case "IPv6": ipVersion = .v6
            default: ipVersion = .unknown
            }

            records.append(
                PortRecord(
                    processName: process.command,
                    pid: process.pid,
                    user: process.login ?? process.uid,
                    fileDescriptor: file.descriptor,
                    ipVersion: ipVersion,
                    transport: transport,
                    localAddress: local.address,
                    localPort: local.port,
                    remoteAddress: pair.remote?.address,
                    remotePort: pair.remote?.port,
                    state: file.state,
                    executablePath: nil,
                    parentPID: process.parentPID,
                    updatedAt: timestamp
                )
            )
        }

        for rawField in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let decoded = String(data: rawField, encoding: .utf8) else { continue }
            let field = decoded.trimmingCharacters(in: .newlines)
            guard let tag = field.first else { continue }
            let value = String(field.dropFirst())

            switch tag {
            case "p":
                appendCurrentFile()
                file = nil
                if let pid = Int32(value) {
                    process = ProcessFields(pid: pid)
                } else {
                    process = nil
                }
            case "c":
                process?.command = value.isEmpty ? "未知进程" : value
            case "u":
                process?.uid = value.isEmpty ? "未知" : value
            case "L":
                process?.login = value.isEmpty ? nil : value
            case "R":
                process?.parentPID = Int32(value)
            case "f":
                appendCurrentFile()
                file = FileFields(descriptor: value)
            case "t":
                file?.type = value
            case "P":
                file?.transport = TransportProtocol(rawValue: value)
            case "n":
                file?.name = value
            case "T":
                if value.hasPrefix("ST=") {
                    let state = String(value.dropFirst(3))
                    file?.state = state.isEmpty ? nil : state
                }
            default:
                continue
            }
        }

        appendCurrentFile()
        return records
    }

    static func parseEndpointPair(_ value: String) -> (local: Endpoint?, remote: Endpoint?) {
        let parts = value.components(separatedBy: "->")
        let local = parseEndpoint(parts[0])
        let remote = parts.count > 1 ? parseEndpoint(parts[1]) : nil
        return (local, remote)
    }

    static func parseEndpoint(_ value: String) -> Endpoint? {
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("["), let bracket = value.lastIndex(of: "]") {
            let address = String(value[value.index(after: value.startIndex)..<bracket])
            let suffix = value[value.index(after: bracket)...]
            guard suffix.first == ":" else { return Endpoint(address: address, port: nil) }
            let portText = suffix.dropFirst()
            return Endpoint(address: address, port: Int(portText))
        }

        guard let separator = value.lastIndex(of: ":") else {
            return Endpoint(address: value, port: nil)
        }
        let address = String(value[..<separator])
        let portText = value[value.index(after: separator)...]
        return Endpoint(address: address.isEmpty ? "*" : address, port: Int(portText))
    }
}
