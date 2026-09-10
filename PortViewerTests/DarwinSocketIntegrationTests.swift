import Darwin
import Foundation
import XCTest
@testable import PortViewer

@MainActor
final class DarwinSocketIntegrationTests: XCTestCase {
    func testRealTCPUDPIPv4IPv6AndConnectedSocketsMatchLsof() async throws {
        var fds: [Int32] = []
        defer { for fd in fds { close(fd) } }
        for family in [AF_INET, AF_INET6] {
            for type in [SOCK_STREAM, SOCK_DGRAM] {
                let fd = try boundSocket(family: family, type: type)
                fds.append(fd)
                if type == SOCK_STREAM {
                    XCTAssertEqual(listen(fd, 4), 0)
                    let shared = dup(fd)
                    XCTAssertGreaterThanOrEqual(shared, 0)
                    fds.append(shared)
                    let client = Darwin.socket(family, SOCK_STREAM, 0)
                    XCTAssertGreaterThanOrEqual(client, 0)
                    fds.append(client)
                    var address = sockaddr_storage()
                    var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    XCTAssertEqual(withUnsafeMutablePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
                    }, 0)
                    XCTAssertEqual(withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, size) }
                    }, 0)
                    let accepted = accept(fd, nil, nil)
                    XCTAssertGreaterThanOrEqual(accepted, 0)
                    fds.append(accepted)
                } else {
                    let sender = try boundSocket(family: family, type: SOCK_DGRAM)
                    fds.append(sender)
                    var address = sockaddr_storage()
                    var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    XCTAssertEqual(withUnsafeMutablePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
                    }, 0)
                    XCTAssertEqual(withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sender, $0, size) }
                    }, 0)
                }
            }
            let closed = Darwin.socket(family, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(closed, 0)
            fds.append(closed)
        }
        let native = try await DarwinPortService().query()
        let lsof = try await LsofService().query()
        let descriptors = Set(fds.map(String.init))
        let n = native.records.filter { $0.pid == getpid() && descriptors.contains($0.fileDescriptor) }
        let l = lsof.records.filter { $0.pid == getpid() && descriptors.contains($0.fileDescriptor) }
        XCTAssertEqual(n.count, fds.count)
        XCTAssertEqual(Set(n.map { signature($0) }), Set(l.map { signature($0) }))
        XCTAssertTrue(n.allSatisfy { $0.context.identity != nil })
    }

    func testFileportOnlyListenerIsVisibleAndMatchesLsofEndpoint() async throws {
        let fd = try boundSocket(family: AF_INET, type: SOCK_STREAM)
        XCTAssertEqual(listen(fd, 4), 0)
        var port: fileport_t = 0
        let status = fileport_makeport(fd, &port)
        close(fd)
        XCTAssertEqual(status, 0)
        guard status == 0 else { return }
        defer { mach_port_deallocate(mach_task_self_, port) }
        let native = try await DarwinPortService().query()
        let record = try XCTUnwrap(native.records.first { $0.pid == getpid() && $0.fileDescriptor == "fp:\(port)" })
        let lsof = try await LsofService().query()
        let reference = try XCTUnwrap(lsof.records.first { $0.pid == getpid() && $0.localPort == record.localPort })
        // lsof's machine output only says "fp." and omits the Mach port number.
        XCTAssertEqual(signature(record, includeDescriptor: false), signature(reference, includeDescriptor: false))
        XCTAssertEqual(reference.fileDescriptor, "fp.")
        XCTAssertTrue(record.isListening)
    }

    private func signature(_ record: PortRecord, includeDescriptor: Bool = true) -> String {
        [String(record.pid), includeDescriptor ? record.fileDescriptor : "", record.processName, record.user,
         record.ipVersion.rawValue, record.transport.rawValue, record.localEndpoint, record.remoteEndpoint,
         record.state ?? "", String(record.parentPID ?? 0)].joined(separator: "|")
    }

    private func boundSocket(family: Int32, type: Int32) throws -> Int32 {
        let fd = Darwin.socket(family, type, 0)
        guard fd >= 0 else { throw DarwinSocketError.system(errno) }
        let result: Int32
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard result == 0 else { let code = errno; close(fd); throw DarwinSocketError.system(code) }
        return fd
    }
}
