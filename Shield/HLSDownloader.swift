import Foundation
import CommonCrypto

struct HLSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Descarga un vídeo en streaming HLS (.m3u8): elige la mejor calidad, baja
/// todos los segmentos (descifrando AES-128 si hace falta) y los une en un
/// único archivo (.mp4 si son fMP4, .ts si son MPEG-TS).
final class HLSDownloader: @unchecked Sendable {
    private struct Key: Sendable {
        let uri: URL
        let iv: Data?
    }

    private struct Segment: Sendable {
        let url: URL
        let key: Key?
        let sequence: Int
    }

    private let session: URLSession
    private let context: RequestContext

    init(context: RequestContext) {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
        self.context = context
    }

    func download(playlist: URL, to folder: URL, baseName: String,
                  progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let (mediaURL, text) = try await resolveMediaPlaylist(playlist)
        let (segments, initSegment) = try parse(text, base: mediaURL)
        guard !segments.isEmpty else {
            throw HLSError(message: "La lista no tiene segmentos (¿es una emisión en directo?)")
        }
        let firstExt = segments[0].url.pathExtension.lowercased()
        let isFMP4 = initSegment != nil || ["m4s", "mp4", "m4v", "cmfv"].contains(firstExt)
        let destination = DownloadManager.uniqueURL(in: folder, name: baseName + (isFMP4 ? ".mp4" : ".ts"))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        do {
            if let initSegment {
                try handle.write(contentsOf: try await get(initSegment))
            }
            var keyCache: [URL: Data] = [:]
            let batchSize = 6
            var index = 0
            while index < segments.count {
                let batch = Array(segments[index..<min(index + batchSize, segments.count)])
                let parts = try await withThrowingTaskGroup(of: (Int, Data).self) { group -> [Data] in
                    for (i, segment) in batch.enumerated() {
                        group.addTask { (i, try await self.get(segment.url)) }
                    }
                    var result = [Data](repeating: Data(), count: batch.count)
                    for try await (i, data) in group { result[i] = data }
                    return result
                }
                for (segment, data) in zip(batch, parts) {
                    var chunk = data
                    if let key = segment.key {
                        if keyCache[key.uri] == nil { keyCache[key.uri] = try await get(key.uri) }
                        chunk = try decrypt(chunk, key: keyCache[key.uri]!,
                                            iv: key.iv ?? Self.iv(for: segment.sequence))
                    }
                    try handle.write(contentsOf: chunk)
                }
                index += batch.count
                await progress(Double(index) / Double(segments.count))
            }
            try handle.close()
            return destination
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Red

    private func get(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let request = context.request(for: url, cors: true)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HLSError(message: "El servidor respondió \(http.statusCode)")
        }
        return data
    }

    // MARK: - Listas M3U8

    /// Si es una lista maestra, elige la variante de mayor calidad.
    private func resolveMediaPlaylist(_ url: URL) async throws -> (URL, String) {
        var current = url
        for _ in 0..<3 {
            let data = try await get(current)
            guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
                throw HLSError(message: "No es una lista HLS válida")
            }
            guard text.contains("#EXT-X-STREAM-INF") else { return (current, text) }

            let lines = text.components(separatedBy: .newlines)
            var best: (bandwidth: Int, url: URL)?
            for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
                let bandwidth = Int(Self.attributes(line)["BANDWIDTH"] ?? "") ?? 0
                let uriLine = lines[(i + 1)...].first {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    return !t.isEmpty && !t.hasPrefix("#")
                }
                if let uriLine,
                   let variant = URL(string: uriLine.trimmingCharacters(in: .whitespaces), relativeTo: current)?.absoluteURL,
                   bandwidth >= (best?.bandwidth ?? -1) {
                    best = (bandwidth, variant)
                }
            }
            guard let chosen = best?.url else { throw HLSError(message: "Lista maestra sin variantes") }
            current = chosen
        }
        throw HLSError(message: "Lista HLS demasiado anidada")
    }

    private func parse(_ text: String, base: URL) throws -> ([Segment], URL?) {
        var segments: [Segment] = []
        var initSegment: URL?
        var key: Key?
        var sequence = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.components(separatedBy: ":").last ?? "") ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = Self.attributes(line)
                let method = attrs["METHOD"] ?? "NONE"
                if method == "NONE" {
                    key = nil
                } else if method == "AES-128",
                          let uri = attrs["URI"].flatMap({ URL(string: $0, relativeTo: base)?.absoluteURL }) {
                    key = Key(uri: uri, iv: attrs["IV"].flatMap(Self.hexData))
                } else {
                    throw HLSError(message: "Vídeo protegido con DRM (\(method)); no se puede descargar")
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                initSegment = Self.attributes(line)["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                throw HLSError(message: "Este formato HLS (rangos de bytes) no está soportado")
            } else if !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    segments.append(Segment(url: url, key: key, sequence: sequence))
                }
                sequence += 1
            }
        }
        return (segments, initSegment)
    }

    /// Lee `ATRIBUTO=valor,OTRO="valor, con comas"` de una etiqueta HLS.
    static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = ""
        var readingKey = true, quoted = false
        for ch in line[line.index(after: colon)...] {
            if readingKey {
                if ch == "=" { readingKey = false } else if ch != "," { key.append(ch) }
                continue
            }
            if ch == "\"" { quoted.toggle(); continue }
            if ch == ",", !quoted {
                result[key.trimmingCharacters(in: .whitespaces)] = value
                key = ""; value = ""; readingKey = true
                continue
            }
            value.append(ch)
        }
        if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
        return result
    }

    // MARK: - AES-128

    private static func hexData(_ hex: String) -> Data? {
        var string = hex
        if string.lowercased().hasPrefix("0x") { string.removeFirst(2) }
        guard string.count % 2 == 0 else { return nil }
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func iv(for sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(max(sequence, 0)).bigEndian
        withUnsafeBytes(of: &value) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }

    private func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw HLSError(message: "Clave de cifrado no válida")
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCount = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outputCount, &moved)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw HLSError(message: "No se pudo descifrar el vídeo")
        }
        return output.prefix(moved)
    }
}
