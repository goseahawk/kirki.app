import CryptoKit
import Foundation

public enum DownloadError: LocalizedError, Equatable {
    case http(Int, URL)
    case checksum(String)
    case tooShort(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "The server answered \(code) for \(url.lastPathComponent)."
        case .checksum(let name): return "\(name) was damaged on the way (its checksum doesn't match). It has been deleted; try again."
        case .tooShort(let name): return "\(name) didn't download completely."
        }
    }
}

/// Downloads one part of kirki's image to a file, checking its SHA-256. Interrupted downloads carry on
/// where they stopped (also the next time the app starts): the bytes so far are kept in NAME.partial.
public final class PartDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let part: ImageManifest.Part
    public let destination: URL
    /// Called (on a background queue) with the number of bytes of this part that are on disk
    public var onProgress: ((Int64) -> Void)?

    private var partial: URL { destination.appendingPathExtension("partial") }
    private var name: String { destination.lastPathComponent }
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var written: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "kirki download"
        return q
    }()

    public init(part: ImageManifest.Part, destination: URL) {
        self.part = part
        self.destination = destination
    }

    /// Downloads the part unless it's already there. Network trouble is retried (six times, with a
    /// growing pause), always resuming; a checksum mismatch throws DownloadError.checksum.
    public func run() async throws {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: destination.path))?[.size] as? Int64, size == part.size {
            onProgress?(part.size)
            return
        }
        try Paths.ensure(destination.deletingLastPathComponent())
        var attempt = 0
        while true {
            attempt += 1
            do {
                try prepare()
                if written < part.size { try await fetch() }
                break
            } catch let error as URLError where attempt < 6 && Self.isTransient(error) {
                Log.info("Download of \(name) interrupted (\(error.localizedDescription)); trying again")
                try await Task.sleep(nanoseconds: UInt64(attempt * attempt) * 2_000_000_000)
            }
        }
        try? handle?.close()
        handle = nil
        guard written == part.size else { throw DownloadError.tooShort(name) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == part.sha256.lowercased() else {
            try? fm.removeItem(at: partial)
            throw DownloadError.checksum(name)
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
        Log.info("Downloaded \(name) (\(part.size) bytes, checksum OK)")
    }

    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .cancelled, .badURL, .unsupportedURL, .fileDoesNotExist, .noPermissionsToReadFile: return false
        default: return true
        }
    }

    /// Opens NAME.partial and hashes what's already in it, so the download can carry on.
    private func prepare() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        try? handle?.close()
        hasher = SHA256()
        written = 0
        let reader = try FileHandle(forReadingFrom: partial)
        while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
            if written + Int64(chunk.count) > part.size { break }       // longer than it should be
            hasher.update(data: chunk)
            written += Int64(chunk.count)
        }
        try reader.close()
        let h = try FileHandle(forWritingTo: partial)
        try h.truncate(atOffset: UInt64(written))
        try h.seek(toOffset: UInt64(written))
        handle = h
        onProgress?(written)
    }

    private func fetch() async throws {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: part.url)
        request.setValue("kirki-app", forHTTPHeaderField: "User-Agent")
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        failure = nil
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.addOperation {
                self.continuation = c
                session.dataTask(with: request).resume()
            }
        }
    }

    // MARK: URLSessionDataDelegate (on `queue`)

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // (a file:// link, used in tests, has no status: it's the whole file)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch code {
        case 206:
            completionHandler(.allow)
        case 200:
            // The server sent the whole file: start again from the beginning.
            if written > 0 {
                do {
                    try handle?.truncate(atOffset: 0)
                    try handle?.seek(toOffset: 0)
                } catch {
                    failure = error
                    completionHandler(.cancel)
                    return
                }
                hasher = SHA256()
                written = 0
            }
            completionHandler(.allow)
        default:
            failure = DownloadError.http(code, part.url)
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        if written + Int64(data.count) > part.size {
            failure = DownloadError.checksum(name)
            dataTask.cancel()
            return
        }
        do {
            try handle?.write(contentsOf: data)
            hasher.update(data: data)
            written += Int64(data.count)
            onProgress?(written)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let failure { c?.resume(throwing: failure) }
        else if let error { c?.resume(throwing: error) }
        else { c?.resume() }
    }

    /// GitHub's downloads redirect to a signed link; keep asking for the rest of the file there too.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            next.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(next)
    }
}
