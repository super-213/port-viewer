import Darwin
import Foundation
import Observation

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

struct AdaptiveRefreshPolicy {
    static func interval(
        base: TimeInterval,
        consecutiveUnchangedRefreshes: Int,
        maximum: TimeInterval
    ) -> TimeInterval {
        let stage = min(max(0, consecutiveUnchangedRefreshes) / 3, 3)
        let multiplier = pow(2, Double(stage))
        return min(base * multiplier, max(base, maximum))
    }
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
@Observable
final class PortViewModel {
    private(set) var records: [PortRecord] = []
    private(set) var state: QueryPresentationState = .loading
    private(set) var lastSuccessfulUpdate: Date?
    private(set) var lastQueryDuration: TimeInterval?
    private(set) var isRefreshing = false
    private(set) var isPaused = false
    private(set) var recentListenerActivity: [ListenerActivityKey: RecentPortActivityChange] = [:]
    var terminationPrompt: TerminationPrompt?
    var feedback: OperationFeedback?

    private enum RefreshReason {
        case automatic
        case manual
    }

    @ObservationIgnored private let queryService: any PortQuerying
    @ObservationIgnored private let processService: any ProcessControlling
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var manualRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var terminationTask: Task<Void, Never>?
    @ObservationIgnored private var activityFeedbackCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var queryCancellationTask: Task<Void, Never>?
    @ObservationIgnored private var queuedRefresh = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isMainWindowVisible = false
    @ObservationIgnored private var isMenuBarPanelVisible = false
    @ObservationIgnored private var didRequestInitialWindow = false
    @ObservationIgnored private var consecutiveUnchangedAutomaticRefreshes = 0
    @ObservationIgnored private var listenerActivitySnapshot = PortActivitySnapshot(
        connectionIDsByListener: [:],
        remoteEndpointsByListener: [:]
    )
    @ObservationIgnored private var hasListenerActivityBaseline = false
    @ObservationIgnored private let activityFeedbackLifetime: TimeInterval = 5

    init(
        queryService: any PortQuerying,
        processService: any ProcessControlling
    ) {
        self.queryService = queryService
        self.processService = processService
    }

    deinit {
        refreshLoop?.cancel()
        manualRefreshTask?.cancel()
        terminationTask?.cancel()
        activityFeedbackCleanupTask?.cancel()
        queryCancellationTask?.cancel()
    }

    private(set) var listeningCount = 0
    private(set) var activeConnectionCount = 0
    private(set) var otherNetworkActivityCount = 0

    var statusSymbolName: String {
        if isPaused { return "pause.circle" }
        switch state {
        case .failed, .unavailable, .partial: return "exclamationmark.triangle"
        default: return "network"
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshIfStale(maximumAge: 1)
        restartRefreshLoop()
    }

    func stop() {
        isRunning = false
        refreshLoop?.cancel()
        refreshLoop = nil
        manualRefreshTask?.cancel()
        manualRefreshTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        activityFeedbackCleanupTask?.cancel()
        activityFeedbackCleanupTask = nil

        queryCancellationTask?.cancel()
        let queryService = queryService
        queryCancellationTask = Task {
            await queryService.cancelCurrentQuery()
        }
    }

    func claimInitialWindowRequest() -> Bool {
        guard !didRequestInitialWindow else { return false }
        didRequestInitialWindow = true
        return true
    }

    func setMainWindowVisible(_ visible: Bool) {
        guard isMainWindowVisible != visible else { return }
        isMainWindowVisible = visible
        if visible {
            consecutiveUnchangedAutomaticRefreshes = 0
        }
        restartRefreshLoop()
        if visible {
            refreshIfStale(maximumAge: 1)
        }
    }

    func setMenuBarPanelVisible(_ visible: Bool) {
        guard isMenuBarPanelVisible != visible else { return }
        isMenuBarPanelVisible = visible
        if visible {
            consecutiveUnchangedAutomaticRefreshes = 0
        }
        restartRefreshLoop()
        if visible {
            refreshIfStale(maximumAge: 1)
        }
    }

    func refreshNow() {
        guard manualRefreshTask == nil else {
            queuedRefresh = true
            return
        }
        manualRefreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh(reason: .manual)
            manualRefreshTask = nil
        }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            refreshLoop?.cancel()
            refreshLoop = nil
            state = .paused
        } else {
            state = records.isEmpty ? .empty : .ready
            consecutiveUnchangedAutomaticRefreshes = 0
            restartRefreshLoop()
            refreshNow()
        }
    }

    func dismissFeedback() {
        feedback = nil
    }

    func listenerActivitySummary(for item: ReadablePortItem) -> ListenerActivitySummary? {
        ListenerActivitySummary.make(
            for: item,
            snapshot: listenerActivitySnapshot,
            recentChanges: recentListenerActivity
        )
    }

