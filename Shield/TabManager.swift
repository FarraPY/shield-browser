import SwiftUI

@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?

    init() {
        newTab()
    }

    var current: BrowserTab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    @discardableResult
    func newTab(isPrivate: Bool = false, request: URLRequest? = nil) -> BrowserTab {
        let tab = BrowserTab(isPrivate: isPrivate)
        tab.onOpenInNewTab = { [weak self, weak tab] request in
            self?.newTab(isPrivate: tab?.isPrivate ?? false, request: request)
        }
        tabs.append(tab)
        selectedID = tab.id
        if let request { tab.webView.load(request) }
        return tab
    }

    func close(_ tab: BrowserTab) {
        tab.stop()
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty { newTab() }
        if !tabs.contains(where: { $0.id == selectedID }) {
            selectedID = tabs.last?.id
        }
    }

    func closeAll() {
        tabs.forEach { $0.stop() }
        tabs.removeAll()
        newTab()
    }
}
