import Foundation

/// Página visitada (sólo pestañas normales; las privadas no dejan rastro).
struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    let url: URL
    var title: String
    var date: Date
}

/// Sugerencia de la barra de direcciones: búsqueda anterior o página del historial.
struct AddressSuggestion: Identifiable, Hashable {
    enum Kind { case search, page }
    let kind: Kind
    let text: String       // lo que se carga al pulsarla
    let title: String
    let subtitle: String?
    var id: String { "\(kind)-\(text)" }
}

/// Historial de páginas y de búsquedas, guardado en Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []   // más reciente primero
    @Published private(set) var searches: [String] = []        // más reciente primero

    private let maxEntries = 3000
    private let maxSearches = 300
    private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var entries: [HistoryEntry]
        var searches: [String]
    }

    nonisolated private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            entries = snapshot.entries
            searches = snapshot.searches
        }
    }

    // MARK: - Registro

    func recordVisit(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        // Recargar o volver a la misma página no crea una entrada nueva.
        if let first = entries.first, first.url == url {
            entries[0].date = Date()
            if !title.isEmpty { entries[0].title = title }
        } else {
            entries.insert(HistoryEntry(url: url, title: title, date: Date()), at: 0)
            if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        }
        scheduleSave()
    }

    /// Actualiza el título cuando la página lo cambia después de cargar.
    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let index = entries.prefix(20).firstIndex(where: { $0.url == url }),
              entries[index].title != title else { return }
        entries[index].title = title
        scheduleSave()
    }

    func recordSearch(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searches.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        searches.insert(text, at: 0)
        if searches.count > maxSearches { searches.removeLast(searches.count - maxSearches) }
        scheduleSave()
    }

    // MARK: - Borrado

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func deleteSearch(_ query: String) {
        searches.removeAll { $0 == query }
        scheduleSave()
    }

    func clear() {
        entries = []
        searches = []
        scheduleSave()
    }

    // MARK: - Sugerencias

    /// Búsquedas anteriores y páginas visitadas que coinciden con lo escrito.
    func suggestions(for input: String, limit: Int = 8) -> [AddressSuggestion] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [AddressSuggestion] = []
        var seen = Set<String>()

        let searchMatches = query.isEmpty
            ? Array(searches.prefix(5))
            : searches.filter { $0.lowercased().contains(query) }.prefix(4).map { $0 }
        for search in searchMatches where seen.insert("s" + search.lowercased()).inserted {
            result.append(AddressSuggestion(kind: .search, text: search, title: search, subtitle: nil))
        }

        guard !query.isEmpty else { return result }
        // Primero las que empiezan por lo escrito (dominio), luego las que lo contienen.
        let stripped = query.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        func host(_ e: HistoryEntry) -> String {
            (e.url.host() ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        }
        let prefixMatches = entries.filter { host($0).hasPrefix(stripped) }
        let containsMatches = entries.filter {
            !host($0).hasPrefix(stripped) &&
            ($0.title.lowercased().contains(query) || $0.url.absoluteString.lowercased().contains(stripped))
        }
        for entry in prefixMatches + containsMatches {
            guard result.count < limit else { break }
            let key = "p" + entry.url.absoluteString
            guard seen.insert(key).inserted else { continue }
            result.append(AddressSuggestion(kind: .page, text: entry.url.absoluteString,
                                            title: entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title,
                                            subtitle: entry.url.absoluteString))
        }
        return result
    }

    // MARK: - Guardado

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Snapshot(entries: entries, searches: searches)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: HistoryStore.fileURL, options: .atomic)
        }
    }
}
