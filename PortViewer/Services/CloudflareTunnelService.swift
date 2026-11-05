import Foundation

enum TunnelDiscoveryError: Error { case invalidResponse, responseTooLarge, invalidEndpoint }

protocol CloudflareTunnelDiscovering: Sendable {
    func discover(records: [PortRecord], isPartial: Bool, manualEndpoint: String,
                  force: Bool, interval: TimeInterval) async throws -> TunnelSnapshot
}

struct TunnelHTTPResponse: Sendable { let status: Int; let data: Data }

protocol TunnelHTTPReading: Sendable {
    func get(_ url: URL) async throws -> TunnelHTTPResponse
}

private final class TunnelRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct TunnelHTTPClient: TunnelHTTPReading {
    func get(_ url: URL) async throws -> TunnelHTTPResponse {
        guard CloudflareTunnelService.localEndpoint(url.deletingLastPathComponent().absoluteString) != nil
        else { throw TunnelDiscoveryError.invalidEndpoint }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: TunnelRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw TunnelDiscoveryError.invalidResponse }
        guard response.expectedContentLength <= 1_048_576 else { throw TunnelDiscoveryError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw TunnelDiscoveryError.responseTooLarge }
            data.append(byte)
        }
        return TunnelHTTPResponse(status: response.statusCode, data: data)
    }
}

protocol TunnelProcessInspecting: Sendable {
    func identity(for pid: Int32) -> ProcessIdentity?
    func owns(endpoint: URL, identity: ProcessIdentity) -> Bool
}

struct TunnelProcessInspector: TunnelProcessInspecting {
    func identity(for pid: Int32) -> ProcessIdentity? { ProcessMetadataResolver.identity(for: pid) }

    func owns(endpoint: URL, identity: ProcessIdentity) -> Bool {
        let reader = DarwinSocketReader()
        guard let process = try? reader.processInfo(identity.pid), process.identity == identity,
              let path = ProcessMetadataResolver.executablePath(for: identity.pid),
              URL(fileURLWithPath: path).lastPathComponent == "cloudflared",
              let port = endpoint.port else { return false }
        let ipv6 = endpoint.host?.contains(":") == true
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        for fileports in [false, true] {
            guard let descriptors = try? reader.descriptors(identity.pid, fileports: fileports) else { continue }
            for descriptor in descriptors.prefix(4096) {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
                guard let record = try? reader.socket(identity.pid, descriptor: descriptor,
                                                     process: process, timestamp: Date()),
                      record.isListening, record.localPort == port,
                      record.ipVersion == (ipv6 ? .v6 : .v4),
                      (ipv6 ? ["::1", "::", "*"] : ["127.0.0.1", "0.0.0.0", "*"]).contains(record.localAddress)
                else { continue }
                return self.identity(for: identity.pid) == identity
            }
        }
        return false
    }
}

