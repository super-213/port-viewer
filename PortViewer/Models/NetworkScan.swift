import Foundation

enum NetworkScanScope: String, CaseIterable, Identifiable, Sendable {
    case host = "单台主机"
    case subnet = "局域网网段"

    var id: Self { self }

    var targetPrompt: String {
        switch self {
        case .host: return L10n.string("主机名或 IP，例如 192.168.1.10")
        case .subnet: return L10n.string("IPv4 CIDR，例如 192.168.1.0/24")
        }
    }
}

enum ScanPortPreset: String, CaseIterable, Identifiable, Sendable {
    case common = "常用端口"
    case wellKnown = "1–1024"
    case all = "全部端口"
    case custom = "自定义"

    var id: Self { self }

    var ports: [UInt16]? {
        switch self {
        case .common:
            return [
                20, 21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 389, 443, 445,
                465, 587, 631, 636, 993, 995, 1_433,
                1_522, 1_883, 2_045, 2_379, 3_000, 3_306, 3_389, 5_000, 5_433, 5_555,
                5_900, 6_378, 8_000, 8_080, 8_443, 8_888, 9_000, 9_092, 9_100, 27_017
            ]
        case .wellKnown:
            return (1...1_024).map(UInt16.init)
        case .all:
            return (1...65_535).map(UInt16.init)
        case .custom:
            return nil
        }
    }
}

enum NetworkScanValidationError: LocalizedError, Equatable {
    case missingTarget
    case invalidHost
    case invalidCIDR
    case subnetTooLarge
    case emptyPorts
    case invalidPort(String)
    case tooManyProbes(Int)

    var errorDescription: String? {
        switch self {
        case .missingTarget:
            return L10n.string("请输入要扫描的主机或网段。")
        case .invalidHost:
            return L10n.string("主机名或 IP 格式无效。")
        case .invalidCIDR:
            return L10n.string("请输入有效的 IPv4 CIDR，例如 192.168.1.0/24。")
        case .subnetTooLarge:
            return L10n.string("单次最多扫描 1,024 台主机，请缩小网段。")
        case .emptyPorts:
            return L10n.string("请至少选择一个 TCP 端口。")
        case .invalidPort(let token):
            return L10n.format("端口“%@”无效；可输入 22,80,443 或 8000-8100。", token)
        case .tooManyProbes(let count):
            return L10n.format("本次需要探测 %lld 个端点，超过 300,000 个上限；请缩小网段或端口范围。", count)
        }
    }
}

struct NetworkScanPlan: Sendable, Equatable {
    static let maximumHosts = 1_024
    static let maximumProbes = 300_000

    let scope: NetworkScanScope
    let targets: [String]
    let ports: [UInt16]
    let timeout: Duration
    let concurrency: Int

    var totalProbeCount: Int { targets.count * ports.count }

    static func make(
        scope: NetworkScanScope,
        target: String,
        preset: ScanPortPreset,
        customPorts: String,
        timeout: TimeInterval,
        concurrency: Int = 192
    ) throws -> NetworkScanPlan {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { throw NetworkScanValidationError.missingTarget }

        let targets: [String]
        switch scope {
        case .host:
            guard Self.isPlausibleHost(trimmedTarget) else {
                throw NetworkScanValidationError.invalidHost
            }
            targets = [trimmedTarget]
        case .subnet:
            let subnet = try IPv4Subnet(cidr: trimmedTarget)
            guard subnet.hosts.count <= maximumHosts else {
                throw NetworkScanValidationError.subnetTooLarge
            }
            targets = subnet.hosts
        }

        let ports = try preset.ports ?? PortRangeParser.parse(customPorts)
        guard !ports.isEmpty else { throw NetworkScanValidationError.emptyPorts }
        let probeCount = targets.count * ports.count
        guard probeCount <= maximumProbes else {
            throw NetworkScanValidationError.tooManyProbes(probeCount)
        }

        return NetworkScanPlan(
            scope: scope,
            targets: targets,
            ports: ports,
            timeout: .milliseconds(Int64(max(0.15, min(timeout, 3)) * 1_000)),
            concurrency: max(1, min(concurrency, 256))
        )
    }

    private static func isPlausibleHost(_ value: String) -> Bool {
        guard value.count <= 253, !value.contains(where: { $0.isWhitespace }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

enum PortRangeParser {
    static func parse(_ value: String) throws -> [UInt16] {
        let tokens = value
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard !tokens.isEmpty, tokens.contains(where: { !$0.isEmpty }) else {
            throw NetworkScanValidationError.emptyPorts
        }

        var result = Set<UInt16>()
        for token in tokens {
            guard !token.isEmpty else { throw NetworkScanValidationError.invalidPort(token) }
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                guard let port = parsePort(String(bounds[0])) else {
                    throw NetworkScanValidationError.invalidPort(token)
                }
                result.insert(port)
            case 2:
                guard let lower = parsePort(String(bounds[0])),
                      let upper = parsePort(String(bounds[1])),
                      lower <= upper else {
                    throw NetworkScanValidationError.invalidPort(token)
                }
                for port in Int(lower)...Int(upper) {
                    result.insert(UInt16(port))
                }
            default:
                throw NetworkScanValidationError.invalidPort(token)
            }
        }
        return result.sorted()
    }

    private static func parsePort(_ value: String) -> UInt16? {
        guard let port = Int(value), (1...65_535).contains(port) else { return nil }
        return UInt16(port)
    }
}

struct IPv4Subnet: Equatable, Sendable {
    let networkAddress: UInt32
    let prefixLength: Int
    let hosts: [String]

    init(cidr: String) throws {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let address = Self.parseAddress(String(parts[0])),
              let prefix = Int(parts[1]),
              (0...32).contains(prefix) else {
            throw NetworkScanValidationError.invalidCIDR
        }

        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
        let network = address & mask
        let addressCount = UInt64(1) << UInt64(32 - prefix)
        let hostCount = prefix <= 30 ? max(0, Int(addressCount) - 2) : Int(addressCount)
        guard hostCount <= NetworkScanPlan.maximumHosts else {
            throw NetworkScanValidationError.subnetTooLarge
        }

        let start: UInt64 = prefix <= 30 ? UInt64(network) + 1 : UInt64(network)
        self.networkAddress = network
        self.prefixLength = prefix
        self.hosts = (0..<hostCount).map { Self.formatAddress(UInt32(start + UInt64($0))) }
    }

    private static func parseAddress(_ value: String) -> UInt32? {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard let number = UInt8(octet) else { return nil }
            result = (result << 8) | UInt32(number)
        }
        return result
    }

    private static func formatAddress(_ value: UInt32) -> String {
        [24, 16, 8, 0]
            .map { String((value >> UInt32($0)) & 0xFF) }
            .joined(separator: ".")
    }
}

struct OpenPortResult: Identifiable, Hashable, Sendable {
    let host: String
    let port: UInt16
    let latency: TimeInterval

    var id: String { "\(host):\(port)" }
    var endpoint: String { "\(host):\(port)" }
}

struct NetworkScanProgress: Sendable, Equatable {
    let completedCount: Int
    let totalCount: Int
    let openCount: Int
    let currentEndpoint: String?

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}

struct NetworkScanReport: Sendable, Equatable {
    let plan: NetworkScanPlan
    let openPorts: [OpenPortResult]
    let startedAt: Date
    let finishedAt: Date

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    var hostsWithOpenPorts: Int { Set(openPorts.map(\.host)).count }
}
