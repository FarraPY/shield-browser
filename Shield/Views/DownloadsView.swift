import SwiftUI
import QuickLook

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @State private var files: [URL] = []
    @State private var preview: URL?
    @State private var message: String?

    var body: some View {
        List {
            let pending = manager.items.filter { !isFinished($0) }
            if !pending.isEmpty {
                Section("En curso") {
                    ForEach(pending) { DownloadRow(item: $0) }
                }
            }
            Section {
                if files.isEmpty {
                    Text("Aún no hay descargas.").foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    FileRow(url: url, note: note(for: url))
                        .contentShape(Rectangle())
                        .onTapGesture { preview = url }
                        .swipeActions {
                            Button("Borrar", role: .destructive) { delete(url) }
                            ShareLink(item: url) { Label("Compartir", systemImage: "square.and.arrow.up") }
                                .tint(.blue)
                            if DownloadManager.canSaveToPhotos(url) {
                                Button { save(url) } label: { Label("Fotos", systemImage: "photo") }
                                    .tint(.orange)
                            }
                        }
                }
            } header: {
                Text("Guardadas")
            } footer: {
                Text("También están en la app Archivos → En mi iPhone → Shield. Desliza una descarga para guardarla en Fotos, compartirla o borrarla.")
            }
        }
        .navigationTitle("Descargas")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview, in: files)
        .onAppear(perform: reload)
        .onChange(of: manager.finishedCount) { _, _ in reload() }
        .alert("Fotos", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func isFinished(_ item: DownloadItem) -> Bool {
        if case .finished = item.state { return true }
        return false
    }

    private func note(for url: URL) -> String? {
        manager.items.first { $0.state == .finished(url) }?.note
    }

    private func reload() {
        let folder = DownloadManager.folder
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        files = urls
            .filter { !$0.hasDirectoryPath }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    private func save(_ url: URL) {
        Task {
            message = await DownloadManager.saveToPhotos(url) ?? "Guardado en Fotos ✓"
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name).lineLimit(1)
                Spacer()
                if item.isRunning {
                    Button { item.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            switch item.state {
            case .running:
                ProgressView(value: item.progress).tint(.orange)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.red)
            case .finished:
                EmptyView()
            }
        }
    }
}

private struct FileRow: View {
    let url: URL
    let note: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DownloadManager.isImage(url) ? "photo" :
                    (DownloadManager.isVideo(url) || url.pathExtension.lowercased() == "ts") ? "film" : "doc")
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).lineLimit(1)
                Text(note ?? size).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var size: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
