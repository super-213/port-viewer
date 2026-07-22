import Foundation
import Observation

@MainActor
@Observable
final class MenuBarViewModel {
    var searchText = ""

    @ObservationIgnored private let portViewModel: PortViewModel
    private let maximumRecordCount = 10

    init(portViewModel: PortViewModel) {
        self.portViewModel = portViewModel
    }

    var displayedRecords: [PortRecord] {
        let sorted = portViewModel.records.filter(\.isListening).sorted {
            if $0.localPortSortValue != $1.localPortSortValue {
                return $0.localPortSortValue < $1.localPortSortValue
            }
            return $0.processName.localizedStandardCompare($1.processName) == .orderedAscending
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Array(sorted.prefix(maximumRecordCount))
        }
        return Array(sorted.filter { PortSearch.rank(of: $0, query: query) != nil }.prefix(maximumRecordCount))
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
