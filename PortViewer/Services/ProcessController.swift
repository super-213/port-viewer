import Darwin
import Foundation

enum ProcessSignalError: LocalizedError {
    case permissionDenied
    case processMissing
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "权限不足，无法结束该进程。MVP 暂不申请管理员权限。"
        case .processMissing:
            return "进程已在操作前自行退出。"
        case .failed(let code):
            return "无法向进程发送信号（错误代码 \(code)）。"
        }
    }
}

struct ProcessController: Sendable {
    func send(signal: Int32, to pid: Int32) throws {
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