actor CloudflareTunnelService: CloudflareTunnelDiscovering {
    private struct Candidate: Sendable {
        let endpoint: URL
        let identity: ProcessIdentity?
        var key: String { endpoint.absoluteString }
    }
    private struct Cached: Sendable {
        var connector: TunnelConnector
        var attemptedAt: Date
        var failures: Int
    }
    private let http: any TunnelHTTPReading
    private let inspector: any TunnelProcessInspecting
    private var cache: [String: Cached] = [:]
    private var cursor = 0
    private var inFlight: (id: UUID, task: Task<TunnelSnapshot, Error>)?

    init(http: any TunnelHTTPReading = TunnelHTTPClient(), inspector: any TunnelProcessInspecting = TunnelProcessInspector()) {
        self.http = http
        self.inspector = inspector
    }

    /// User-supplied diagnostics are restricted to literal loopback HTTP endpoints.
    nonisolated static func localEndpoint(_ text: String) -> URL? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "http", ["127.0.0.1", "[::1]", "::1"].contains(components.host),
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        var canonical = components
        canonical.path = ""
        return canonical.url
    }

    func discover(records: [PortRecord], isPartial: Bool, manualEndpoint: String,
                  force: Bool, interval: TimeInterval) async throws -> TunnelSnapshot {
        if let inFlight { return try await inFlight.task.value }
        let id = UUID()
        let task = Task { try await self.perform(records: records, isPartial: isPartial,
                                                manualEndpoint: manualEndpoint, force: force, interval: interval) }
        inFlight = (id, task)
        defer { if inFlight?.id == id { inFlight = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func perform(records: [PortRecord], isPartial: Bool, manualEndpoint: String,
                         force: Bool, interval: TimeInterval) async throws -> TunnelSnapshot {
        let now = Date()
        let candidates = Self.candidates(records: records, manualEndpoint: manualEndpoint)
        let keys = Set(candidates.map(\.key))
        cache = cache.filter { key, value in
            if keys.contains(key) { return true }
            guard isPartial, let identity = value.connector.identity else { return false }
            // An unreadable identity is inconclusive in a partial snapshot, not proof of exit.
            guard let current = inspector.identity(for: identity.pid) else { return true }
            return current == identity
        }
        for key in Array(cache.keys) where !keys.contains(key) {
            guard var value = cache[key], let identity = value.connector.identity,
                  inspector.identity(for: identity.pid) == nil else { continue }
            value.connector.state = .unknown
            value.connector.issue = "无法复核进程归属"
            cache[key] = value
        }
        for candidate in candidates where cache[candidate.key]?.connector.identity != candidate.identity {
            cache[candidate.key] = nil
        }
        let due = candidates.filter { candidate in
            guard !force, let cached = cache[candidate.key] else { return true }
            let backoff = cached.failures == 0 ? interval : [5.0, 15, 30, 60][min(cached.failures - 1, 3)]
            return now.timeIntervalSince(cached.attemptedAt) >= max(interval, backoff)
        }
        // At most four probes per round, each with three one-second HTTP requests.
        let offset = due.isEmpty ? 0 : cursor % due.count
        let selected = Array((Array(due.dropFirst(offset)) + Array(due.prefix(offset))).prefix(4))
        cursor += selected.count
        let http = self.http
        let inspector = self.inspector
        let oldCache = cache
        let results = try await withThrowingTaskGroup(of: (String, Cached?).self) { group in
            for candidate in selected {
                group.addTask {
                    let result = try await Self.probe(candidate, cached: oldCache[candidate.key], force: force,
                                                      http: http, inspector: inspector)
                    return (candidate.key, result)
                }
            }
            var results: [(String, Cached?)] = []
            for try await result in group { results.append(result) }
            return results
        }
        try Task.checkCancellation()
        for (key, result) in results { cache[key] = result }
        var connectors = cache.values.map(\.connector)
        if !manualEndpoint.isEmpty && Self.localEndpoint(manualEndpoint) == nil {
            // Never send a request for an invalid or remote diagnostic endpoint.
            connectors.append(TunnelConnector(endpoint: URL(string: "http://127.0.0.1")!, identity: nil,
                                              issue: "请输入带端口的本机回环 HTTP 地址"))
        }
        return TunnelSnapshot(connectors: connectors.sorted { $0.id < $1.id }, capturedAt: Date())
    }

    private nonisolated static func candidates(records: [PortRecord], manualEndpoint: String) -> [Candidate] {
        var values: [String: Candidate] = [:]
        for record in records where record.isListening {
            guard let path = record.executablePath, URL(fileURLWithPath: path).lastPathComponent == "cloudflared",
                  let identity = record.context.identity, let port = record.localPort else { continue }
            let host: String
            switch (record.ipVersion, record.localAddress) {
            case (.v4, "127.0.0.1"), (.v4, "0.0.0.0"), (.v4, "*"): host = "127.0.0.1"
            case (.v6, "::1"), (.v6, "::"), (.v6, "*"): host = "[::1]"
            default: continue
            }
            guard let endpoint = localEndpoint("http://\(host):\(port)") else { continue }
            let candidate = Candidate(endpoint: endpoint, identity: identity)
            values[candidate.key] = candidate
        }
        if let endpoint = localEndpoint(manualEndpoint) {
            let candidate = Candidate(endpoint: endpoint, identity: nil)
            if values[candidate.key] == nil { values[candidate.key] = candidate }
        }
        return values.values.sorted { $0.key < $1.key }
    }

    private nonisolated static func probe(_ candidate: Candidate, cached: Cached?, force: Bool,
                                          http: any TunnelHTTPReading, inspector: any TunnelProcessInspecting) async throws -> Cached? {
        if let identity = candidate.identity, !inspector.owns(endpoint: candidate.endpoint, identity: identity) { return nil }
        var connector = cached?.connector ?? TunnelConnector(endpoint: candidate.endpoint, identity: candidate.identity)
        var failed = false
        connector.issue = nil
        do {
            let response = try await http.get(candidate.endpoint.appendingPathComponent("ready"))
            let (state, count, id) = try TunnelParser.readiness(response.data, httpStatus: response.status)
            connector.state = state
            connector.readyConnections = count
            connector.connectorID = id
            connector.observedAt = Date()
        } catch {
            try Task.checkCancellation()
            connector.state = .unknown
            connector.issue = "无法读取连接状态"
            failed = true
        }
        if force || connector.routesObservedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
            do {
                let quick = try? await http.get(candidate.endpoint.appendingPathComponent("quicktunnel"))
                try Task.checkCancellation()
                let hostname = quick.flatMap { $0.status == 200 ? try? TunnelParser.quickHostname($0.data) : nil }
                let response = try await http.get(candidate.endpoint.appendingPathComponent("config"))
                guard response.status == 200 else { throw TunnelDiscoveryError.invalidResponse }
                let (version, routes) = try TunnelParser.configuration(response.data, quickHostname: hostname)
                connector.configVersion = version
                connector.routes = routes
                connector.routesObservedAt = Date()
            } catch {
                try Task.checkCancellation()
                connector.issue = "无法读取域名映射"
                failed = true
            }
        }
        if let identity = candidate.identity, !inspector.owns(endpoint: candidate.endpoint, identity: identity) { return nil }
        try Task.checkCancellation()
        return Cached(connector: connector, attemptedAt: Date(), failures: failed ? (cached?.failures ?? 0) + 1 : 0)
    }
}
