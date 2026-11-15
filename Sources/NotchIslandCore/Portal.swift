import Foundation

// UI-free pieces of Portal (files flying in from an iPhone): safe file names, the shared token and
// a small streaming parser for `POST /upload` requests sent by iOS Shortcuts or curl.

public enum PortalFiles {
    /// A file name that is safe to create in the destination folder: no folders, no hidden files,
    /// no control characters, not too long. Empty input gets a dated name.
    public static func sanitize(_ raw: String, now: Date = Date()) -> String {
        var name = (raw.removingPercentEncoding ?? raw)
            .replacingOccurrences(of: "\\", with: "/")
        name = name.split(separator: "/").last.map(String.init) ?? ""
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty || name == ".." {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            name = "Portal \(f.string(from: now))"
        }
        // File systems allow 255 bytes; keep the extension when cutting.
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            var base = (name as NSString).deletingPathExtension
            while (base.utf8.count + ext.utf8.count + 1) > 200, !base.isEmpty { base.removeLast() }
            name = ext.isEmpty ? base : "\(base).\(ext)"
        }
        return name
    }

    /// `folder/name`, or `name 2.ext`, `name 3.ext`… if that is taken — like Finder does.
    public static func uniqueDestination(for name: String, in folder: URL,
                                         exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for n in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !exists(candidate) { return candidate }
        }
        return first
    }

    /// A media-type guess for a received file without an extension (Shortcuts sometimes drop it).
    public static func fileExtension(forContentType type: String?) -> String? {
        guard let type = type?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        let known: [String: String] = [
            "image/jpeg": "jpg", "image/png": "png", "image/heic": "heic", "image/heif": "heif", "image/gif": "gif",
            "image/webp": "webp", "video/quicktime": "mov", "video/mp4": "mp4", "application/pdf": "pdf",
            "text/plain": "txt", "application/zip": "zip", "audio/mpeg": "mp3", "audio/x-m4a": "m4a",
        ]
        return known[type]
    }
}

