import Foundation

protocol DockerStatusQuerying: Sendable {
    func status(for service: ManagedService) async throws -> DockerStatusSnapshot
}

/// Reads only the uniquely associated container, through the same explicit local socket as ownership discovery.
actor DockerStatusService: DockerStatusQuerying {
    private let runner: any LocalCommandRunning
    private let configuredTools: ManagedServiceController.Tools?
    private var cache: [String: DockerStatusSnapshot] = [:]

    init(runner: any LocalCommandRunning = LocalCommandRunner(), tools: ManagedServiceController.Tools? = nil) {
        self.runner = runner
        configuredTools = tools
    }

    func status(for service: ManagedService) async throws -> DockerStatusSnapshot {
        try Task.checkCancellation()
        if let cached = cache[service.id], Date().timeIntervalSince(cached.observedAt) < 10 { return cached }
        let tools = configuredTools ?? ManagedServiceController.Tools.installed()
        guard service.kind == .docker, tools.docker == service.executable, tools.dockerSocket == service.endpoint,
              ManagedServiceController.validContainerID(service.target) else { throw ManagedServiceError.changed }
        let prefix = ["--host", "unix://" + service.endpoint]
        let result: DockerStatusSnapshot
        do {
            let data = try await runner.run(executable: service.executable,
                                            arguments: prefix + ["inspect", "--type", "container", service.target], timeout: .seconds(4))
            let container = try DockerContainerStatus.parse(data, expectedID: service.target)
            result = .init(serviceID: service.id, observedAt: Date(), availability: .available, container: container)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // A successful all-ID listing distinguishes deletion from an unreadable daemon/inspect failure.
            let listing = try? await runner.run(executable: service.executable,
                                               arguments: prefix + ["ps", "--all", "--quiet", "--no-trunc"], timeout: .seconds(3))
            try Task.checkCancellation()
            let ids = listing.map { String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init) }
            let removed = ids.map { $0.allSatisfy(ManagedServiceController.validContainerID) && !$0.contains(service.target) } ?? false
            result = .init(serviceID: service.id, observedAt: Date(), availability: removed ? .removed : .unavailable, container: nil)
        }
        try Task.checkCancellation()
        if cache.count >= 32 { cache.removeAll() }
        cache[service.id] = result
        return result
    }
}
