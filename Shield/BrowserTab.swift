import SwiftUI
import WebKit

/// Posición en pantalla del reproductor del iPhone, encima del vídeo de la web.
/// Va aparte de BrowserTab para que el desplazamiento no redibuje toda la pestaña.
@MainActor
final class PlayerPlacement: ObservableObject {
    @Published var frame: CGRect?
}

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
    @Published var nativeVideo: NativeVideo? {
        didSet {
            // Una sola reproducción a la vez: la anterior se para siempre.
            if oldValue?.id != nativeVideo?.id {
                playback?.stop()
                playback = nativeVideo.map { NativePlayback(video: $0, webView: webView) }
            }
            updatePlayerFrame()
        }
    }
    private(set) var playback: NativePlayback?
    @Published private(set) var snapshot: UIImage?
    let playerPlacement = PlayerPlacement()

    /// Lo asigna TabManager para abrir ventanas nuevas como pestañas.
    var onOpenInNewTab: ((URLRequest) -> Void)?
    /// Lo asigna TabManager: cerrar esta pestaña (deslizar desde el borde sin historial atrás).
    var onRequestClose: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var appliedShields: Bool?
    private var approvedPopups: [String: Date] = [:]

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        let config = WKWebViewConfiguration()
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all      // sin autoplay
        config.upgradeKnownHostsToHTTPS = true
        config.ignoresViewportScaleLimits = true                    // pinch-to-zoom en todas las webs
        config.preferences.javaScriptCanOpenWindowsAutomatically = false // bloquea pop-ups
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.bouncesZoom = true
        config.userContentController.add(ScriptMessageProxy(self), name: "shield")

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        // Deslizar desde el borde izquierdo sin historial atrás → cerrar la pestaña.
        let edgePan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwipe(_:)))
        edgePan.edges = .left
        edgePan.delegate = self
        webView.addGestureRecognizer(edgePan)

        observe()
        applyShields(for: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rulesReady),
                                               name: .shieldRulesReady, object: nil)
    }

    // MARK: - Navegación

    func load(_ input: String) {
        guard let target = URLBuilder.url(from: input) else { return }
        if !isPrivate, URLBuilder.isSearch(input) { HistoryStore.shared.recordSearch(input) }
        applyShields(for: target.host())
        webView.load(URLRequest(url: target))
    }

    /// Abre una dirección en esta misma pestaña (enlaces que la web quería abrir en otra ventana).
    func open(_ request: URLRequest) {
        applyShields(for: request.url?.host())
        webView.load(request)
    }

    func reload() {
        applyShields(for: webView.url?.host(), force: true)
        webView.reload()
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stop() { webView.stopLoading() }

    /// Pausa vídeos y audio (p. ej. al cerrar la pestaña con opción de deshacer).
    func pauseMedia() {
        nativeVideo = nil
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        reload()
        sender.endRefreshing()
    }

    @objc private func rulesReady() {
        applyShields(for: webView.url?.host(), force: true)
    }

    // MARK: - Miniatura para la vista de pestañas

    func captureSnapshot() {
        guard url != nil, webView.window != nil else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 360
        Task {
            if let image = try? await webView.takeSnapshot(configuration: config) {
                snapshot = image
            }
        }
    }

    // MARK: - Gesto de cerrar pestaña

    @objc private func edgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let width = max(webView.bounds.width, 1)
        let dx = max(0, gesture.translation(in: webView).x)
        switch gesture.state {
        case .changed:
            webView.transform = CGAffineTransform(translationX: dx * 0.7, y: 0)
            webView.alpha = 1 - min(dx / width, 1) * 0.6
        case .ended:
            let velocity = gesture.velocity(in: webView).x
            if dx > width * 0.35 || (velocity > 700 && dx > 40) {
                UIView.animate(withDuration: 0.18, animations: {
                    self.webView.transform = CGAffineTransform(translationX: width, y: 0)
                    self.webView.alpha = 0
                }, completion: { _ in
                    self.onRequestClose?()
                    self.webView.transform = .identity
                    self.webView.alpha = 1
                })
            } else {
                resetSwipe()
            }
        case .cancelled, .failed:
            resetSwipe()
        default:
            break
        }
    }

    private func resetSwipe() {
        UIView.animate(withDuration: 0.2) {
            self.webView.transform = .identity
            self.webView.alpha = 1
        }
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
            let flag = "window.__shieldNativePlayer = \(ShieldSettings.nativePlayer);"
            controller.addUserScript(WKUserScript(source: flag, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
            controller.addUserScript(ContentBlocker.shared.userScript)
        }
    }

    /// Activa/desactiva el reproductor nativo en la página actual y las siguientes.
    func setNativePlayer(_ on: Bool) {
        webView.evaluateJavaScript("window.__shieldSetNative && window.__shieldSetNative(\(on)); 0",
                                   completionHandler: nil)
        applyShields(for: webView.url?.host(), force: true)
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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.title = wv.title ?? ""
                    if !self.isPrivate, let url = wv.url {
                        HistoryStore.shared.updateTitle(self.title, for: url)
                    }
                }
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
            // El reproductor del iPhone sigue al vídeo al desplazar o hacer zoom.
            webView.scrollView.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updatePlayerFrame() }
            },
            webView.scrollView.observe(\.zoomScale) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updatePlayerFrame() }
            },
        ]
    }

    /// Convierte la posición del vídeo en la página (px CSS) a puntos del WKWebView.
    private func updatePlayerFrame() {
        guard let rect = nativeVideo?.pageRect else {
            if playerPlacement.frame != nil { playerPlacement.frame = nil }
            return
        }
        let scroll = webView.scrollView
        let zoom = scroll.zoomScale
        playerPlacement.frame = CGRect(x: rect.minX * zoom - scroll.contentOffset.x,
                                       y: rect.minY * zoom - scroll.contentOffset.y,
                                       width: rect.width * zoom, height: rect.height * zoom)
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
        // Enlace que la web abría en una ventana en blanco: se abre aquí mismo.
        if message.frameInfo.isMainFrame,
           let url = (body["openHere"] as? String).flatMap({ URL(string: $0) }),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            open(URLRequest(url: url))
        }
        if let video = NativeVideo(body) {
            nativeVideo = video
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

    /// Se anota sin molestar: el contador y el último pop-up están en el panel del escudo.
    private func noteBlockedPopup(_ url: URL) {
        popupsBlocked += 1
        if url.absoluteString != "about:blank" || blockedPopup == nil {
            blockedPopup = url
        }
    }

    /// El usuario decide abrir el último pop-up bloqueado desde el panel del escudo.
    func openBlockedPopup() {
        guard let url = blockedPopup, ["http", "https"].contains(url.scheme ?? "") else { return }
        blockedPopup = nil
        open(URLRequest(url: url))
    }

    /// Enlaces "nueva ventana" permitidos: en la misma pestaña, salvo ventanitas
    /// con tamaño propio (inicio de sesión con Google, Apple…), que necesitan su opener.
    private func openAllowed(_ request: URLRequest, features: WKWindowFeatures?) {
        if features?.width != nil || features?.height != nil {
            onOpenInNewTab?(request)
        } else {
            open(request)
        }
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

// MARK: - UIGestureRecognizerDelegate

extension BrowserTab: UIGestureRecognizerDelegate {
    /// Si hay historial atrás, manda el gesto nativo de WebKit (volver).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !webView.canGoBack && url != nil && onRequestClose != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // <a download>, archivos generados en la página (blob:/data:, p. ej. MEGA)
        if navigationAction.shouldPerformDownload { return .download }
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
        blockedPopup = nil
        media = []
        nativeVideo = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isPrivate, let url = webView.url {
            HistoryStore.shared.recordVisit(url: url, title: webView.title ?? "")
        }
    }

    /// Enlaces a archivos que la web no puede mostrar (zip, apk, pdf forzado…) → descarga.
    /// También los que llegan por un iframe oculto (MediaFire y similares).
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        guard navigationResponse.isForMainFrame else { return .allow }
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        if mime == "application/octet-stream" || mime == "application/force-download" {
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
    /// Ventanas nuevas (target="_blank" / window.open). Si el usuario tocó de verdad
    /// un enlace visible se abren en esta misma pestaña (se puede volver atrás con
    /// el gesto); el resto son pop-ups/pop-unders de anuncios y se bloquean en silencio.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        let request = navigationAction.request
        // Permitido: shield.js lo aprobó (toque real sobre un enlace visible) o es del mismo sitio.
        if isApprovedPopup(url) ||
            (navigationAction.navigationType == .linkActivated && URLBuilder.sameSite(url, webView.url)) {
            openAllowed(request, features: windowFeatures)
            return nil
        }
        // El permiso del script puede llegar unos milisegundos después que la petición.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            if self.isApprovedPopup(url) {
                self.openAllowed(request, features: windowFeatures)
            } else {
                self.noteBlockedPopup(url)
            }
        }
        return nil
    }

    /// Mantener pulsado un enlace: además de las opciones de WebKit, abrirlo en otra pestaña.
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let link = elementInfo.linkURL, ["http", "https"].contains(link.scheme?.lowercased() ?? "") else {
            completionHandler(nil)
            return
        }
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let newTab = UIAction(title: "Abrir en pestaña nueva",
                                  image: UIImage(systemName: "plus.square.on.square")) { _ in
                self?.onOpenInNewTab?(URLRequest(url: link))
            }
            return UIMenu(children: [newTab] + suggested)
        }
        completionHandler(configuration)
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
