import Darwin
import Foundation

enum QueryPresentationState: Equatable {
    case loading
    case ready
    case empty
    case paused
    case partial(String)
    case failed(String)
    case unavailable(String)

    var issueMessage: String? {
        switch self {
        case .partial(let message), .failed(let message), .unavailable(let message):
            return message
        default:
            return nil
        }
    }
}

struct OperationFeedback: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case error
        case information
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

struct TerminationPrompt: Identifiable, Equatable {
    enum Stage: Equatable {
        case standard
        case force
    }

    let stage: Stage
    let record: PortRecord
    let otherConnectionCount: Int
    let otherOccupants: [String]
    let isCritical: Bool

    var id: String { "\(record.id)|\(stage)" }

    var title: String {
        stage == .standard ? "结束 \(record.processName)？" : "强制结束 \(record.processName)？"
    }

    var actionTitle: String {
        stage == .standard ? "结束进程" : "强制结束"
    }

    var message: String {
        var lines = [
            "PID \(record.pid) · \(record.transport.rawValue) 端口 \(record.localPortText)",
            "结束的是整个进程，而不只是这个端口。"
        ]
        if otherConnectionCount > 0 {
            lines.append("该进程的另外 \(otherConnectionCount) 条端口或连接也会一并关闭。")
        }
        if !otherOccupants.isEmpty {
            lines.append("同一端口还由 \(otherOccupants.joined(separator: "、")) 占用；本次只结束当前选中的进程。")
        }
        if isCritical {
            lines.append("这是受保护的系统关键进程；不会允许强制结束。")
        }
        if stage == .force {
            lines.append("强制结束可能造成未保存数据丢失。")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class PortStore: ObservableObject {
    @Published private(set) var records: [PortRecord] = []
    @Published private(set) var state: QueryPresentationState = .loading
    @Published private(set) var lastSuccessfulUpdate: Date?
    @Published private(set) var lastQueryDuration: TimeInterval?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPaused = false
    @Published var terminationPrompt: TerminationPrompt?
    @Published var feedback: OperationFeedback?
    @Published var requestedSelectionID: String?

    private enum RefreshReason {
        case initial
        case automatic
        case manual
    }

    private let queryClient: LsofClient
    private let processController: ProcessController
    private var refreshLoop: Task<Void, Never>?
    private var queuedRefresh = false
    private var isMainWindowVisible = true
    private var didRequestInitialWindow = false

    init(
        queryClient: LsofClient = LsofClient(),
        processController: ProcessController = ProcessController()
    ) {
        self.queryClient = queryClient
        self.processController = processController
    }

    deinit {
        refreshLoop?.cancel()
    }

    var listeningCount: Int { records.lazy.filter(\.isListening).count }
    var activeConnectionCount: Int { records.lazy.filter(\.isActiveConnection).count }

    var statusSymbolName: String {
        if isPaused { return "pause.circle" }
        switch state {
        case .failed, .unavailable, .partial: return "exclamationmark.triangle"
        default: return "network"
        }
    }

    func start() {
        guard refreshLoop == nil else { return }
        Task { await refresh(reason: .initial) }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.currentRefreshInterval
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled, !self.isPaused else { continue }
                await self.refresh(reason: .automatic)
            }
        }
    }

    func claimInitialWindowRequest() -> Bool {
        guard !didRequestInitialWindow else { return false }
        didRequestInitialWindow = true
        return true
    }

    func setMainWindowVisible(_ visible: Bool) {
        isMainWindowVisible = visible
    }

    func refreshNow() {
        Task { await refresh(reason: .manual) }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            state = .paused
        } else {
            state = records.isEmpty ? .empty : .ready
            refreshNow()
        }
    }

    func selectFromMenuBar(_ record: PortRecord) {
        requestedSelectionID = record.id
    }

    func dismissFeedback() {
        feedback = nil
    }

    func prepareToTerminate(_ staleRecord: PortRecord) async {
        guard staleRecord.belongsToCurrentUser else {
            feedback = OperationFeedback(
                kind: .error,
                message: "\(staleRecord.processName) 属于用户 \(staleRecord.user)。MVP 不申请管理员权限，无法结束其他用户的进程。"
            )
            return
        }

        do {
            let snapshot = try await queryClient.query()
            apply(snapshot)
            guard !snapshot.isPartial else {
                feedback = OperationFeedback(kind: .error, message: "最新查询结果不完整，无法安全校验进程与端口的关联。请重试。")
                return
            }

            guard let liveRecord = snapshot.records.first(where: { $0.matchesTarget(staleRecord) }) else {
                let processStillExists = processController.exists(pid: staleRecord.pid)
                feedback = OperationFeedback(
                    kind: .information,
                    message: processStillExists
                        ? "该进程已不再占用所选端口，未发送任何信号。"
                        : "进程已在操作前自行退出，未发送任何信号。"
                )
                return
            }

            let otherCount = snapshot.records.filter {
                $0.pid == liveRecord.pid && $0.id != liveRecord.id
            }.count
            terminationPrompt = TerminationPrompt(
                stage: .standard,
                record: liveRecord,
                otherConnectionCount: otherCount,
                otherOccupants: occupantLabels(for: liveRecord, in: snapshot.records),
                isCritical: ProcessProtectionPolicy.isCritical(liveRecord)
            )
        } catch {
            feedback = OperationFeedback(
                kind: .error,
                message: "无法完成操作前校验：\(error.localizedDescription) 未发送任何信号。"
            )
        }
    }

