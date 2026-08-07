import Foundation
import Observation

enum NetworkScanRunState: Equatable {
    case idle
    case running
    case finished
    case cancelled
    case failed(String)
}

enum ScanTimeoutOption: Double, CaseIterable, Identifiable {
    case fast = 0.3
    case balanced = 0.7
    case patient = 1.5

    var id: Self { self }

    var title: String {
        switch self {
        case .fast: return "快速 · 0.3 秒"
        case .balanced: return "平衡 · 0.7 秒"
        case .patient: return "耐心 · 1.5 秒"
        }
    }
}

@MainActor
@Observable
final class NetworkScanViewModel {
    var scope: NetworkScanScope = .host
    var target = ""
    var portPreset: ScanPortPreset = .common
    var customPorts = "22,80,443"
    var timeoutOption: ScanTimeoutOption = .balanced

    private(set) var state: NetworkScanRunState = .idle
    private(set) var progress = NetworkScanProgress(
        completedCount: 0,
        totalCount: 0,
        openCount: 0,
        currentEndpoint: nil
    )
    private(set) var report: NetworkScanReport?
    private(set) var validationMessage: String?

    @ObservationIgnored private let scanner: any NetworkScanning
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = UUID()

    init(scanner: any NetworkScanning) {
        self.scanner = scanner
    }

    deinit {
        scanTask?.cancel()
    }

    var isRunning: Bool { state == .running }
    var openPorts: [OpenPortResult] { report?.openPorts ?? [] }

    var stateTitle: String {
        switch state {
        case .idle: return "准备扫描"
        case .running: return "正在扫描"
        case .finished where openPorts.isEmpty: return "未探测到开放端口"
        case .finished: return "扫描完成"
        case .cancelled: return "扫描已取消"
        case .failed: return "扫描失败"
        }
    }

    var stateDescription: String {
        switch state {
        case .idle:
            return "选择单台主机或 IPv4 网段，并指定要探测的 TCP 端口。"
        case .running:
            return "已完成 \(progress.completedCount.formatted()) / \(progress.totalCount.formatted())，发现 \(progress.openCount) 个开放端口。"
        case .finished:
            guard let report else { return "扫描已经完成。" }
            if report.openPorts.isEmpty {
                return "目标可能关闭了这些端口，也可能被防火墙过滤或未在超时时间内响应。"
            }
            return "在 \(report.hostsWithOpenPorts) 台主机上发现 \(report.openPorts.count) 个开放端口，用时 \(report.duration.formatted(.number.precision(.fractionLength(1)))) 秒。"
        case .cancelled:
            return "已经停止新的连接探测；取消前的临时结果未作为完整报告保存。"
        case .failed(let message):
            return message
        }
    }

    func startScan() {
        let plan: NetworkScanPlan
        do {
            plan = try NetworkScanPlan.make(
                scope: scope,
                target: target,
                preset: portPreset,
                customPorts: customPorts,
                timeout: timeoutOption.rawValue
            )
        } catch {
            validationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        cancelScan(markCancelled: false)
        validationMessage = nil
        report = nil
        state = .running
        progress = NetworkScanProgress(
            completedCount: 0,
            totalCount: plan.totalProbeCount,
            openCount: 0,
            currentEndpoint: nil
        )

        let generation = UUID()
        scanGeneration = generation
        let scanner = scanner
        let progressSink = NetworkScanProgressSink(viewModel: self, generation: generation)
        scanTask = Task { [weak self] in
            do {
                let report = try await scanner.scan(plan: plan) { progress in
                    progressSink.send(progress)
                }
                guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
                self.report = report
                self.state = .finished
                self.scanTask = nil
            } catch is CancellationError {
                guard let self, self.scanGeneration == generation else { return }
                self.state = .cancelled
                self.scanTask = nil
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.state = .failed(error.localizedDescription)
                self.scanTask = nil
            }
        }
    }

    func cancelScan() {
        cancelScan(markCancelled: true)
    }

    func clearResults() {
        guard !isRunning else { return }
        report = nil
        validationMessage = nil
        state = .idle
        progress = NetworkScanProgress(
            completedCount: 0,
            totalCount: 0,
            openCount: 0,
            currentEndpoint: nil
        )
    }

    private func cancelScan(markCancelled: Bool) {
        guard let scanTask else { return }
        scanGeneration = UUID()
        scanTask.cancel()
        self.scanTask = nil
        if markCancelled { state = .cancelled }
    }

    fileprivate func acceptProgress(_ progress: NetworkScanProgress, generation: UUID) {
        guard scanGeneration == generation else { return }
        self.progress = progress
    }
}

private final class NetworkScanProgressSink: @unchecked Sendable {
    private weak var viewModel: NetworkScanViewModel?
    private let generation: UUID

    @MainActor
    init(viewModel: NetworkScanViewModel, generation: UUID) {
        self.viewModel = viewModel
        self.generation = generation
    }

    func send(_ progress: NetworkScanProgress) {
        Task { @MainActor [weak self] in
            guard let self,
                  let viewModel = self.viewModel else { return }
            viewModel.acceptProgress(progress, generation: self.generation)
        }
    }
}
