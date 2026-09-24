import CoreGraphics
import Foundation

/// Vídeo, audio o imagen detectado en la página por shield.js.
struct MediaItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case video, audio, image, file }

    let kind: Kind
    let url: URL
    let pageURL: URL?
    let poster: URL?
    let width: Int?
    let height: Int?
    let isHLS: Bool

    var id: String { kind.rawValue + url.absoluteString }

    init(kind: Kind, url: URL, pageURL: URL?, poster: URL? = nil, isHLS: Bool) {
        self.kind = kind
        self.url = url
        self.pageURL = pageURL
        self.poster = poster
        width = nil
        height = nil
        self.isHLS = isHLS || url.pathExtension.lowercased() == "m3u8"
    }

    init?(_ dict: [String: Any]) {
        guard let kindString = dict["kind"] as? String, let kind = Kind(rawValue: kindString),
              let urlString = dict["url"] as? String, let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        self.kind = kind
        self.url = url
        pageURL = (dict["page"] as? String).flatMap { URL(string: $0) }
        poster = (dict["poster"] as? String).flatMap { URL(string: $0) }
        width = dict["width"] as? Int
        height = dict["height"] as? Int
        isHLS = (dict["hls"] as? Bool ?? false) || url.pathExtension.lowercased() == "m3u8"
    }

    /// Nombre de archivo razonable para guardar.
    var fileName: String {
        let last = url.lastPathComponent
        let stem = (last as NSString).deletingPathExtension
        let base = stem.isEmpty || stem == "/" ? (url.host() ?? "descarga") : stem
        let clean = String(base.prefix(60)).replacingOccurrences(of: "/", with: "-")
        if isHLS { return clean }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { return clean + "." + ext }
        switch kind {
        case .image: return clean + ".jpg"
        case .audio: return clean + ".mp3"
        case .video: return clean + ".mp4"
        case .file: return clean
        }
    }

    var subtitle: String {
        var parts = [url.host() ?? ""]
        if isHLS { parts.append("Streaming HLS") }
        else if !url.pathExtension.isEmpty { parts.append(url.pathExtension.uppercased()) }
        if let width, let height { parts.append("\(width)×\(height)") }
        return parts.joined(separator: " · ")
    }
}

/// Vídeo que la web intentó reproducir y que se abre en el reproductor nativo.
struct NativeVideo: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let pageURL: URL?
    let poster: URL?
    let title: String
    let startTime: Double
    let isHLS: Bool
    /// Posición del vídeo en la página (px CSS, coordenadas del documento).
    var pageRect: CGRect?

    init?(_ dict: [String: Any]) {
        guard let s = dict["nativePlay"] as? String, let url = URL(string: s) else { return nil }
        self.url = url
        pageURL = (dict["page"] as? String).flatMap { URL(string: $0) }
        poster = (dict["poster"] as? String).flatMap { URL(string: $0) }
        title = dict["title"] as? String ?? ""
        startTime = dict["time"] as? Double ?? 0
        isHLS = dict["hls"] as? Bool ?? false
        if let r = dict["rect"] as? [Double], r.count == 4, r[2] > 0, r[3] > 0 {
            pageRect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }
    }

    init(_ media: MediaItem) {
        url = media.url
        pageURL = media.pageURL
        poster = media.poster
        title = media.fileName
        startTime = 0
        isHLS = media.isHLS
    }

    var asMedia: MediaItem {
        MediaItem(kind: .video, url: url, pageURL: pageURL, poster: poster, isHLS: isHLS)
    }
}
