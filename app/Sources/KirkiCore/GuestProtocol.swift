import Foundation

/// Messages from kirki (kirk-vm-agent and kirk-vm-power in the image) over the control port,
/// org.kirki.control. One per line; see /usr/local/bin/kirk-vm-agent for the whole protocol.
public enum GuestMessage: Equatable {
    case ready(version: String)
    /// Sent at the very end of shutting down: "poweroff", "reboot", "halt" or "kexec"
    case power(String)
    case status([String: String])
    case pong
    case unknown(String)

    public init(line: String) {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        switch words.first {
        case "ready": self = .ready(version: words.count > 1 ? words[1] : "")
        case "power" where words.count > 1: self = .power(words[1])
        case "pong": self = .pong
        case "status":
            var values: [String: String] = [:]
            for word in words.dropFirst() {
                guard let eq = word.firstIndex(of: "=") else { continue }
                values[String(word[..<eq])] = String(word[word.index(after: eq)...])
            }
            self = .status(values)
        default: self = .unknown(line)
        }
    }
}

/// Messages to kirki.
public enum HostMessage: Equatable {
    case hostinfo([String: String])
    case time(Date)
    case shutdown
    case reboot
    case status
    case ping

    public var line: String {
        switch self {
        case .hostinfo(let values):
            let pairs = values.keys.sorted().map { "\($0)=\(Self.encode(values[$0]!))" }
            return (["hostinfo"] + pairs).joined(separator: " ")
        case .time(let date): return String(format: "time %.3f", date.timeIntervalSince1970)
        case .shutdown: return "shutdown"
        case .reboot: return "reboot"
        case .status: return "status"
        case .ping: return "ping"
        }
    }

    /// %XX for everything but letters, digits and . _ - / : (kirk-vm-agent decodes it)
    public static func encode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"),
                 UInt8(ascii: "-"), UInt8(ascii: "/"), UInt8(ascii: ":"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

/// Splits bytes as they arrive into lines.
public final class LineSplitter {
    private var buffer = Data()
    private let limit: Int

    public init(limit: Int = 64 * 1024) { self.limit = limit }

    public func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if buffer.count > limit { buffer.removeAll() }      // a runaway line: drop it
        return lines
    }
}

/// What kirki's kernel says last on its console (hvc0) when it stops: a backup for telling a restart
/// from a shutdown, in case kirk-vm-power's message didn't arrive.
public enum PowerIntent: String, Equatable {
    case reboot, poweroff, unknown

    public static func fromConsole(_ line: String) -> PowerIntent? {
        if line.contains("reboot: Restarting system") { return .reboot }
        if line.contains("reboot: Power down") || line.contains("reboot: System halted") { return .poweroff }
        return nil
    }

    public static func fromPowerMessage(_ word: String) -> PowerIntent {
        switch word {
        case "reboot", "kexec": return .reboot
        case "poweroff", "halt": return .poweroff
        default: return .unknown
        }
    }
}
