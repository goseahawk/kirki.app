import Foundation

/// kirki-vm.json, published with each release (image/build.sh writes it): the disk image to download,
/// in one or more parts, with sizes and SHA-256 checksums.
public struct ImageManifest: Codable, Equatable {
    public struct Part: Codable, Equatable {
        public var url: URL
        public var size: Int64
        public var sha256: String
    }

    public struct Image: Codable, Equatable {
        /// Always "xz": macOS reads it with its own Compression framework
        public var compression: String
        /// Size and checksum of the whole compressed image (all the parts, one after another)
        public var size: Int64
        public var sha256: String
        public var uncompressedSize: Int64
        public var uncompressedSha256: String?
        public var parts: [Part]
    }

    public var format: Int
    public var version: String
    /// The kirki commit the desktop comes from
    public var kirki: String?
    public var image: Image

    public enum Problem: LocalizedError, Equatable {
        case unsupported(String)
        case invalid(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported(let why): return "This kirki image needs a newer version of the kirki app (\(why))."
            case .invalid(let why): return "kirki's download information is damaged (\(why))."
            }
        }
    }

    public static func decode(_ data: Data) throws -> ImageManifest {
        let manifest = try JSONDecoder().decode(ImageManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard format == 1 else { throw Problem.unsupported("format \(format)") }
        guard image.compression == "xz" else { throw Problem.unsupported("compression \(image.compression)") }
        guard !image.parts.isEmpty else { throw Problem.invalid("no parts") }
        guard image.parts.reduce(Int64(0), { $0 + $1.size }) == image.size else { throw Problem.invalid("the parts don't add up") }
        let hex = { (s: String) in s.count == 64 && s.allSatisfy { $0.isHexDigit } }
        guard hex(image.sha256), image.parts.allSatisfy({ hex($0.sha256) }) else { throw Problem.invalid("bad checksum") }
        guard image.uncompressedSize > image.size, image.uncompressedSize < 1 << 40 else { throw Problem.invalid("bad size") }
        guard image.parts.allSatisfy({ $0.url.scheme == "https" || $0.url.isFileURL }) else { throw Problem.invalid("bad link") }
        guard Version(version) != nil else { throw Problem.invalid("bad version \(version)") }
    }

    /// Downloads and checks kirki-vm.json.
    public static func fetch(from url: URL) async throws -> ImageManifest {
        if url.isFileURL { return try decode(Data(contentsOf: url)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("kirki-app", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.http(http.statusCode, url)
        }
        return try decode(data)
    }
}

/// kirki's versions: YY.MM.DD, or YY.MM.DD.N for later builds the same day.
public struct Version: Comparable, CustomStringConvertible {
    public let parts: [Int]
    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (3...4).contains(pieces.count), pieces.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = pieces.map { $0! }
    }
    public var description: String { parts.map(String.init).joined(separator: ".") }
    public static func < (a: Version, b: Version) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        let x = a.parts + Array(repeating: 0, count: n - a.parts.count)
        let y = b.parts + Array(repeating: 0, count: n - b.parts.count)
        return x.lexicographicallyPrecedes(y)
    }
}

/// What's installed: written once kirki's disk is set up (vm/image.json).
public struct InstalledImage: Codable, Equatable {
    public var version: String
    public var kirki: String?
    public var installed: Date

    public static func load() -> InstalledImage? {
        guard let data = try? Data(contentsOf: Paths.installedImage) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstalledImage.self, from: data)
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.installedImage, options: .atomic)
    }
}
