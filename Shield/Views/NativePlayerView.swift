import AVKit
import SwiftUI
import WebKit

/// Coloca el reproductor del iPhone justo encima del vídeo de la web (se
/// desplaza con la página). Si no se conoce la posición, aparece centrado.
struct InlinePlayerOverlay: View {
    let video: NativeVideo
    @ObservedObject var tab: BrowserTab
    @ObservedObject var placement: PlayerPlacement

    var body: some View {
        GeometryReader { geo in
            let frame = resolvedFrame(in: geo.size)
            NativePlayerView(video: video, webView: tab.webView, onClose: close) {
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

/// Reproductor del iPhone (AVPlayer) para cualquier vídeo de la web, con
/// descarga, Picture in Picture y AirPlay. Se envían el Referer, el User-Agent
/// y las cookies de la página para que el servidor acepte la petición.
struct NativePlayerView: View {
    let video: NativeVideo
    let webView: WKWebView
    var onClose: () -> Void
    var onUseWebPlayer: () -> Void = {}

    @State private var player: AVPlayer?
    @State private var downloadStarted = false
    @State private var failure: String?
    @State private var statusObservation: NSKeyValueObservation?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black
                if let player {
                    PlayerController(player: player)
                } else if failure == nil {
                    ProgressView().tint(.white)
                }
                if let failure {
                    VStack(spacing: 8) {
                        Text(failure).font(.footnote).multilineTextAlignment(.center)
                        HStack {
                            Button("Descargar") { startDownload() }
                                .buttonStyle(.borderedProminent).tint(.orange)
                            Button("Reproductor de la web") { onUseWebPlayer() }
                                .buttonStyle(.bordered).tint(.white)
                        }
                        .font(.footnote)
                    }
                    .foregroundStyle(.white)
                    .padding(8)
                }
            }

            // Controles propios: descargar, más opciones y cerrar.
            HStack(spacing: 14) {
                Button { startDownload() } label: {
                    Image(systemName: downloadStarted ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(downloadStarted ? Color.green : Color.orange)
                }
                .disabled(downloadStarted)
                .accessibilityLabel("Descargar vídeo")
                Menu {
                    Button { startDownload() } label: {
                        Label("Descargar vídeo", systemImage: "arrow.down.circle")
                    }
                    ShareLink(item: video.url) { Label("Compartir enlace del vídeo", systemImage: "link") }
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
            if downloadStarted {
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
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func startDownload() {
        guard !downloadStarted else { return }
        downloadStarted = true
        DownloadManager.shared.download(video.asMedia, from: webView)
    }

    private func load() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        var headers: [String: String] = [:]
        if let page = video.pageURL ?? webView.url { headers["Referer"] = page.absoluteString }
        if let userAgent { headers["User-Agent"] = userAgent }

        let asset = AVURLAsset(url: video.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetHTTPCookiesKey: cookies,
        ])
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        statusObservation = item.observe(\.status) { item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "error desconocido"
            Task { @MainActor in
                failure = "No se pudo reproducir aquí (\(message))."
                player = nil
            }
        }
        if video.startTime > 1 {
            _ = await newPlayer.seek(to: CMTime(seconds: video.startTime, preferredTimescale: 600))
        }
        player = newPlayer
        newPlayer.play()
    }
}

private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.entersFullScreenWhenPlaybackBegins = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