    func prepareToTerminate(_ staleRecord: PortRecord) {
        terminationTask?.cancel()
        terminationTask = Task { [weak self] in
            await self?.performPreparation(for: staleRecord)
        }
    }

    func confirmTermination(_ prompt: TerminationPrompt) {
        terminationTask?.cancel()
        terminationTask = Task { [weak self] in
            await self?.performTermination(prompt)
        }
    }

    #if DEBUG
    func refreshForTesting() async {
        await refresh(reason: .manual)
    }

    func waitForManualRefreshForTesting() async {
        await manualRefreshTask?.value
    }

    func waitForTerminationTaskForTesting() async {
        await terminationTask?.value
    }

    var hasScheduledAutomaticRefreshForTesting: Bool {
        refreshLoop != nil
    }
    #endif

    private func performPreparation(for staleRecord: PortRecord) async {
        guard staleRecord.belongsToCurrentUser else {
            feedback = OperationFeedback(
                kind: .error,
                message: "\(staleRecord.processName) 属于用户 \(staleRecord.user)。当前版本不申请管理员权限，无法结束其他用户的进程。"
            )
            return
        }

        do {
            let snapshot = try await queryService.query(policy: .fresh)
            _ = apply(snapshot)
            guard !snapshot.isPartial else {
                feedback = OperationFeedback(kind: .error, message: "最新查询结果不完整，无法安全校验进程与端口的关联。请重试。")
                return
            }

            guard let liveRecord = snapshot.records.first(where: { $0.matchesTarget(staleRecord) }) else {
                let processStillExists = processService.exists(pid: staleRecord.pid)
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
        } catch is CancellationError {
            return
        } catch {
            feedback = OperationFeedback(
                kind: .error,
                message: "无法完成操作前校验：\(error.localizedDescription) 未发送任何信号。"
            )
        }
    }

    private func performTermination(_ prompt: TerminationPrompt) async {
        terminationPrompt = nil

        let force = prompt.stage == .force
        if force && prompt.isCritical {
            feedback = OperationFeedback(kind: .error, message: "为避免系统异常，Port Viewer 禁止强制结束该关键系统进程。")
            return
        }

        do {
            try processService.send(signal: force ? SIGKILL : SIGTERM, to: prompt.record.pid)
        } catch {
            feedback = OperationFeedback(kind: .error, message: error.localizedDescription)
            return
        }

        do {
            try await Task.sleep(for: force ? .milliseconds(500) : .milliseconds(1_500))
            let snapshot = try await queryService.query(policy: .fresh)
            _ = apply(snapshot)

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

    private var currentRefreshInterval: TimeInterval? {
        let base: TimeInterval
        let maximum: TimeInterval
        if isMainWindowVisible {
            base = max(3, storedInterval(forKey: "foregroundRefreshInterval", defaultValue: 3))
            maximum = max(base, 10)
        } else if isMenuBarPanelVisible {
            base = 5
            maximum = 15
        } else {
            let stored = storedInterval(forKey: "backgroundRefreshInterval", defaultValue: 30)
            guard stored > 0 else { return nil }
            base = max(10, stored)
            maximum = max(base, 60)
        }

        return AdaptiveRefreshPolicy.interval(
            base: base,
            consecutiveUnchangedRefreshes: consecutiveUnchangedAutomaticRefreshes,
            maximum: maximum
        )
    }

    private func storedInterval(forKey key: String, defaultValue: TimeInterval) -> TimeInterval {
        guard let value = UserDefaults.standard.object(forKey: key) as? NSNumber else {
            return defaultValue
        }
        return value.doubleValue
    }

    private func restartRefreshLoop() {
        refreshLoop?.cancel()
        refreshLoop = nil

        guard isRunning, !isPaused, currentRefreshInterval != nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.currentRefreshInterval else { return }
                let tolerance: Duration = interval >= 30
                    ? .seconds(3)
                    : interval >= 10 ? .seconds(1) : .milliseconds(300)
                do {
                    try await Task.sleep(for: .seconds(interval), tolerance: tolerance)
                } catch {
                    return
                }
                guard !Task.isCancelled, let owner = self, !owner.isPaused else { return }
                await owner.refresh(reason: .automatic)
            }
        }
    }

    private func refreshIfStale(maximumAge: TimeInterval) {
        guard !isRefreshing, manualRefreshTask == nil else { return }
        if let lastSuccessfulUpdate,
           Date().timeIntervalSince(lastSuccessfulUpdate) <= maximumAge {
            return
        }
        refreshNow()
    }

    private func refresh(reason: RefreshReason) async {
        if isRefreshing {
            if reason != .automatic { queuedRefresh = true }
            return
        }

        isRefreshing = true

        do {
            let snapshot = try await queryService.query(policy: .reuseInFlight)
            let recordsChanged = apply(snapshot)
            if snapshot.isPartial || recordsChanged {
                consecutiveUnchangedAutomaticRefreshes = 0
            } else if reason == .automatic {
                consecutiveUnchangedAutomaticRefreshes = min(
                    consecutiveUnchangedAutomaticRefreshes + 1,
                    9
                )
            }
        } catch is CancellationError {
            // Cancellation belongs to the task owner and should not replace the last UI state.
        } catch {
            consecutiveUnchangedAutomaticRefreshes = 0
            let failureState: QueryPresentationState
            if let queryError = error as? LsofQueryError, case .unavailable = queryError {
                failureState = .unavailable(error.localizedDescription)
            } else {
                failureState = .failed(error.localizedDescription)
            }
            if state != failureState {
                state = failureState
            }
        }

        isRefreshing = false

        if queuedRefresh, !Task.isCancelled {
            queuedRefresh = false
            await refresh(reason: .manual)
        }
    }

    @discardableResult
    private func apply(_ snapshot: PortSnapshot) -> Bool {
        updateListenerActivity(with: snapshot)
        let recordsChanged = !records.elementsEqual(
            snapshot.records,
            by: { $0.hasSameSnapshotContent(as: $1) }
        )
        if recordsChanged {
            records = snapshot.records
            var nextListeningCount = 0
            var nextActiveConnectionCount = 0
            var nextOtherNetworkActivityCount = 0
            for record in snapshot.records {
                if record.isListening {
                    nextListeningCount += 1
                } else if record.isActiveConnection {
                    nextActiveConnectionCount += 1
                } else {
                    nextOtherNetworkActivityCount += 1
                }
            }
            listeningCount = nextListeningCount
            activeConnectionCount = nextActiveConnectionCount
            otherNetworkActivityCount = nextOtherNetworkActivityCount
        }
        lastQueryDuration = snapshot.duration
        if !snapshot.isPartial {
            lastSuccessfulUpdate = snapshot.capturedAt
        }
        let nextState: QueryPresentationState
        if isPaused {
            nextState = .paused
        } else if snapshot.isPartial {
            nextState = .partial("lsof 返回了部分结果；已展示可安全解析的数据。")
        } else {
            nextState = snapshot.records.isEmpty ? .empty : .ready
        }
        if state != nextState {
            state = nextState
        }
        return recordsChanged
    }

    private func updateListenerActivity(with snapshot: PortSnapshot) {
        // Partial lsof output can omit live sockets, so never treat it as evidence that a connection ended.
        guard !snapshot.isPartial else { return }

        let nextSnapshot = snapshot.activitySnapshot
        let removedExpiredActivity = removeExpiredListenerActivity(
            referenceDate: snapshot.capturedAt
        )
        var addedRecentActivity = false

        if hasListenerActivityBaseline {
            if nextSnapshot != listenerActivitySnapshot {
                let changes = nextSnapshot.changes(
                    comparedTo: listenerActivitySnapshot,
                    observedAt: snapshot.capturedAt
                )
                if !changes.isEmpty {
                    recentListenerActivity.merge(changes) { _, new in new }
                    addedRecentActivity = true
                }
                listenerActivitySnapshot = nextSnapshot
            }
        } else {
            hasListenerActivityBaseline = true
            listenerActivitySnapshot = nextSnapshot
        }

        if removedExpiredActivity || addedRecentActivity {
            scheduleActivityFeedbackCleanup()
        }
    }

    @discardableResult
    private func removeExpiredListenerActivity(referenceDate: Date = Date()) -> Bool {
        guard recentListenerActivity.values.contains(where: {
            referenceDate.timeIntervalSince($0.observedAt) >= activityFeedbackLifetime
        }) else { return false }

        let filtered = recentListenerActivity.filter {
            referenceDate.timeIntervalSince($0.value.observedAt) < activityFeedbackLifetime
        }
        recentListenerActivity = filtered
        return true
    }

    private func scheduleActivityFeedbackCleanup() {
        activityFeedbackCleanupTask?.cancel()
        activityFeedbackCleanupTask = nil
        guard let nextExpiration = recentListenerActivity.values
            .map({ $0.observedAt.addingTimeInterval(activityFeedbackLifetime) })
            .min() else { return }

        let delay = max(0, nextExpiration.timeIntervalSinceNow)
        activityFeedbackCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            removeExpiredListenerActivity()
            scheduleActivityFeedbackCleanup()
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
    func hasSameSnapshotContent(as other: PortRecord) -> Bool {
        processName == other.processName
            && pid == other.pid
            && user == other.user
            && fileDescriptor == other.fileDescriptor
            && ipVersion == other.ipVersion
            && transport == other.transport
            && localAddress == other.localAddress
            && localPort == other.localPort
            && remoteAddress == other.remoteAddress
            && remotePort == other.remotePort
            && state == other.state
            && executablePath == other.executablePath
            && parentPID == other.parentPID
    }

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
