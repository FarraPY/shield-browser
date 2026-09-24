import SwiftUI

@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID? {
        didSet {
            // Miniatura de la pestaña que se deja, para la vista de pestañas.
            if oldValue != selectedID, let old = tabs.first(where: { $0.id == oldValue }) {
                old.captureSnapshot()
            }
        }
    }
    /// Vista de pestañas abierta (la presenta BrowserView, que no cambia al cambiar de pestaña).
    @Published var showingTabs = false
    /// Pestaña cerrada hace un momento que todavía se puede recuperar.
    @Published private(set) var recentlyClosed: BrowserTab?

    private var closedIndex = 0
    private var placeholderID: UUID?
    private var undoTask: Task<Void, Never>?

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
        tab.onRequestClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeWithUndo(tab)
        }
        tabs.append(tab)
        selectedID = tab.id
        if let request { tab.webView.load(request) }
        return tab
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
    }

    /// Pestaña anterior/siguiente (deslizar sobre la barra de direcciones).
    func selectAdjacent(_ offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        let target = index + offset
        guard tabs.indices.contains(target) else { return }
        selectedID = tabs[target].id
    }

    func close(_ tab: BrowserTab) {
        tab.stop()
        tab.pauseMedia()
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty { newTab() }
        if !tabs.contains(where: { $0.id == selectedID }) {
            selectedID = tabs.last?.id
        }
    }

    /// Cierra la pestaña pero la guarda unos segundos para poder deshacer
    /// (con su historial y la página tal cual estaba).
    func closeWithUndo(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.pauseMedia()
        closedIndex = index
        tabs.remove(at: index)
        placeholderID = nil
        if tabs.isEmpty {
            placeholderID = newTab(isPrivate: tab.isPrivate).id
        } else if selectedID == tab.id {
            selectedID = tabs[min(max(index - 1, 0), tabs.count - 1)].id
        }
        recentlyClosed = tab
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissUndo()
        }
    }

    func undoClose() {
        guard let tab = recentlyClosed else { return }
        undoTask?.cancel()
        recentlyClosed = nil
        // Quitar la pestaña vacía que se abrió al cerrar la última.
        if let placeholderID, let empty = tabs.first(where: { $0.id == placeholderID }), empty.url == nil {
            tabs.removeAll { $0.id == placeholderID }
        }
        placeholderID = nil
        tabs.insert(tab, at: min(closedIndex, tabs.count))
        selectedID = tab.id
    }

    func dismissUndo() {
        undoTask?.cancel()
        recentlyClosed?.stop()
        recentlyClosed = nil
        placeholderID = nil
    }

    func closeAll(privateOnly: Bool? = nil) {
        let closing = tabs.filter { privateOnly == nil || $0.isPrivate == privateOnly }
        closing.forEach { $0.stop(); $0.pauseMedia() }
        let ids = Set(closing.map(\.id))
        tabs.removeAll { ids.contains($0.id) }
        if tabs.isEmpty {
            newTab()
        } else if !tabs.contains(where: { $0.id == selectedID }) {
            selectedID = tabs.last?.id
        }
    }
}
