// Compile with the production Models, Services and L10n sources (see implementation report).
import Darwin
import Foundation

@main struct ProductionBenchmark {
    static func cpuTime() -> Double {
        var own = rusage()
        var children = rusage()
        getrusage(RUSAGE_SELF, &own)
        getrusage(RUSAGE_CHILDREN, &children)
        return [own.ru_utime, own.ru_stime, children.ru_utime, children.ru_stime].reduce(0) {
            $0 + Double($1.tv_sec) + Double($1.tv_usec) / 1e6
        }
    }
    static func key(_ r: PortRecord) -> String {
        // lsof's field output hides the fileport number; endpoint comparison is
        // appropriate here, while native UI identifiers retain that number.
        [String(r.pid), r.fileDescriptor.hasPrefix("fp") ? "fp" : r.fileDescriptor,
         r.processName, r.user, r.transport.rawValue, r.ipVersion.rawValue,
         r.localEndpoint, r.remoteEndpoint, r.state ?? "", String(r.parentPID ?? 0)].joined(separator: "|")
    }
    static func main() async throws {
        let services: [(String, any PortQuerying)] = [
            ("native", PortQueryService(serviceContexts: ManagedServiceController())),
            ("lsof", LsofService(serviceContexts: ManagedServiceController()))
        ]
        for (_, service) in services { _ = try await service.query() }
        print("backend,iteration,total_ms,collection_ms,enrichment_ms,cpu_ms,source,records,partial")
        for i in 0..<30 {
            for (name, service) in i % 2 == 0 ? services : services.reversed() {
                let start = ContinuousClock.now
                let cpu = cpuTime()
                let s = try await service.query()
                let used = (cpuTime() - cpu) * 1000
                let total = start.duration(to: .now).secondsValue * 1000
                let d = s.diagnostics
                print("\(name),\(i),\(total),\(d.collectionDuration * 1000),\(d.enrichmentDuration * 1000),\(used),\(d.source.rawValue),\(s.records.count),\(s.isPartial)")
            }
        }
        let before = try await services[1].1.query()
        let native = try await services[0].1.query()
        let after = try await services[1].1.query()
        let b = Set(before.records.map(key)), n = Set(native.records.map(key)), a = Set(after.records.map(key))
        let stable = b.intersection(a)
        let report = "stable=\(stable.count), matched=\(stable.intersection(n).count), missing=\(stable.subtracting(n).count), unexplained_extra=\(n.subtracting(b.union(a)).count)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }
}
