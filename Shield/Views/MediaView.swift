import SwiftUI

/// Todo lo descargable de la página actual, aunque el reproductor de la web
/// no permita mantener pulsado.
struct MediaView: View {
    @ObservedObject var tab: BrowserTab
    @Environment(\.dismiss) private var dismiss
    @State private var started: Set<String> = []

    private var videos: [MediaItem] { tab.media.filter { $0.kind != .image } }
    private var images: [MediaItem] { tab.media.filter { $0.kind == .image } }

    var body: some View {
        NavigationStack {
            List {
                if tab.media.isEmpty {
                    ContentUnavailableView(
                        "Nada detectado todavía",
                        systemImage: "arrow.down.circle",
                        description: Text("Reproduce el vídeo unos segundos (o desplázate para que carguen las imágenes) y desliza hacia abajo para buscar de nuevo."))
                }

                if !videos.isEmpty {
                    Section("Vídeos y audio") {
                        ForEach(videos) { item in
                            HStack(spacing: 12) {
                                Thumbnail(url: item.poster, icon: item.kind == .audio ? "waveform" : "film")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.fileName).lineLimit(1)
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if item.kind == .video {
                                    Button { play(item) } label: {
                                        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.orange)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                downloadButton(item)
                            }
                        }
                    }
                }

                if !images.isEmpty {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                            ForEach(images) { item in
                                Button { start(item) } label: {
                                    Thumbnail(url: item.url, icon: "photo", size: 96)
                                        .overlay(alignment: .bottomTrailing) {
                                            Image(systemName: started.contains(item.id) ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.white, started.contains(item.id) ? Color.green : Color.orange)
                                                .padding(4)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        HStack {
                            Text("Imágenes (\(images.count))")
                            Spacer()
                            Button("Descargar todas") { images.forEach { start($0) } }
                                .font(.caption.bold())
                        }
                    }
                }
            }
            .refreshable { tab.scanMedia() }
            .navigationTitle("Descargar de esta página")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { DownloadsView() } label: { Label("Descargas", systemImage: "tray.and.arrow.down") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() } }
            }
            .onAppear { tab.scanMedia() }
        }
    }

    private func downloadButton(_ item: MediaItem) -> some View {
        Button { start(item) } label: {
            Image(systemName: started.contains(item.id) ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(started.contains(item.id) ? Color.green : Color.orange)
        }
        .buttonStyle(.borderless)
    }

    /// Abre el vídeo en el reproductor del iPhone (después de cerrar este panel).
    private func play(_ item: MediaItem) {
        dismiss()
        let tab = tab
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            tab.nativeVideo = NativeVideo(item)
        }
    }

    private func start(_ item: MediaItem) {
        guard !started.contains(item.id) else { return }
        started.insert(item.id)
        DownloadManager.shared.download(item, from: tab.webView)
    }
}

private struct Thumbnail: View {
    let url: URL?
    let icon: String
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12))
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: icon).foregroundStyle(.orange)
                    }
                }
            } else {
                Image(systemName: icon).foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
