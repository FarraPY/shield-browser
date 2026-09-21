import Foundation
import Photos
import UniformTypeIdentifiers
import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case finished(URL)
        case failed(String)
    }

    let id = UUID()
    let kind: MediaItem.Kind
    @Published var name: String
    @Published var progress: Double = 0
    @Published var state: State = .running {
        didSet { DownloadManager.shared.objectWillChange.send() }  // refresca contadores
    }
    @Published var note: String?

    fileprivate var destination: URL?
    fileprivate var observation: NSKeyValueObservation?
    fileprivate var task: Task<Void, Never>?
    fileprivate weak var download: WKDownload?

    init(name: String, kind: MediaItem.Kind) {
        self.name = name
        self.kind = kind
    }

    var isRunning: Bool { state == .running }

    func cancel() {
        download?.cancel { _ in }
        task?.cancel()
        if state == .running { state = .failed("Cancelada") }
    }
}

/// Descargas de archivos (WKDownload, con las cookies de la web) y de
/// streaming HLS. Los archivos quedan en Archivos → En mi iPhone → Shield.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static let autoSaveKey = "autoSaveToPhotos"

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var finishedCount = 0

    private var byDownload: [ObjectIdentifier: DownloadItem] = [:]

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var activeCount: Int { items.filter { $0.isRunning }.count }

    // MARK: - Iniciar descargas

    func download(_ media: MediaItem, from webView: WKWebView) {
        let item = DownloadItem(name: media.fileName, kind: media.kind)
        items.insert(item, at: 0)
        item.task = Task { [weak self] in
            let context = await Self.context(for: media, in: webView)
            do {
                let url: URL
                if media.isHLS {
                    url = try await HLSDownloader(context: context)
                        .download(playlist: media.url, to: Self.folder, baseName: media.fileName) { [weak item] value in
                            item?.progress = value
                        }
                } else {
                    let loader = FileDownloader { [weak item] value in
                        Task { @MainActor in item?.progress = value }
                    }
                    url = try await loader.download(context.request(for: media.url),
                                                    to: Self.folder, suggestedName: media.fileName)
                }
                item.name = url.lastPathComponent
                self?.finish(item, at: url)
            } catch is CancellationError {
                item.state = .failed("Cancelada")
            } catch let error as URLError where error.code == .cancelled {
                item.state = .failed("Cancelada")
            } catch {
                item.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Referer de la página, User-Agent real y cookies del WKWebView.
    private static func context(for media: MediaItem, in webView: WKWebView) async -> RequestContext {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        return RequestContext(referer: media.pageURL ?? webView.url, userAgent: userAgent, cookies: cookies)
    }

    /// Descargas iniciadas por la propia web (enlace a un archivo).
    func adopt(_ download: WKDownload, name: String?) {
        let item = DownloadItem(name: name ?? "Descarga", kind: .file)
        items.insert(item, at: 0)
        attach(download, to: item)
    }

    private func attach(_ download: WKDownload, to item: DownloadItem) {
        download.delegate = self
        item.download = download
        byDownload[ObjectIdentifier(download)] = item
        item.observation = download.progress.observe(\.fractionCompleted) { @Sendable [weak item] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in item?.progress = value }
        }
    }

    // MARK: - Final

    private func finish(_ item: DownloadItem, at url: URL) {
        item.progress = 1
        item.state = .finished(url)
        finishedCount += 1
        let autoSave = UserDefaults.standard.object(forKey: Self.autoSaveKey) as? Bool ?? true
        guard autoSave, Self.canSaveToPhotos(url) else {
            if url.pathExtension.lowercased() == "ts" {
                item.note = "Guardado en Archivos. Formato .ts: ábrelo con VLC o Infuse."
            } else {
                item.note = "Guardado en Archivos → Shield"
            }
            return
        }
        Task {
            item.note = await Self.saveToPhotos(url) ?? "Guardado en Fotos y en Archivos"
        }
    }

    func remove(_ item: DownloadItem) {
        item.cancel()
        items.removeAll { $0.id == item.id }
    }

    // MARK: - Utilidades

    nonisolated static func uniqueURL(in folder: URL, name: String) -> URL {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(cleaned)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func isVideo(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    static func canSaveToPhotos(_ url: URL) -> Bool { isImage(url) || isVideo(url) }

    /// Devuelve un mensaje de error, o nil si se guardó bien.
    static func saveToPhotos(_ url: URL) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "Sin permiso para Fotos (actívalo en Ajustes → Shield). Está en Archivos."
        }
        let photo = Self.isImage(url)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: photo ? .photo : .video, fileURL: url, options: nil)
            }
            return nil
        } catch {
            return "Fotos no admite este archivo; está guardado en Archivos → Shield."
        }
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let item = byDownload[ObjectIdentifier(download)]
        var name = suggestedFilename.isEmpty ? (item?.name ?? "descarga") : suggestedFilename
        if (name as NSString).pathExtension.isEmpty,
           let mime = response.mimeType,
           let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name += "." + ext
        }
        let destination = Self.uniqueURL(in: Self.folder, name: name)
        item?.destination = destination
        item?.name = destination.lastPathComponent
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.observation = nil
        if let destination = item.destination {
            finish(item, at: destination)
        } else {
            item.state = .failed("Sin destino")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.observation = nil
        if item.state == .running { item.state = .failed(error.localizedDescription) }
    }
}
