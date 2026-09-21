import Foundation

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo, brave, google, startpage

    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave Search"
        case .google: "Google"
        case .startpage: "Startpage"
        }
    }

    func searchURL(_ query: String) -> URL? {
        var components: URLComponents
        switch self {
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")!
        case .brave: components = URLComponents(string: "https://search.brave.com/search")!
        case .google: components = URLComponents(string: "https://www.google.com/search")!
        case .startpage: components = URLComponents(string: "https://www.startpage.com/do/search")!
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

enum ShieldSettings {
    static let searchEngineKey = "searchEngine"
    static let globalShieldsKey = "globalShields"
    static let nativePlayerKey = "nativePlayer"
    private static let disabledHostsKey = "shieldsDisabledHosts"
    private static var defaults: UserDefaults { .standard }

    static var searchEngine: SearchEngine {
        SearchEngine(rawValue: defaults.string(forKey: searchEngineKey) ?? "") ?? .duckDuckGo
    }

    static var globalShields: Bool {
        defaults.object(forKey: globalShieldsKey) as? Bool ?? true
    }

    static var nativePlayer: Bool {
        defaults.object(forKey: nativePlayerKey) as? Bool ?? true
    }

    static var disabledHosts: Set<String> {
        Set(defaults.stringArray(forKey: disabledHostsKey) ?? [])
    }

    static func shieldsEnabled(for host: String?) -> Bool {
        guard globalShields else { return false }
        guard let host = normalized(host) else { return true }
        return !disabledHosts.contains(host)
    }

    static func setShields(_ enabled: Bool, for host: String) {
        guard let host = normalized(host) else { return }
        var hosts = disabledHosts
        if enabled { hosts.remove(host) } else { hosts.insert(host) }
        defaults.set(Array(hosts).sorted(), forKey: disabledHostsKey)
    }

    static func resetSiteExceptions() {
        defaults.removeObject(forKey: disabledHostsKey)
    }

    private static func normalized(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

enum URLBuilder {
    /// Convierte lo escrito en la barra en una URL: dirección directa o búsqueda.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about", "file"].contains(scheme) {
            return url
        }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://" + text), url.host() != nil {
            return url
        }
        return ShieldSettings.searchEngine.searchURL(text)
    }

    /// Dominio registrable aproximado: "img.foro.com.ar" → "foro.com.ar".
    static func baseDomain(_ host: String?) -> String {
        var h = (host ?? "").lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let parts = h.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return h }
        let secondLevel = ["co", "com", "net", "org", "gov", "gob", "edu", "ac", "nic", "or", "ne", "go", "mil"]
        let twoLevel = secondLevel.contains(parts[parts.count - 2]) && parts[parts.count - 1].count == 2
        return parts.suffix(twoLevel ? 3 : 2).joined(separator: ".")
    }

    static func sameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let a = a?.host(), let b = b?.host() else { return false }
        return baseDomain(a) == baseDomain(b)
    }
}
