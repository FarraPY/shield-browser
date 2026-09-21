import Foundation
import WebKit

/// Compila las listas de filtros incluidas en la app (Resources/Blocklists/*.json)
/// a WKContentRuleList. WebKit bloquea las peticiones antes de que salgan del
/// dispositivo, igual que un bloqueador de contenido de Safari.
@MainActor
final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    @Published private(set) var ruleLists: [WKContentRuleList] = []
    @Published private(set) var isReady = false
    @Published private(set) var status = "Preparando filtros…"
    @Published private(set) var ruleCount = 0
    @Published private(set) var droppedRules = 0

    /// Script cosmético/antianuncios que se inyecta en todas las páginas.
    let userScript: WKUserScript = {
        let url = Bundle.main.url(forResource: "shield", withExtension: "js")
        let source = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }()

    private var loading = false
    private let store = WKContentRuleListStore.default()!

    func load() async {
        guard !isReady, !loading else { return }
        loading = true
        let files = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Blocklists") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

        var lists: [WKContentRuleList] = []
        var identifiers: Set<String> = []
        for (index, file) in files.enumerated() {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let identifier = "\(file.deletingPathExtension().lastPathComponent)-\(version)-\(size)"
            identifiers.insert(identifier)
            status = "Compilando filtros \(index + 1)/\(files.count)…"

            if let cached = await lookUp(identifier) {
                lists.append(cached)
            } else if let data = try? Data(contentsOf: file),
                      let json = String(data: data, encoding: .utf8) {
                if let compiled = await compileSafely(identifier: identifier, json: json) {
                    lists.append(compiled)
                }
            }
            ruleCount += countRules(file)
        }
        await removeStale(keeping: identifiers)
        ruleLists = lists
        status = "\(ruleCount.formatted()) reglas activas"
        isReady = true
        loading = false
        NotificationCenter.default.post(name: .shieldRulesReady, object: nil)
    }

    // MARK: - Compilación robusta

    /// Si WebKit rechaza una lista por una regla inválida, localiza las reglas
    /// problemáticas por bisección y compila el resto.
    private func compileSafely(identifier: String, json: String) async -> WKContentRuleList? {
        if let list = try? await compile(identifier, json) { return list }
        guard let data = json.data(using: .utf8),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        status = "Revisando reglas…"
        let bad = await findBadRules(rules, range: 0..<rules.count)
        droppedRules += bad.count
        let good = rules.enumerated().filter { !bad.contains($0.offset) }.map(\.element)
        guard let goodData = try? JSONSerialization.data(withJSONObject: good),
              let goodJSON = String(data: goodData, encoding: .utf8) else { return nil }
        return try? await compile(identifier, goodJSON)
    }

    private func findBadRules(_ rules: [Any], range: Range<Int>) async -> Set<Int> {
        let slice = Array(rules[range])
        guard let data = try? JSONSerialization.data(withJSONObject: slice),
              let json = String(data: data, encoding: .utf8) else { return Set(range) }
        let probe = "probe-\(range.lowerBound)-\(range.upperBound)"
        if (try? await compile(probe, json)) != nil {
            await remove(probe)
            return []
        }
        if range.count == 1 { return [range.lowerBound] }
        let mid = range.lowerBound + range.count / 2
        let left = await findBadRules(rules, range: range.lowerBound..<mid)
        let right = await findBadRules(rules, range: mid..<range.upperBound)
        return left.union(right)
    }

    private func countRules(_ file: URL) -> Int {
        // Aproximación barata: una regla por cada "trigger".
        guard let data = try? Data(contentsOf: file) else { return 0 }
        let needle = Data("\"trigger\"".utf8)
        var count = 0
        var start = data.startIndex
        while let found = data.range(of: needle, in: start..<data.endIndex) {
            count += 1
            start = found.upperBound
        }
        return count
    }

    // MARK: - Envoltorios del WKContentRuleListStore

    private func compile(_ identifier: String, _ json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? CocoaError(.featureUnsupported)) }
            }
        }
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func remove(_ identifier: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }

    private func removeStale(keeping identifiers: Set<String>) async {
        let existing: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for id in existing where !identifiers.contains(id) {
            await remove(id)
        }
    }
}

extension Notification.Name {
    static let shieldRulesReady = Notification.Name("shieldRulesReady")
}