    func confirmTermination(_ prompt: TerminationPrompt) async {
        terminationPrompt = nil

        let force = prompt.stage == .force
        if force && prompt.isCritical {
            feedback = OperationFeedback(kind: .error, message: "为避免系统异常，Port Viewer 禁止强制结束该关键系统进程。")
            return
        }

        do {
            try processController.send(signal: force ? SIGKILL : SIGTERM, to: prompt.record.pid)
        } catch {
            feedback = OperationFeedback(kind: .error, message: error.localizedDescription)
            return
        }

        do {
            let delay: UInt64 = force ? 500_000_000 : 1_500_000_000
            try await Task.sleep(nanoseconds: delay)
            let snapshot = try await queryClient.query()
            apply(snapshot)

            guard !snapshot.isPartial else {
                feedback = OperationFeedback(kind: .warning, message: "信号已发送，但最新查询不完整，暂时无法验证端口状态。请重试刷新。")
                return
            }

            let originalStillOccupies = snapshot.records.contains { $0.matchesTarget(prompt.record) }
            let currentOccupants = snapshot.records.filter { $0.matchesPort(prompt.record) }

            if !originalStillOccupies, currentOccupants.isEmpty {
                feedback = OperationFeedback(kind: .success, message: "\(prompt.record.transport.rawValue) 端口 \(prompt.record.localPortText) 已释放。")
            } else if !originalStillOccupies {
                feedback = OperationFeedback(
                    kind: .warning,
                    message: "原进程已结束，但端口已被 \(currentOccupants.first?.processName ?? "另一个进程") 重新占用。"
                )
            } else if force {
                feedback = OperationFeedback(kind: .error, message: "强制结束后进程仍占用该端口，操作超时。请刷新后检查权限与进程状态。")
            } else {
                let liveRecord = currentOccupants.first { $0.pid == prompt.record.pid } ?? prompt.record
                terminationPrompt = TerminationPrompt(
                    stage: .force,
                    record: liveRecord,
                    otherConnectionCount: snapshot.records.filter { $0.pid == liveRecord.pid && $0.id != liveRecord.id }.count,
                    otherOccupants: occupantLabels(for: liveRecord, in: snapshot.records),
                    isCritical: ProcessProtectionPolicy.isCritical(liveRecord)
                )
            }
        } catch is CancellationError {
            feedback = OperationFeedback(kind: .warning, message: "进程结束操作已取消，暂时无法验证端口状态。")
        } catch {
            feedback = OperationFeedback(kind: .warning, message: "信号已发送，但无法验证端口状态：\(error.localizedDescription)")
        }
    }

    private var currentRefreshInterval: TimeInterval {
        let key = isMainWindowVisible ? "foregroundRefreshInterval" : "backgroundRefreshInterval"
        let stored = UserDefaults.standard.double(forKey: key)
        if stored > 0 { return stored }
        return isMainWindowVisible ? 3 : 5
    }

    private func refresh(reason: RefreshReason) async {
        if isRefreshing {
            if reason != .automatic { queuedRefresh = true }
            return
        }

        isRefreshing = true

        do {
            let snapshot = try await queryClient.query()
            apply(snapshot)
        } catch {
            if let queryError = error as? LsofQueryError, case .unavailable = queryError {
                state = .unavailable(error.localizedDescription)
            } else {
                state = .failed(error.localizedDescription)
            }
        }

        isRefreshing = false

        if queuedRefresh {
            queuedRefresh = false
            await refresh(reason: .manual)
        }
    }

    private func apply(_ snapshot: PortSnapshot) {
        records = snapshot.records
        lastQueryDuration = snapshot.duration
        if !snapshot.isPartial {
            lastSuccessfulUpdate = snapshot.capturedAt
        }
        if isPaused {
            state = .paused
        } else if snapshot.isPartial {
            state = .partial("lsof 返回了部分结果；已展示可安全解析的数据。")
        } else {
            state = snapshot.records.isEmpty ? .empty : .ready
        }
    }

    private func occupantLabels(for record: PortRecord, in records: [PortRecord]) -> [String] {
        Array(Set(records.filter {
            $0.matchesPort(record) && $0.pid != record.pid
        }.map {
            "\($0.processName)（PID \($0.pid)）"
        })).sorted()
    }
}

private extension PortRecord {
    func matchesTarget(_ other: PortRecord) -> Bool {
        pid == other.pid
            && processName == other.processName
            && transport == other.transport
            && localAddress == other.localAddress
            && localPort == other.localPort
            && (executablePath == nil || other.executablePath == nil || executablePath == other.executablePath)
    }

    func matchesPort(_ other: PortRecord) -> Bool {
        transport == other.transport && localPort == other.localPort
    }
}
