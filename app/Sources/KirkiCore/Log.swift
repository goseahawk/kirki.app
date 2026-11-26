import Foundation
import os

/// The app's log: ~/Library/Logs/kirki/kirki.log (and the unified log, subsystem
/// io.github.goseahawk.kirki). It's kept under 5 MB; the previous one is kirki.1.log.
public enum Log {
    private static let logger = Logger(subsystem: "io.github.goseahawk.kirki", category: "app")
    private static let queue = DispatchQueue(label: "io.github.goseahawk.kirki.log")
    private static var handle: FileHandle?

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("     ", message)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    /// Waits until everything logged so far is in the file.
    public static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func write(_ level: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
        queue.async {
            if handle == nil { open() }
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    private static func open() {
        let url = Paths.appLog
        try? Paths.ensure(url.deletingLastPathComponent())
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}
