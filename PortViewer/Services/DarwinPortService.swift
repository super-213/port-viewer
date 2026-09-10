import Darwin
import Foundation

struct DarwinPortService: PortQuerying {
    let reader: any DarwinProcessReading
    let metadataCache: ProcessMetadataCache
    let serviceContexts: (any ServiceContextProviding)?

    init(reader: any DarwinProcessReading = DarwinSocketReader(),
         metadataCache: ProcessMetadataCache = ProcessMetadataCache(),
         serviceContexts: (any ServiceContextProviding)? = nil) {
        self.reader = reader
        self.metadataCache = metadataCache
        self.serviceContexts = serviceContexts
    }

    func query(policy: PortQueryPolicy) async throws -> PortSnapshot {
        let task = Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            let collected = try Self.collect(reader: reader)
            let collectionDuration = start.duration(to: .now).secondsValue
            var records = await metadataCache.enrich(for: collected.records, forceRefresh: policy == .fresh)
            if let serviceContexts {
                records = await serviceContexts.enrich(records, forceRefresh: policy == .fresh)
            }
            try Task.checkCancellation()
            let duration = start.duration(to: .now).secondsValue
            var diagnostics = collected.diagnostics
            diagnostics.collectionDuration = collectionDuration
            diagnostics.enrichmentDuration = duration - collectionDuration
            return PortSnapshot(records: records, capturedAt: collected.capturedAt,
                                duration: duration, isPartial: collected.isPartial, diagnostics: diagnostics)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func collect(reader: any DarwinProcessReading, userID: UInt32 = getuid(),
                        timeout: Duration = .seconds(5)) throws -> PortSnapshot {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        func checkBudget() throws {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { throw DarwinSocketError.timedOut }
        }
        try checkBudget()
        let timestamp = Date()
        let pids = try reader.processIDs(userID: nil)
        // This also identifies our processes when reading their BSD info is denied.
        let owned = Set(try reader.processIDs(userID: userID))
        var diagnostics = PortCollectionDiagnostics(source: .darwin)
        var records: [PortRecord] = []
        var users: [UInt32: String] = [:]

        func failed(_ error: Error, owned: Bool) throws {
            if error is CancellationError { throw error }
            if error as? DarwinSocketError == .timedOut { throw error }
            switch error as? DarwinSocketError {
            case .system(ESRCH), .system(EBADF), .system(ENOENT), .system(ENOTSOCK):
                diagnostics.vanished += 1
            case .system(EPERM), .system(EACCES):
                diagnostics.permissionDenied += 1
                if owned { diagnostics.failures += 1 }
            default:
                diagnostics.failures += 1
            }
        }

        for pid in pids {
            try checkBudget()
            var process: DarwinProcessInfo
            do { process = try reader.processInfo(pid) }
            catch { try failed(error, owned: owned.contains(pid)); continue }
            let isOwned = process.identity.userID == userID
            var processRecords: [PortRecord] = []
            // A socket can survive solely as a Mach fileport, with no open FD.
            for fileports in [false, true] {
                do {
                    let descriptors = try reader.descriptors(pid, fileports: fileports)
                    if !descriptors.isEmpty, process.user == nil {
                        let uid = process.identity.userID
                        let name = users[uid] ?? DarwinSocketReader.userName(uid)
                        users[uid] = name
                        process.user = name
                    }
                    for descriptor in descriptors {
                        try checkBudget()
                        guard records.count + processRecords.count < 100_000 else {
                            throw DarwinSocketError.capacityExceeded
                        }
                        do {
                            if let record = try reader.socket(pid, descriptor: descriptor,
                                                              process: process, timestamp: timestamp) {
                                processRecords.append(record)
                            }
                        } catch { try failed(error, owned: isOwned) }
                    }
                } catch { try failed(error, owned: isOwned) }
            }
            guard !processRecords.isEmpty else { continue }
            do {
                // Never join a socket read from a reused PID to the previous process.
                guard try reader.processInfo(pid).identity == process.identity else {
                    diagnostics.failures += 1
                    continue
                }
                records.append(contentsOf: processRecords)
            } catch { try failed(error, owned: isOwned) }
        }
        return PortSnapshot(records: records.sorted { $0.id < $1.id }, capturedAt: timestamp,
                            duration: 0, isPartial: diagnostics.failures > 0, diagnostics: diagnostics)
    }
}

extension Duration {
    var secondsValue: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
