import Foundation

@main struct ServiceBenchmark {
    static func main() async throws {
        let configurations: [(String, LsofService, PortQueryPolicy)] = [
            ("metadata_cached", LsofService(), .reuseInFlight),
            ("metadata_fresh", LsofService(), .fresh),
            ("integrations_cached", LsofService(serviceContexts: ManagedServiceController()), .reuseInFlight),
            ("integrations_fresh", LsofService(serviceContexts: ManagedServiceController()), .fresh)
        ]
        for (name, service, policy) in configurations {
            for iteration in 0..<12 {
                let start=ContinuousClock.now
                let snapshot=try await service.query(policy: policy)
                let c=start.duration(to: .now).components
                let total=Double(c.seconds)*1000+Double(c.attoseconds)/1e15
                print("\(name),\(iteration),\(snapshot.duration*1000),\(total),\(snapshot.records.count)")
            }
        }
    }
}
