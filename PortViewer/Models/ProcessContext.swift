import Foundation

/// The start timestamp is an integer pair to avoid precision loss in identity comparisons.
struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let userID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct ProcessContext: Hashable, Sendable {
    var identity: ProcessIdentity?
    var workingDirectory: String?
    var arguments: [String] = []
    var projectRoot: String?
    var projectName: String?
    var framework: String?
    var managedService: ManagedService?
}

struct ManagedService: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case docker = "Docker", homebrew = "Homebrew" }
    let kind: Kind
    /// Full container ID or formula name, never a shell expression.
    let target: String
    let name: String
    let executable: String
    /// Docker's explicit local Unix socket or the Homebrew installation prefix.
    let endpoint: String
    /// Container StartedAt or launchd process identity; detects restarts during confirmation.
    let generation: String

    var id: String { "\(kind.rawValue)|\(endpoint)|\(target)" }
    var stopTitle: String {
        L10n.string(kind == .docker ? "停止容器…" : "停止 Homebrew 服务…")
    }
}
