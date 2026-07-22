import Foundation
import Observation

@MainActor
@Observable
final class MenuBarViewModel {
    var searchText = "" {
        didSet { cachedDisplayedRecords = nil }
    }

    @ObservationIgnored private let portViewModel: PortViewModel
    @ObservationIgnored private var cachedRecords: [PortRecord] = []
    @ObservationIgnored private var cachedListeningRecords: [PortRecord] = []
    @ObservationIgnored private var cachedDisplayedRecords: [PortRecord]?
    private let maximumRecordCount = 10

    init(portViewModel: PortViewModel) {
        self.portViewModel = portViewModel
    }

    var displayedRecords: [PortRecord] {
        let records = portViewModel.records
        if records != cachedRecords {
            cachedRecords = records
            cachedListeningRecords = records.filter(\.isListening).sorted {
                if $0.localPortSortValue != $1.localPortSortValue {
                    return $0.localPortSortValue < $1.localPortSortValue
                }
                return $0.processName.localizedStandardCompare($1.processName) == .orderedAscending
            }
            cachedDisplayedRecords = nil
        }

        if let cachedDisplayedRecords { return cachedDisplayedRecords }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayed: [PortRecord]
        guard !query.isEmpty else {
            displayed = Array(cachedListeningRecords.prefix(maximumRecordCount))
            cachedDisplayedRecords = displayed
            return displayed
        }
        displayed = Array(cachedListeningRecords.lazy.filter {
            PortSearch.rank(of: $0, query: query) != nil
        }.prefix(maximumRecordCount))
        cachedDisplayedRecords = displayed
        return displayed
    }

    var updateDescription: String {
        if portViewModel.isPaused { return "自动刷新已暂停" }
        if let issue = portViewModel.state.issueMessage { return issue }
        if let date = portViewModel.lastSuccessfulUpdate {
            return "已更新 \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "等待首次查询"
    }

    func clearSearch() {
        searchText = ""
    }
}
