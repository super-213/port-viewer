import Darwin
import Foundation

enum ProcessSignalError: LocalizedError, Sendable, Equatable {
    case permissionDenied
    case processMissing
    case identityChanged
    case identityUnavailable
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L10n.string("权限不足，无法结束该进程。当前版本不申请管理员权限。")
        case .processMissing:
            return L10n.string("进程已在操作前自行退出。")
        case .identityChanged:
            return L10n.string("进程身份已变化，已取消操作。请刷新后重新选择。")
        case .identityUnavailable:
            return L10n.string("无法读取进程启动时间，无法安全结束该进程。")
        case .failed(let code):
            return L10n.format("无法向进程发送信号（错误代码 %d）。", code)
        }
    }
}

struct ProcessService: ProcessControlling {
    func send(signal: Int32, to pid: Int32, expectedIdentity: ProcessIdentity) throws {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { throw ProcessSignalError.permissionDenied }
        guard let current = ProcessMetadataResolver.identity(for: pid) else {
            throw exists(pid: pid) ? ProcessSignalError.identityUnavailable : ProcessSignalError.processMissing
        }
        guard current == expectedIdentity else { throw ProcessSignalError.identityChanged }
        guard current.userID == getuid() else { throw ProcessSignalError.permissionDenied }
        // No await or subprocess between the identity read and kill. Darwin has no pidfd-style atomic API.
        guard Darwin.kill(pid, signal) == 0 else {
            switch errno {
            case EPERM: throw ProcessSignalError.permissionDenied
            case ESRCH: throw ProcessSignalError.processMissing
            default: throw ProcessSignalError.failed(errno)
            }
        }
    }

    func exists(pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

enum ProcessProtectionPolicy {
    static func isSharedServiceHost(_ record: PortRecord) -> Bool {
        let name = record.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
            ?? record.processName.lowercased()
        return name.hasPrefix("com.docker") || ["vpnkit", "docker-proxy"].contains(name)
    }
    private static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "securityd",
        "tccd", "runningboardd", "opendirectoryd"
    ]

    static func isCritical(_ record: PortRecord) -> Bool {
        record.pid <= 1
            || record.pid == ProcessInfo.processInfo.processIdentifier
            || protectedNames.contains(record.processName.lowercased())
    }
}
