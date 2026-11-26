import Compression
import CryptoKit
import Foundation

/// Writes a disk image as a sparse file: blocks that are all zeros aren't written but punched out as
/// holes, so the file only takes up the space kirki's data needs. (APFS doesn't always make a hole
/// where a file was written past its end, so it's done explicitly.) Also hashes everything, zeros
/// included, so the result can be checked against the image's SHA-256.
public final class SparseFileWriter {
    public static let blockSize = 1 << 20
    public private(set) var size: Int64 = 0
    public private(set) var dataBytesWritten: Int64 = 0

    private let fd: Int32
    private let block: UnsafeMutableRawBufferPointer
    private let zeros: UnsafeMutableRawBufferPointer
    private var fill = 0
    private var hasher = SHA256()
    private var closed = false

    /// - Parameter expectedSize: the image's size, if known: the file starts out that big, all hole
    public init(url: URL, expectedSize: Int64? = nil) throws {
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        block = .allocate(byteCount: Self.blockSize, alignment: 16384)
        zeros = .allocate(byteCount: Self.blockSize, alignment: 16384)
        zeros.initializeMemory(as: UInt8.self, repeating: 0)
        if let expectedSize, expectedSize > 0 { _ = ftruncate(fd, off_t(expectedSize)) }
    }

    deinit {
        if !closed { close(fd) }
        block.deallocate()
        zeros.deallocate()
    }

    public func append(_ data: Data) throws {
        hasher.update(data: data)
        try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < src.count {
                let n = min(Self.blockSize - fill, src.count - offset)
                UnsafeMutableRawBufferPointer(rebasing: block[fill..<fill + n])
                    .copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<offset + n]))
                fill += n
                offset += n
                if fill == Self.blockSize { try flushBlock() }
            }
        }
    }

    private func flushBlock() throws {
        defer { size += Int64(fill); fill = 0 }
        guard fill > 0 else { return }
        if memcmp(block.baseAddress!, zeros.baseAddress!, fill) == 0 {
            punchHole(at: size, length: Int64(fill))
            return
        }
        var done = 0
        while done < fill {
            let n = pwrite(fd, block.baseAddress! + done, fill - done, off_t(size) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            done += n
        }
        dataBytesWritten += Int64(fill)
    }

    /// Makes sure a range of the file is a hole (if it's inside the file; past its end it's one anyway).
    private func punchHole(at offset: Int64, length: Int64) {
        var st = stat()
        guard fstat(fd, &st) == 0, offset < Int64(st.st_size) else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(offset),
                                fp_length: off_t(min(length, Int64(st.st_size) - offset)))
        _ = fcntl(fd, F_PUNCHHOLE, &hole)
    }

    /// Writes what's left, sets the file's full size (it may end in a hole) and makes sure it's on
    /// disk. Returns the SHA-256 of everything appended.
    public func finish() throws -> String {
        try flushBlock()
        guard ftruncate(fd, off_t(size)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        close(fd)
        closed = true
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Decompresses an xz stream (what image/build.sh makes) with macOS's Compression framework.
public final class XZDecoder {
    private var filter: OutputFilter?

    /// `output` gets the decompressed data, in pieces, as it comes.
    public init(output: @escaping (Data) throws -> Void) throws {
        filter = try OutputFilter(.decompress, using: .lzma, bufferCapacity: 1 << 20) { data in
            if let data, !data.isEmpty { try output(data) }
        }
    }

    public func write(_ data: Data) throws {
        try filter?.write(data)
    }

    public func finish() throws {
        try filter?.finalize()
        filter = nil
    }
}

public enum ImageError: LocalizedError, Equatable {
    case sizeMismatch(expected: Int64, got: Int64)
    case checksum
    case notEnoughSpace(neededGB: Int, freeGB: Int)

    public var errorDescription: String? {
        switch self {
        case .sizeMismatch(let e, let g): return "kirki's image unpacked to \(g) bytes instead of \(e)."
        case .checksum: return "kirki's image didn't unpack correctly (its checksum doesn't match)."
        case .notEnoughSpace(let need, let free):
            return "kirki needs about \(need) GB of free space on this Mac to get started, and there's \(free) GB. Free up some space and try again."
        }
    }
}

/// Unpacks the downloaded parts (in order, as one xz stream) into a sparse disk image.
public enum ImageUnpacker {
    /// - Parameters:
    ///   - progress: called with the compressed bytes read so far
    /// - Returns: the image's real size and SHA-256
    @discardableResult
    public static func unpack(parts: [URL], to destination: URL, expectedSize: Int64? = nil, expectedSHA256: String? = nil,
                              progress: ((Int64) -> Void)? = nil) throws -> (size: Int64, sha256: String) {
        let writer = try SparseFileWriter(url: destination, expectedSize: expectedSize)
        let decoder = try XZDecoder { try writer.append($0) }
        var read: Int64 = 0
        for url in parts {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                try autoreleasepool { try decoder.write(chunk) }
                read += Int64(chunk.count)
                progress?(read)
            }
        }
        try decoder.finish()
        let sha = try writer.finish()
        if let expectedSize, writer.size != expectedSize {
            throw ImageError.sizeMismatch(expected: expectedSize, got: writer.size)
        }
        if let expectedSHA256, sha != expectedSHA256.lowercased() { throw ImageError.checksum }
        return (writer.size, sha)
    }
}
