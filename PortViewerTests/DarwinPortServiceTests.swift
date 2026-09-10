import Darwin
import Foundation
import XCTest
@testable import PortViewer

private final class FixtureDarwinReader: DarwinProcessReading, @unchecked Sendable {
    let uid: UInt32
    let descriptorError: DarwinSocketError?
    let socketError: DarwinSocketError?
    let replacesProcess: Bool
    private let lock = NSLock()
    private var infoReads = 0

    init(uid: UInt32 = getuid(), descriptorError: DarwinSocketError? = nil,
         socketError: DarwinSocketError? = nil, replacesProcess: Bool = false) {
        self.uid = uid
        self.descriptorError = descriptorError
        self.socketError = socketError
        self.replacesProcess = replacesProcess
    }
    func processIDs(userID: UInt32?) throws -> [Int32] { userID == nil || userID == uid ? [123] : [] }
    func processInfo(_ pid: Int32) throws -> DarwinProcessInfo {
        let count = lock.withLock { infoReads += 1; return infoReads }
        return DarwinProcessInfo(identity: ProcessIdentity(pid: pid, userID: uid,
            startSeconds: replacesProcess && count > 1 ? 200 : 100, startMicroseconds: 1),
            name: "fixture", parentPID: 1)
    }
    func descriptors(_ pid: Int32, fileports: Bool) throws -> [DarwinSocketDescriptor] {
        if let descriptorError { throw descriptorError }
        return fileports ? [.fileport(42)] : []
    }
    func socket(_ pid: Int32, descriptor: DarwinSocketDescriptor,
                process: DarwinProcessInfo, timestamp: Date) throws -> PortRecord? {
        if let socketError { throw socketError }
        return PortTestFixtures.record(fileDescriptor: descriptor.displayValue).withContext(ProcessContext(identity: process.identity))
    }
}

final class DarwinPortServiceTests: XCTestCase {
    private var process: DarwinProcessInfo {
        DarwinProcessInfo(identity: ProcessIdentity(pid: getpid(), userID: getuid(), startSeconds: 1, startMicroseconds: 0),
                          name: "fixture", parentPID: 1)
    }

    func testFileportsAreCollectedEvenWithoutAnyFDs() throws {
        let result = try DarwinPortService.collect(reader: FixtureDarwinReader())
        XCTAssertEqual(result.records.map(\.fileDescriptor), ["fp:42"])
        XCTAssertFalse(result.isPartial)
    }

    func testOwnPermissionFailureIsPartialButOtherUserDenialIsExpected() throws {
        let own = try DarwinPortService.collect(reader: FixtureDarwinReader(descriptorError: .system(EPERM)))
        let other = try DarwinPortService.collect(reader: FixtureDarwinReader(uid: getuid() + 1, descriptorError: .system(EPERM)))
        XCTAssertTrue(own.isPartial)
        XCTAssertFalse(other.isPartial)
        XCTAssertGreaterThan(other.diagnostics.permissionDenied, 0)
    }

    func testDescriptorDisappearingIsNormalChurn() throws {
        for code in [ESRCH, EBADF, ENOENT, ENOTSOCK] {
            let result = try DarwinPortService.collect(reader: FixtureDarwinReader(socketError: .system(code)))
            XCTAssertFalse(result.isPartial)
            XCTAssertEqual(result.diagnostics.vanished, 1)
            XCTAssertTrue(result.records.isEmpty)
        }
    }

    func testUnsupportedResponseAndCapacityFailureArePartial() throws {
        for error in [DarwinSocketError.invalidResponse, .capacityExceeded, .system(EIO)] {
            let result = try DarwinPortService.collect(reader: FixtureDarwinReader(descriptorError: error))
            XCTAssertTrue(result.isPartial)
        }
    }

    func testExpiredScanBudgetFailsRatherThanReturningAnEmptyCompleteSnapshot() {
        XCTAssertThrowsError(try DarwinPortService.collect(reader: FixtureDarwinReader(), timeout: .zero)) {
            XCTAssertEqual($0 as? DarwinSocketError, .timedOut)
        }
    }

