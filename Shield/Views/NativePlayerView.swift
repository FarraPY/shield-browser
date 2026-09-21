import AVKit
import SwiftUI
import WebKit

/// Reproductor del iPhone (AVPlayer) para cualquier vídeo de la web, con
/// descarga, Picture in Picture y AirPlay. Se envían el Referer, el User-Agent
/// y las cookies de la página para que el servidor acepte la petición.
struct NativePlayerView: View {
    let video: NativeVideo
    let webView: WKWebView
    var onUseWebPlayer: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var downloadStarted = false
    @State private var failure: String?
    @State private var statusObservation: NSKeyValueObservation?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.title3.bold())
                }
                Text(video.title.isEmpty ? (video.url.host() ?? "Vídeo") : video.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button { startDownload() } label: {
                        Label("Descargar vídeo", systemImage: "arrow.down.circle")
                    }
                    ShareLink(item: video.url) { Label("Compartir enlace del vídeo", systemImage: "link") }
                    Divider()
                    Button {
                        onUseWebPlayer()
                        dismiss()
                    } label: {
                        Label("Usar el reproductor de la web", systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                Button { startDownload() } label: {
                    Image(systemName: downloadStarted ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(downloadStarted ? Color.green : Color.orange)
                }
                .disabled(downloadStarted)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ZStack {
                if let player {
                    PlayerController(player: player)
                } else if failure == nil {
                    ProgressView().tint(.white)
                }
                if let failure {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(failure).multilineTextAlignment(.center)
                        Button("Descargar de todos modos") { startDownload() }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }
                    .foregroundStyle(.white)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if downloadStarted {
                Text("Descargando… lo verás en Descargas y en Fotos")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.vertical, 8)
            }
        }
        .background(Color.black.ignoresSafeArea())
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
