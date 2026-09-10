import Darwin
import Foundation

enum DarwinSocketError: Error, Equatable {
    case system(Int32)
    case invalidResponse
    case capacityExceeded
    case timedOut
}

struct DarwinProcessInfo: Sendable {
    let identity: ProcessIdentity
    let name: String
    let parentPID: Int32
    var user: String?
}

enum DarwinSocketDescriptor: Hashable, Sendable {
    case fd(Int32)
    case fileport(UInt32)

    var displayValue: String {
        switch self {
        case .fd(let value): String(value)
        case .fileport(let value): "fp:\(value)"
        }
    }
}

protocol DarwinProcessReading: Sendable {
    func processIDs(userID: UInt32?) throws -> [Int32]
    func processInfo(_ pid: Int32) throws -> DarwinProcessInfo
    func descriptors(_ pid: Int32, fileports: Bool) throws -> [DarwinSocketDescriptor]
    func socket(_ pid: Int32, descriptor: DarwinSocketDescriptor,
                process: DarwinProcessInfo, timestamp: Date) throws -> PortRecord?
}

/// Reads public libproc structures. No kernel addresses or process arguments are logged.
struct DarwinSocketReader: DarwinProcessReading {
    func processIDs(userID: UInt32?) throws -> [Int32] {
        let values: [Int32] = try Self.readList(empty: Int32(0)) { buffer, size in
            proc_listpids(userID == nil ? UInt32(PROC_ALL_PIDS) : UInt32(PROC_UID_ONLY),
                          userID ?? 0, buffer, size)
        }
        let pids = Array(Set(values.filter { $0 > 0 })).sorted()
        if userID == nil || userID == getuid() {
            guard pids.contains(getpid()) else { throw DarwinSocketError.invalidResponse }
        }
        return pids
    }

    func processInfo(_ pid: Int32) throws -> DarwinProcessInfo {
        var info = proc_bsdinfo()
        errno = 0
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        try Self.check(count, expected: size)
        let name = Self.string(&info.pbi_name)
        return DarwinProcessInfo(
            identity: ProcessIdentity(pid: pid, userID: info.pbi_uid,
                                      startSeconds: info.pbi_start_tvsec,
                                      startMicroseconds: info.pbi_start_tvusec),
            name: name.isEmpty ? Self.string(&info.pbi_comm) : name,
            parentPID: Int32(bitPattern: info.pbi_ppid)
        )
    }