    func testPIDReusedDuringScanDiscardsOldSocketsAndRequestsFallback() throws {
        let result = try DarwinPortService.collect(reader: FixtureDarwinReader(replacesProcess: true))
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.isPartial)
    }

    func testListBufferGrowthAndMalformedResponse() throws {
        var calls = 0
        let values: [Int32] = try DarwinSocketReader.readList(empty: Int32(0)) { buffer, bytes in
            calls += 1
            if calls == 1 { return bytes }
            buffer!.storeBytes(of: Int32(123), as: Int32.self)
            return 4
        }
        XCTAssertEqual(values, [123])
        XCTAssertEqual(calls, 2)
        XCTAssertThrowsError(try DarwinSocketReader.readList(empty: Int32(0)) { _, _ in 3 })
        XCTAssertThrowsError(try DarwinSocketReader.readList(empty: Int32(0)) { _, bytes in bytes })
        XCTAssertThrowsError(try DarwinSocketReader.readList(empty: Int32(0)) { _, _ in errno = EPERM; return 0 })
        let empty: [Int32] = try DarwinSocketReader.readList(empty: Int32(0)) { _, _ in 0 }
        XCTAssertTrue(empty.isEmpty)
    }

    func testClosedIPv4WithoutFlagsUsesIPv4AddressAndWildcardPort() throws {
        var socket = socket_info()
        socket.soi_family = AF_INET
        socket.soi_protocol = IPPROTO_TCP
        socket.soi_kind = Int32(SOCKINFO_TCP)
        socket.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = inet_addr("127.0.0.1")
        let record = try XCTUnwrap(DarwinSocketReader.record(socket, descriptor: .fd(1), process: process, timestamp: Date()))
        XCTAssertEqual(record.localAddress, "127.0.0.1")
        XCTAssertEqual(record.state, "CLOSED")
        XCTAssertEqual(record.ipVersion, .v4)
        XCTAssertNil(record.localPort)
        XCTAssertNil(record.remoteAddress)
    }

    func testIPv6SocketWithIPv4AddressesRetainsIPv6Family() throws {
        var socket = socket_info()
        socket.soi_family = AF_INET6
        socket.soi_protocol = IPPROTO_TCP
        socket.soi_kind = Int32(SOCKINFO_TCP)
        socket.soi_proto.pri_tcp.tcpsi_state = 4
        socket.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
        socket.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = inet_addr("127.0.0.1")
        socket.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(5173).bigEndian)
        socket.soi_proto.pri_tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4.s_addr = inet_addr("127.0.0.2")
        socket.soi_proto.pri_tcp.tcpsi_ini.insi_fport = Int32(UInt16(1234).bigEndian)
        let record = try XCTUnwrap(DarwinSocketReader.record(socket, descriptor: .fd(1), process: process, timestamp: Date()))
        XCTAssertEqual(record.ipVersion, .v6)
        XCTAssertEqual(record.localEndpoint, "127.0.0.1:5173")
        XCTAssertEqual(record.remoteEndpoint, "127.0.0.2:1234")
        XCTAssertEqual(record.state, "ESTABLISHED")
    }

    func testIPv6WildcardUDPHasNoTCPState() throws {
        var socket = socket_info()
        socket.soi_family = AF_INET6
        socket.soi_protocol = IPPROTO_UDP
        socket.soi_kind = Int32(SOCKINFO_IN)
        let record = try XCTUnwrap(DarwinSocketReader.record(socket, descriptor: .fd(1), process: process, timestamp: Date()))
        XCTAssertEqual(record.localAddress, "*")
        XCTAssertNil(record.remoteAddress)
        XCTAssertNil(record.state)
    }

    func testUnknownTCPStateOrWrongSocketLayoutRequestsFallback() throws {
        var socket = socket_info()
        socket.soi_family = AF_INET
        socket.soi_protocol = IPPROTO_TCP
        socket.soi_kind = Int32(SOCKINFO_TCP)
        socket.soi_proto.pri_tcp.tcpsi_state = 99
        XCTAssertThrowsError(try DarwinSocketReader.record(socket, descriptor: .fd(1), process: process, timestamp: Date()))
        socket.soi_kind = Int32(SOCKINFO_IN)
        XCTAssertThrowsError(try DarwinSocketReader.record(socket, descriptor: .fd(1), process: process, timestamp: Date()))
        socket.soi_family = AF_UNIX
        XCTAssertNil(try DarwinSocketReader.record(socket, descriptor: .fd(1), process: process, timestamp: Date()))
    }

    func testEnrichmentNeverOverwritesScannedIdentityWithReusedPID() async {
        let identity = ProcessIdentity(pid: getpid(), userID: getuid(), startSeconds: 1, startMicroseconds: 0)
        let record = PortTestFixtures.record(pid: getpid()).withContext(ProcessContext(identity: identity))
        let result = await ProcessMetadataCache().enrich(for: [record], forceRefresh: true)
        XCTAssertEqual(result.first?.context.identity, identity)
    }
}
