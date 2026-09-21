import SwiftUI
import WebKit

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView

    @Published var title = ""
    @Published var url: URL?
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var cosmeticBlocked = 0
    @Published private(set) var shieldsActive = true
    @Published var media: [MediaItem] = []
    @Published var blockedPopup: URL?
    @Published var popupsBlocked = 0

    /// Lo asigna TabManager para abrir ventanas nuevas como pestañas.
    var onOpenInNewTab: ((URLRequest) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var appliedShields: Bool?
    private var approvedPopups: [String: Date] = [:]
    private var popupBannerTask: Task<Void, Never>?

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        let config = WKWebViewConfiguration()
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all      // sin autoplay
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false // bloquea pop-ups
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.scrollView.keyboardDismissMode = .interactive
        config.userContentController.add(ScriptMessageProxy(self), name: "shield")

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        observe()
        applyShields(for: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rulesReady),
                                               name: .shieldRulesReady, object: nil)
    }

    // MARK: - Navegación

    func load(_ input: String) {
        guard let target = URLBuilder.url(from: input) else { return }
        applyShields(for: target.host())
        webView.load(URLRequest(url: target))
    }

    func reload() {
        applyShields(for: webView.url?.host(), force: true)
        webView.reload()
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stop() { webView.stopLoading() }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        reload()
        sender.endRefreshing()
    }

    @objc private func rulesReady() {
        applyShields(for: webView.url?.host(), force: true)
    }

    // MARK: - Escudos

    /// Activa o desactiva las listas de bloqueo según el sitio.
    func applyShields(for host: String?, force: Bool = false) {
        let enabled = ShieldSettings.shieldsEnabled(for: host)
        shieldsActive = enabled
        guard force || appliedShields != enabled else { return }
        appliedShields = enabled
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        controller.removeAllUserScripts()
        if enabled {
            for list in ContentBlocker.shared.ruleLists { controller.add(list) }
            controller.addUserScript(ContentBlocker.shared.userScript)
        }
    }

    func toggleShieldsForCurrentSite() {
        guard let host = webView.url?.host() else { return }
        ShieldSettings.setShields(!ShieldSettings.shieldsEnabled(for: host), for: host)
        reload()
    }

    // MARK: - KVO

    private func observe() {
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.title = wv.title ?? "" }
            },
            webView.observe(\.url) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.url = wv.url }
            },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
        ]
    }

    fileprivate func didReceive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let hidden = body["hidden"] as? Int {
            cosmeticBlocked = max(cosmeticBlocked, hidden)
        }
        if let url = body["allowPopup"] as? String {
            approvedPopups[url] = Date()
        }
        if let url = (body["popupBlocked"] as? String).flatMap({ URL(string: $0) }) {
            noteBlockedPopup(url)
        }
        if let list = body["media"] as? [[String: Any]] {
            addMedia(list.compactMap(MediaItem.init))
        }
    }

    // MARK: - Pop-ups

    private func isApprovedPopup(_ url: URL) -> Bool {
        approvedPopups = approvedPopups.filter { Date().timeIntervalSince($0.value) < 5 }
        return approvedPopups.removeValue(forKey: url.absoluteString) != nil
    }

    private func noteBlockedPopup(_ url: URL) {
        popupsBlocked += 1
        blockedPopup = url
        popupBannerTask?.cancel()
        popupBannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.blockedPopup = nil }
        }
    }

    /// El usuario decide abrir un pop-up bloqueado desde el aviso.
    func openBlockedPopup() {
        guard let url = blockedPopup, ["http", "https"].contains(url.scheme ?? "") else { return }
        blockedPopup = nil
        onOpenInNewTab?(URLRequest(url: url))
    }

    // MARK: - Contenido multimedia

    private func addMedia(_ items: [MediaItem]) {
        var known = Set(media.map(\.id))
        var added: [MediaItem] = []
        for item in items where !known.contains(item.id) {
            known.insert(item.id)
            added.append(item)
        }
        guard !added.isEmpty else { return }
        media = Array((media + added).prefix(400))
    }

    /// Pide a la página (y a sus iframes) que vuelva a buscar vídeos e imágenes.
    func scanMedia() {
        webView.evaluateJavaScript("window.__shieldScan && window.__shieldScan(); 0", completionHandler: nil)
    }

    var videoCount: Int { media.filter { $0.kind != .image }.count }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "data", "blob", "file"].contains(scheme) {
            if navigationAction.targetFrame?.isMainFrame ?? true {
                applyShields(for: url.host())
            }
            return .allow
        }
        // tel:, mailto:, maps:, itms-apps: … → abrir con la app del sistema
        if navigationAction.navigationType == .linkActivated {
            _ = await UIApplication.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cosmeticBlocked = 0
        popupsBlocked = 0
        media = []
    }

    /// Enlaces a archivos que la web no puede mostrar (zip, pdf forzado, etc.) → descarga.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, name: navigationResponse.response.suggestedFilename)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, name: navigationAction.request.url?.lastPathComponent)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// Ventanas nuevas (target="_blank" / window.open). Sólo se abren como
    /// pestaña si el usuario tocó de verdad un enlace visible; el resto son
    /// pop-ups/pop-unders de anuncios y se bloquean con un aviso para abrirlos.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        let request = navigationAction.request
        // Permitido: shield.js lo aprobó (toque real sobre un enlace visible) o es del mismo sitio.
        if isApprovedPopup(url) ||
            (navigationAction.navigationType == .linkActivated && URLBuilder.sameSite(url, webView.url)) {
            onOpenInNewTab?(request)
            return nil
        }
        // El permiso del script puede llegar unos milisegundos después que la petición.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            if self.isApprovedPopup(url) {
                self.onOpenInNewTab?(request)
            } else if self.blockedPopup != url {
                self.noteBlockedPopup(url)
            }
        }
        return nil
    }
}

/// Evita el ciclo de retención WKUserContentController → handler.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(_ tab: BrowserTab) { self.tab = tab }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { tab?.didReceive(message) }
    }
}