public enum PortalToken {
    /// Short enough to type into Shortcuts by hand, long enough not to be guessed on a home network.
    public static func generate() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    /// Constant-time comparison (doesn't leak how many leading characters matched).
    public static func matches(_ provided: String?, _ expected: String) -> Bool {
        guard let provided, !expected.isEmpty else { return false }
        let a = Array(provided.utf8), b = Array(expected.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<max(a.count, b.count) {
            diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return diff == 0
    }
}

// MARK: - HTTP

public struct HTTPRequestHead: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Lower-cased names.
    public var headers: [String: String]

    public var contentLength: Int? { headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    public var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false }
    public var expectsContinue: Bool { headers["expect"]?.lowercased() == "100-continue" }

    /// The multipart boundary when the body is `multipart/form-data`.
    public var multipartBoundary: String? {
        guard let type = headers["content-type"], type.lowercased().hasPrefix("multipart/") else { return nil }
        for part in type.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "boundary" { return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }

    /// Token from `Authorization: Bearer …`, `X-Portal-Token` or `?token=`.
    public var token: String? {
        if let auth = headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" { return parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return headers["x-portal-token"]?.trimmingCharacters(in: .whitespaces) ?? query["token"]
    }

    /// File name from `X-Filename`, `?name=` or a `Content-Disposition` header (multipart parts carry their own).
    public var fileName: String? {
        if let raw = headers["x-filename"] ?? query["name"] ?? query["filename"] { return raw.removingPercentEncoding ?? raw }
        if let cd = headers["content-disposition"] { return Multipart.fileName(fromDisposition: cd) }
        return nil
    }
}

/// Feeds on raw bytes from a connection and reports the request head, then the body piece by piece.
/// Handles `Content-Length`, `Transfer-Encoding: chunked` and bodies that end when the client closes.
public final class HTTPUploadParser {
    public enum Event: Equatable {
        case head(HTTPRequestHead)
        case body(Data)
        case done
        case failed(String)
    }

    private enum State { case head, fixed(Int), chunkSize, chunkData(Int), chunkDataEnd, trailer, untilClose, done, failed }

    public var maxHeadBytes = 32 * 1024
    private var state = State.head
    private var buffer = Data()

    public init() {}

    public var isFinished: Bool {
        switch state { case .done, .failed: return true; default: return false }
    }

    public func feed(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while true {
            switch state {
            case .head:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > maxHeadBytes { state = .failed; events.append(.failed("header too large")) }
                    return events
                }
                let headData = buffer.subdata(in: buffer.startIndex..<end.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                guard let head = Self.parseHead(headData) else {
                    state = .failed
                    events.append(.failed("bad request"))
                    return events
                }
                events.append(.head(head))
                if head.isChunked { state = .chunkSize }
                else if let n = head.contentLength { state = n > 0 ? .fixed(n) : .done; if n == 0 { events.append(.done) } }
                else if head.method == "POST" || head.method == "PUT" { state = .untilClose }
                else { state = .done; events.append(.done) }
            case .fixed(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(remaining, buffer.count)
                events.append(.body(buffer.prefix(take)))
                buffer.removeFirst(take)
                if remaining - take == 0 { state = .done; events.append(.done) } else { state = .fixed(remaining - take) }
            case .chunkSize:
                guard let crlf = buffer.range(of: Data("\r\n".utf8)) else { return events }
                let line = String(decoding: buffer[buffer.startIndex..<crlf.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<crlf.upperBound)
                let hex = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16) else { state = .failed; events.append(.failed("bad chunk")); return events }
                state = size == 0 ? .trailer : .chunkData(size)
            case .chunkData(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(remaining, buffer.count)
                events.append(.body(buffer.prefix(take)))
                buffer.removeFirst(take)
                state = remaining - take == 0 ? .chunkDataEnd : .chunkData(remaining - take)
            case .chunkDataEnd:
                guard buffer.count >= 2 else { return events }
                buffer.removeFirst(2)
                state = .chunkSize
            case .trailer:
                // Trailer headers (rare) end with an empty line.
                guard let crlf = buffer.range(of: Data("\r\n".utf8)) else { return events }
                let empty = crlf.lowerBound == buffer.startIndex
                buffer.removeSubrange(buffer.startIndex..<crlf.upperBound)
                if empty { state = .done; events.append(.done); return events }
            case .untilClose:
                if !buffer.isEmpty { events.append(.body(buffer)); buffer.removeAll() }
                return events
            case .done, .failed:
                return events
            }
        }
    }

    /// The client closed its side. Ends a body without a declared length; anything else is cut short.
    public func finishInput() -> [Event] {
        switch state {
        case .untilClose: state = .done; return [.done]
        case .done, .failed: return []
        default: state = .failed; return [.failed("connection closed early")]
        }
    }

    static func parseHead(_ data: Data) -> HTTPRequestHead? {
        // Headers are ASCII by the spec, but Shortcuts sends file names as raw UTF-8.
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequestHead(method: String(requestLine[0]).uppercased(),
                               path: comps?.path ?? target, query: query, headers: headers)
    }
}

// MARK: - multipart/form-data

public enum Multipart {
    public struct Part: Equatable {
        public var fileName: String?
        public var contentType: String?
        /// Byte range of the part's content in the whole body.
        public var range: Range<Int>
    }

    /// The first part that carries a file (or the first part at all). Works on a memory-mapped body,
    /// so a large video isn't copied while looking for it.
    public static func filePart(in body: Data, boundary: String) -> Part? {
        let delimiter = Data("--\(boundary)".utf8)
        let separator = Data("\r\n\r\n".utf8)
        var parts: [Part] = []
        var cursor = body.startIndex
        guard let first = body.range(of: delimiter, in: cursor..<body.endIndex) else { return nil }
        cursor = first.upperBound
        while cursor < body.endIndex {
            // "--" right after a delimiter ends the body.
            if body.count - (cursor - body.startIndex) >= 2, body[cursor] == 0x2D, body[cursor + 1] == 0x2D { break }
            guard let headEnd = body.range(of: separator, in: cursor..<body.endIndex) else { break }
            let headText = String(decoding: body[cursor..<headEnd.lowerBound], as: UTF8.self)
            let contentStart = headEnd.upperBound
            guard let next = body.range(of: Data("\r\n".utf8) + delimiter, in: contentStart..<body.endIndex) else { break }
            var part = Part(fileName: nil, contentType: nil, range: (contentStart - body.startIndex)..<(next.lowerBound - body.startIndex))
            for line in headText.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name == "content-disposition" { part.fileName = fileName(fromDisposition: value) }
                if name == "content-type" { part.contentType = value }
            }
            parts.append(part)
            cursor = next.upperBound
        }
        return parts.first { $0.fileName != nil } ?? parts.first
    }

    /// `filename*=UTF-8''…` (RFC 5987) wins over plain `filename="…"`.
    public static func fileName(fromDisposition value: String) -> String? {
        var plain: String?
        for raw in value.split(separator: ";") {
            let kv = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            if key == "filename*" {
                let encoded = kv[1].components(separatedBy: "''").last ?? kv[1]
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty { return decoded }
            } else if key == "filename" {
                plain = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return plain.flatMap { $0.isEmpty ? nil : $0 }
    }
}
