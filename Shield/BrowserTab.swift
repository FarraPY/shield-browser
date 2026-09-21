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

    /// Lo asigna TabManager para abrir ventanas nuevas como pestañas.
    var onOpenInNewTab: ((URLRequest) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var appliedShields: Bool?

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
        if let body = message.body as? [String: Any], let hidden = body["hidden"] as? Int {
            cosmeticBlocked = max(cosmeticBlocked, hidden)
        }
    }
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
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// Enlaces con target="_blank": se abren en la misma pestaña; los pop-ups
    /// automáticos ya están bloqueados por javaScriptCanOpenWindowsAutomatically.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
        } else {
            // window.open() tras un toque del usuario (p. ej. login): nueva pestaña
            onOpenInNewTab?(navigationAction.request)
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
