import Foundation

/// Gets kirki onto this Mac: downloads the newest image (kirki-vm.json says where), checks it, and
/// unpacks it into kirki's disk (Paths.disk), sized as the settings say. Run it off the main thread.
public final class ImageInstaller {
    public enum Stage: Equatable {
        case checking
        /// bytes so far and in all, and the speed (bytes per second; 0 while it's still unknown)
        case downloading(done: Int64, total: Int64, bytesPerSecond: Double)
        case unpacking(done: Int64, total: Int64)
        case finishing

        public var name: String {
            switch self {
            case .checking: return "checking"
            case .downloading: return "downloading"
            case .unpacking: return "unpacking"
            case .finishing: return "finishing"
            }
        }
    }

    public let manifestURL: URL
    public let diskGB: Int

    public init(manifestURL: URL, diskGB: Int) {
        self.manifestURL = manifestURL
        self.diskGB = diskGB
    }

    public func install(progress: @escaping (Stage) -> Void) async throws -> InstalledImage {
        progress(.checking)
        Log.info("Looking for kirki at \(manifestURL.absoluteString)")
        let manifest = try await ImageManifest.fetch(from: manifestURL)
        let image = manifest.image
        Log.info("kirki \(manifest.version): \(image.parts.count) part(s), \(image.size) bytes (\(image.uncompressedSize) unpacked)")

        try Paths.ensure(Paths.downloads)
        try Paths.ensure(Paths.vm)
        // Room for the download, the unpacked image and kirki's first steps (with some to spare)
        let partFiles = image.parts.map { Paths.downloads.appendingPathComponent($0.url.lastPathComponent) }
        let alreadyThere = zip(image.parts, partFiles).reduce(Int64(0)) { sum, p in
            let size = (try? FileManager.default.attributesOfItem(atPath: p.1.path))?[.size] as? Int64 ?? 0
            return sum + min(size, p.0.size)
        }
        let need = (image.size - alreadyThere) + image.uncompressedSize + (4 << 30)
        let free = HostInfo.freeSpace(at: Paths.support)
        if free > 0 && free < need {
            throw ImageError.notEnoughSpace(neededGB: Int((need + (1 << 30) - 1) >> 30), freeGB: Int(free >> 30))
        }

        // Download each part
        let meter = SpeedMeter()
        var before: Int64 = 0
        for (part, file) in zip(image.parts, partFiles) {
            let download = PartDownload(part: part, destination: file)
            let base = before
            download.onProgress = { done in
                let total = base + done
                progress(.downloading(done: total, total: image.size, bytesPerSecond: meter.add(total)))
            }
            try await download.run()
            before += part.size
        }

        // Unpack into a new disk, then put it in place
        let unpacking = Paths.disk.appendingPathExtension("unpacking")
        try? FileManager.default.removeItem(at: unpacking)
        progress(.unpacking(done: 0, total: image.size))
        let started = Date()
        try ImageUnpacker.unpack(parts: partFiles, to: unpacking, expectedSize: image.uncompressedSize,
                                 expectedSHA256: image.uncompressedSha256) { done in
            progress(.unpacking(done: done, total: image.size))
        }
        Log.info("Unpacked kirki in \(Int(Date().timeIntervalSince(started))) s")
        progress(.finishing)
        try DiskFile.grow(unpacking, toGB: diskGB)
        try? FileManager.default.removeItem(at: Paths.disk)
        try FileManager.default.moveItem(at: unpacking, to: Paths.disk)
        let installed = InstalledImage(version: manifest.version, kirki: manifest.kirki, installed: Date())
        try installed.save()
        try? FileManager.default.removeItem(at: Paths.downloads)
        Log.info("kirki \(manifest.version) is set up (disk: \(diskGB) GB)")
        return installed
    }
}

/// kirki's disk file.
public enum DiskFile {
    public static func size(_ url: URL = Paths.disk) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    /// Makes the disk bigger (never smaller). The new space is a hole, so it takes nothing until kirki
    /// uses it; kirki grows its partition into it when it starts (kirk-vm-grow).
    public static func grow(_ url: URL = Paths.disk, toGB gb: Int) throws {
        let target = Int64(gb) << 30
        guard target > size(url) else { return }
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(target)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        Log.info("kirki's disk is now \(gb) GB")
    }
}

/// Download speed, averaged over the last 10 seconds or so.
final class SpeedMeter: @unchecked Sendable {
    private var samples: [(Date, Int64)] = []
    private let lock = NSLock()

    func add(_ bytes: Int64) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.0) > 10 }
        guard let first = samples.first, now.timeIntervalSince(first.0) > 1 else { return 0 }
        return Double(bytes - first.1) / now.timeIntervalSince(first.0)
    }
}