    func descriptors(_ pid: Int32, fileports: Bool) throws -> [DarwinSocketDescriptor] {
        if fileports {
            let values = try Self.readList(empty: proc_fileportinfo()) { buffer, size in
                proc_pidinfo(pid, PROC_PIDLISTFILEPORTS, 0, buffer, size)
            }
            return values.filter { $0.proc_fdtype == PROX_FDTYPE_SOCKET }
                .map { .fileport($0.proc_fileport) }
        }
        let values = try Self.readList(empty: proc_fdinfo()) { buffer, size in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, size)
        }
        return values.filter { $0.proc_fdtype == PROX_FDTYPE_SOCKET }.map { .fd($0.proc_fd) }
    }

    func socket(_ pid: Int32, descriptor: DarwinSocketDescriptor,
                process: DarwinProcessInfo, timestamp: Date) throws -> PortRecord? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.stride)
        errno = 0
        let count: Int32
        switch descriptor {
        case .fd(let fd):
            count = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        case .fileport(let port):
            count = proc_pidfileportinfo(pid, port, PROC_PIDFILEPORTSOCKETINFO, &info, size)
        }
        try Self.check(count, expected: size)
        return try Self.record(info.psi, descriptor: descriptor, process: process, timestamp: timestamp)
    }

    static func record(_ socket: socket_info, descriptor: DarwinSocketDescriptor,
                       process: DarwinProcessInfo, timestamp: Date) throws -> PortRecord? {
        guard socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { return nil }
        let tcp = socket.soi_protocol == IPPROTO_TCP
        guard tcp || socket.soi_protocol == IPPROTO_UDP else { return nil }
        guard socket.soi_kind == (tcp ? SOCKINFO_TCP : SOCKINFO_IN) else {
            throw DarwinSocketError.invalidResponse
        }
        var info = tcp ? socket.soi_proto.pri_tcp.tcpsi_ini : socket.soi_proto.pri_in
        // CLOSED IPv4 sockets may have no INI_IPV4 flag. A dual-stack IPv6 socket
        // can use IPv4 addresses while retaining its IPv6 socket family in lsof.
        let family = socket.soi_family == AF_INET || info.insi_vflag & UInt8(INI_IPV4) != 0
            ? AF_INET : AF_INET6
        let local: String
        let remote: String
        if family == AF_INET {
            local = try address(&info.insi_laddr.ina_46.i46a_addr4, family: family)
            remote = try address(&info.insi_faddr.ina_46.i46a_addr4, family: family)
        } else {
            local = try address(&info.insi_laddr.ina_6, family: family)
            remote = try address(&info.insi_faddr.ina_6, family: family)
        }
        let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.insi_lport)))
        let remotePort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.insi_fport)))
        let states = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "CLOSE_WAIT",
                      "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT", "RESERVED"]
        let state = Int(socket.soi_proto.pri_tcp.tcpsi_state)
        if tcp && !states.indices.contains(state) { throw DarwinSocketError.invalidResponse }
        return PortRecord(
            processName: process.name, pid: process.identity.pid,
            user: process.user ?? userName(process.identity.userID),
            fileDescriptor: descriptor.displayValue,
            ipVersion: socket.soi_family == AF_INET ? .v4 : .v6,
            transport: tcp ? .tcp : .udp, localAddress: local, localPort: localPort == 0 ? nil : localPort,
            remoteAddress: remote == "*" && remotePort == 0 ? nil : remote,
            remotePort: remotePort == 0 ? nil : remotePort, state: tcp ? states[state] : nil,
            executablePath: nil, parentPID: process.parentPID, updatedAt: timestamp,
            context: ProcessContext(identity: process.identity)
        )
    }

    /// All list APIs return bytes. Retry a full buffer rather than silently truncate
    /// during process/descriptor growth; cap memory and retry count under churn.
    static func readList<T>(empty: T, read: (UnsafeMutableRawPointer?, Int32) -> Int32) throws -> [T] {
        let stride = MemoryLayout<T>.stride
        var capacity = 256
        for _ in 0..<12 {
            try Task.checkCancellation()
            guard capacity * stride <= 16 * 1_024 * 1_024 else { break }
            var buffer = [T](repeating: empty, count: capacity)
            errno = 0
            let count = buffer.withUnsafeMutableBytes { read($0.baseAddress, Int32($0.count)) }
            let code = errno
            guard count >= 0, count != 0 || code == 0 else { throw DarwinSocketError.system(code) }
            guard Int(count) % stride == 0 else { throw DarwinSocketError.invalidResponse }
            if Int(count) < capacity * stride { return Array(buffer.prefix(Int(count) / stride)) }
            capacity *= 2
        }
        throw DarwinSocketError.capacityExceeded
    }

    private static func check(_ count: Int32, expected: Int32) throws {
        guard count == expected else {
            if count <= 0, errno != 0 { throw DarwinSocketError.system(errno) }
            throw DarwinSocketError.invalidResponse
        }
    }

    private static func string<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func userName(_ uid: UInt32) -> String {
        if uid == getuid() { return NSUserName() }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(uid, &entry, bytes.baseAddress, bytes.count, &result) == 0,
                  result != nil, let name = entry.pw_name else { return String(uid) }
            return String(cString: name)
        }
    }

    private static func address<T>(_ value: inout T, family: Int32) throws -> String {
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let success = withUnsafePointer(to: &value) { inet_ntop(family, $0, &output, socklen_t(output.count)) != nil }
        guard success else { throw DarwinSocketError.invalidResponse }
        let result = String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return result == "0.0.0.0" || result == "::" ? "*" : result
    }
}
