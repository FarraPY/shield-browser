import AVKit
import SwiftUI
import WebKit

/// Una reproducción en el reproductor del iPhone. Vive en la pestaña (no en la
/// vista): así entrar/salir de pantalla completa no crea un segundo AVPlayer, y
/// al cerrar, abrir otro vídeo o cambiar de página se para de verdad.
/// Se envían el Referer, el User-Agent y las cookies de la página para que el
/// servidor acepte la petición.
@MainActor
final class NativePlayback: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    let video: NativeVideo
    let controller = AVPlayerViewController()
    @Published private(set) var failure: String?
    @Published private(set) var downloadStarted = false

    private weak var webView: WKWebView?
    private var statusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var stopped = false

    // Desplazar la página cuando el gesto empieza encima del vídeo.
    private var displayLink: CADisplayLink?
    private var velocity: CGFloat = 0
    private var lastTimestamp: CFTimeInterval = 0

    init(video: NativeVideo, webView: WKWebView) {
        self.video = video
        self.webView = webView
        super.init()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrollPage(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        controller.view.addGestureRecognizer(pan)

        loadTask = Task { [weak self] in await self?.load() }
    }

    /// Para el vídeo y suelta el reproductor (también si estaba en pantalla completa o PiP).
    func stop() {
        guard !stopped else { return }
        stopped = true
        loadTask?.cancel()
        stopScrolling()
        statusObservation = nil
        controller.player?.pause()
        controller.player?.replaceCurrentItem(with: nil)
        controller.player = nil
        if controller.presentedViewController != nil {
            controller.dismiss(animated: false)
        }
    }

    func startDownload() {
        guard !downloadStarted, let webView else { return }
        downloadStarted = true
        DownloadManager.shared.download(video.asMedia, from: webView)
    }

    private func load() async {
        guard let webView else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        guard !stopped, !Task.isCancelled else { return }
        var headers: [String: String] = [:]
        if let page = video.pageURL ?? webView.url { headers["Referer"] = page.absoluteString }
        if let userAgent { headers["User-Agent"] = userAgent }

        let asset = AVURLAsset(url: video.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetHTTPCookiesKey: cookies,
        ])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "error desconocido"
            Task { @MainActor in
                self?.failure = "No se pudo reproducir aquí (\(message))."
            }
        }
        if video.startTime > 1 {
            _ = await player.seek(to: CMTime(seconds: video.startTime, preferredTimescale: 600))
        }
        guard !stopped, !Task.isCancelled else { return }
        controller.player = player
        player.play()
    }

    // MARK: - Desplazamiento de la página

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              controller.presentedViewController == nil else { return false }   // no en pantalla completa
        let v = pan.velocity(in: pan.view)
        return abs(v.y) > abs(v.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func scrollPage(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopScrolling()
        case .changed:
            let dy = pan.translation(in: pan.view).y
            pan.setTranslation(.zero, in: pan.view)
            move(by: -dy)
        case .ended:
            velocity = -pan.velocity(in: pan.view).y
            guard abs(velocity) > 50 else { return }
            lastTimestamp = 0
            let link = CADisplayLink(target: self, selector: #selector(decelerate(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        default:
            break
        }
    }

    /// Inercia al soltar, como el scroll normal.
    @objc private func decelerate(_ link: CADisplayLink) {
        if lastTimestamp == 0 { lastTimestamp = link.timestamp; return }
        let dt = CGFloat(link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        let moved = move(by: velocity * dt)
        velocity *= pow(0.998, dt * 1000)
        if abs(velocity) < 20 || !moved { stopScrolling() }
    }

    /// Devuelve false si ya estaba en el principio/final de la página.
    @discardableResult
    private func move(by delta: CGFloat) -> Bool {
        guard let scroll = webView?.scrollView else { return false }
        let inset = scroll.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        let target = min(max(scroll.contentOffset.y + delta, minY), maxY)
        guard target != scroll.contentOffset.y else { return false }
        scroll.contentOffset.y = target
        return true
    }

    private func stopScrolling() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

/// Coloca el reproductor del iPhone justo encima del vídeo de la web (se
/// desplaza con la página). Si no se conoce la posición, aparece centrado.
struct InlinePlayerOverlay: View {
    @ObservedObject var playback: NativePlayback
    @ObservedObject var tab: BrowserTab
    @ObservedObject var placement: PlayerPlacement

    var body: some View {
        GeometryReader { geo in
            let frame = resolvedFrame(in: geo.size)
            NativePlayerView(playback: playback, onClose: close) {
                tab.setNativePlayer(false)
                close()
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
        }
        .ignoresSafeArea()
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { tab.nativeVideo = nil }
    }

    private func resolvedFrame(in size: CGSize) -> CGRect {
        if var frame = placement.frame, frame.width >= 140, size.width > 0 {
            // Vídeos casi planos (reproductores que aún no han calculado su altura).
            if frame.height < 90 { frame.size.height = frame.width * 9 / 16 }
            return frame
        }
        let width = size.width
        let height = min(width * 9 / 16, size.height)
        return CGRect(x: 0, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// Controles alrededor del AVPlayerViewController: descargar, más opciones y cerrar.
struct NativePlayerView: View {
    @ObservedObject var playback: NativePlayback
    var onClose: () -> Void
    var onUseWebPlayer: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black
                PlayerController(controller: playback.controller)
                if let failure = playback.failure {
                    VStack(spacing: 8) {
                        Text(failure).font(.footnote).multilineTextAlignment(.center)
                        HStack {
                            Button("Descargar") { playback.startDownload() }
                                .buttonStyle(.borderedProminent).tint(.orange)
                            Button("Reproductor de la web") { onUseWebPlayer() }
                                .buttonStyle(.bordered).tint(.white)
                        }
                        .font(.footnote)
                    }
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            }

            HStack(spacing: 14) {
                Button { playback.startDownload() } label: {
                    Image(systemName: playback.downloadStarted ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(playback.downloadStarted ? Color.green : Color.orange)
                }
                .disabled(playback.downloadStarted)
                .accessibilityLabel("Descargar vídeo")
                Menu {
                    Button { playback.startDownload() } label: {
                        Label("Descargar vídeo", systemImage: "arrow.down.circle")
                    }
                    ShareLink(item: playback.video.url) { Label("Compartir enlace del vídeo", systemImage: "link") }
                    Divider()
                    Button { onUseWebPlayer() } label: {
                        Label("Usar el reproductor de la web", systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Cerrar reproductor")
            }
            .font(.title3)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(6)
        }
        .overlay(alignment: .bottom) {
            if playback.downloadStarted {
                Text("Descargando… lo verás en Descargas")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 50)
                    .allowsHitTesting(false)
            }
        }
        // Gesto de "volver" desde el borde izquierdo: cierra el reproductor.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 15)
                        .onEnded { value in
                            if value.translation.width > 50 { onClose() }
                        }
                )
        }
        .clipped()
    }
}

/// Muestra siempre el mismo AVPlayerViewController de la reproducción, aunque
/// SwiftUI vuelva a crear la vista (p. ej. al volver de pantalla completa).
private struct PlayerController: UIViewControllerRepresentable {
    let controller: AVPlayerViewController

    func makeUIViewController(context: Context) -> AVPlayerViewController { controller }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
