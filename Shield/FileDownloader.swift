import Foundation
import UniformTypeIdentifiers

/// Cabeceras que un servidor de vídeo espera ver del navegador: Referer de la
/// página, User-Agent del WKWebView y las cookies de la sesión. Muchos
/// servidores (p. ej. erome) responden 403 si falta el Referer.
struct RequestContext: Sendable {
    let referer: URL?
    let userAgent: String?
    let cookies: [HTTPCookie]

    func request(for url: URL, cors: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if cors, let scheme = referer.scheme, let host = referer.host() {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let host = url.host()?.lowercased() ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}

/// Descarga directa de un archivo (vídeo, imagen, audio) con progreso.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var movedFile: URL?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    /// Descarga `request` y lo guarda en `folder` con un nombre razonable.
    func download(_ request: URLRequest, to folder: URL, suggestedName: String) async throws -> URL {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (temp, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                lock.lock(); self.continuation = continuation; lock.unlock()
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }

        // El servidor puede devolver una página de error en lugar del archivo.
        let http = response as? HTTPURLResponse
        let mime = response.mimeType?.lowercased() ?? ""
        if let status = http?.statusCode, !(200..<300).contains(status) {
            try? FileManager.default.removeItem(at: temp)
            throw HLSError(message: "El servidor rechazó la descarga (error \(status))")
        }
        if mime.hasPrefix("text/html") {
            try? FileManager.default.removeItem(at: temp)
            throw HLSError(message: "El servidor devolvió una página web en lugar del archivo")
        }

        var name = suggestedName
        if (name as NSString).pathExtension.isEmpty || mime.hasPrefix("video/") || mime.hasPrefix("image/") {
            if let ext = UTType(mimeType: mime)?.preferredFilenameExtension,
               (name as NSString).pathExtension.lowercased() != ext {
                let known = ["jpg", "jpeg", "png", "gif", "webp", "mp4", "mov", "m4v", "webm", "mp3", "m4a"]
                if !known.contains((name as NSString).pathExtension.lowercased()) {
                    name = (name as NSString).deletingPathExtension + "." + ext
                }
            }
        }
        let destination = DownloadManager.uniqueURL(in: folder, name: name)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // El archivo temporal se borra al salir de este método: hay que moverlo ya.
        let keep = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: keep)
        lock.lock(); movedFile = keep; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let file = movedFile
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else if let file, let response = task.response {
            continuation?.resume(returning: (file, response))
        } else {
            continuation?.resume(throwing: HLSError(message: "La descarga no se completó"))
        }
    }
}
