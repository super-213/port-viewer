import Foundation

/// One shared flight across both backends. Safety queries always start a fresh
/// lsof query after any existing refresh, and never accept a native substitute.
actor PortQueryService: PortQuerying {
    private let native: any PortQuerying
    private let lsof: any PortQuerying
    private var nextID: UInt64 = 0
    private var inFlight: (id: UInt64, task: Task<PortSnapshot, Error>)?
    private var cancellation: (id: UInt64, task: Task<Void, Never>)?

    init(native: any PortQuerying, lsof: any PortQuerying) {
        self.native = native
        self.lsof = lsof
    }

    init(serviceContexts: (any ServiceContextProviding)? = nil) {
        let cache = ProcessMetadataCache()
        self.native = DarwinPortService(metadataCache: cache, serviceContexts: serviceContexts)
        self.lsof = LsofService(metadataCache: cache, serviceContexts: serviceContexts)
    }

    func query(policy: PortQueryPolicy) async throws -> PortSnapshot {
        while true {
            if let cleanup = cancellation {
                await cleanup.task.value
                clearCancellation(cleanup.id)
                try Task.checkCancellation()
                continue
            }
            guard let current = inFlight else { break }
            if policy == .reuseInFlight { return try await result(current) }
            _ = try? await result(current)
        }
        try Task.checkCancellation()
        nextID &+= 1
        let native = native
        let lsof = lsof
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            if policy == .fresh {
                let snapshot = try await lsof.query(policy: .fresh)
                try Task.checkCancellation()
                return snapshot
            }
            let start = ContinuousClock.now
            var partial: PortSnapshot?
            let reason: String
            do {
                let snapshot = try await native.query(policy: .reuseInFlight)
                try Task.checkCancellation()
                if !snapshot.isPartial { return snapshot }
                partial = snapshot
                reason = "Native collection was incomplete"
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                reason = "Native collection failed"
            }
            try Task.checkCancellation()
            do {
                let snapshot = try await lsof.query(policy: .reuseInFlight)
                try Task.checkCancellation()
                var diagnostics = partial?.diagnostics ?? PortCollectionDiagnostics()
                diagnostics.source = .lsofFallback
                diagnostics.fallbackReason = reason
                diagnostics.collectionDuration += snapshot.diagnostics.collectionDuration
                diagnostics.enrichmentDuration += snapshot.diagnostics.enrichmentDuration
                return PortSnapshot(records: snapshot.records, capturedAt: snapshot.capturedAt,
                                    duration: start.duration(to: .now).secondsValue,
                                    isPartial: snapshot.isPartial, activitySnapshot: snapshot.activitySnapshot,
                                    diagnostics: diagnostics)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                guard let partial else { throw error }
                var diagnostics = partial.diagnostics
                diagnostics.fallbackReason = "\(reason); lsof fallback failed"
                return PortSnapshot(records: partial.records, capturedAt: partial.capturedAt,
                                    duration: start.duration(to: .now).secondsValue, isPartial: true,
                                    activitySnapshot: partial.activitySnapshot, diagnostics: diagnostics)
            }
        }
        let current = (id: nextID, task: task)
        inFlight = current
        return try await result(current)
    }

    func cancelCurrentQuery() async {
        if let cleanup = cancellation {
            await cleanup.task.value
            clearCancellation(cleanup.id)
            return
        }
        guard let current = inFlight else { return }
        current.task.cancel()
        let native = native
        let lsof = lsof
        // Keep a barrier until backend cleanup completes. Otherwise a new query
        // could start after the old task ends and receive its delayed cancellation.
        let cleanup = Task {
            await native.cancelCurrentQuery()
            await lsof.cancelCurrentQuery()
            _ = try? await current.task.value
        }
        cancellation = (id: current.id, task: cleanup)
        await cleanup.value
        clearCancellation(current.id)
    }

    private func clearCancellation(_ id: UInt64) {
        if cancellation?.id == id { cancellation = nil }
        if inFlight?.id == id { inFlight = nil }
    }

    private func result(_ current: (id: UInt64, task: Task<PortSnapshot, Error>)) async throws -> PortSnapshot {
        defer { if inFlight?.id == current.id { inFlight = nil } }
        return try await current.task.value
    }
}
