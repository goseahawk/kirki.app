import Foundation

/// What happens when you shut kirki down in the kirki login.
public enum ShutdownAction: String, Codable, CaseIterable {
    /// Back to the Mac's login window, where you can choose macOS or kirki again
    case logOut
    /// Turn the Mac off
    case shutDownMac
}

/// The Mac's menu bar, in the kirki login.
public enum MenuBarMode: String, Codable, CaseIterable {
    /// Hidden, but it slides down when the pointer reaches the top of the screen: Wi-Fi, Bluetooth,
    /// sound, battery and Control Center stay a click away
    case showAtTop
    /// Never shown: the screen is all kirki
    case hidden
}

/// The app's settings (~/Library/Application Support/kirki/settings.json). Most take effect the
/// next time kirki starts.
public struct Settings: Codable, Equatable {
    public var memoryGB: Int
    public var processors: Int
    /// kirki's disk. It can only grow: kirki's partition grows into the new space when it starts.
    public var diskGB: Int
    /// Give kirki the screen's full Retina resolution (sharp text) rather than half (faster)
    public var retina: Bool
    public var microphone: Bool
    /// Share Rosetta, so kirki can run programs made for Intel and AMD computers
    public var rosetta: Bool
    public var whenKirkiShutsDown: ShutdownAction
    public var macMenuBar: MenuBarMode
    /// Pause kirki while another Mac account is in use (Fast User Switching), so it uses no power
    public var pauseWhenSwitchedAway: Bool
    /// In a window: send shortcuts like ⌘Tab and ⌘Space to kirki instead of the Mac
    public var captureSystemKeysInWindow: Bool
    /// Where the app finds kirki's image (a kirki-vm.json); empty means the latest release
    public var imageManifestURL: String

    public static let latestManifestURL = "https://github.com/goseahawk/kirki.app/releases/latest/download/kirki-vm.json"
    public static let minimumDiskGB = 24

    /// Defaults for this Mac: about 60% of its memory (at least 4 GB, leaving macOS at least 3 GB),
    /// all its processors, and a 64 GB disk (less if the Mac is short of space; it only takes the
    /// space kirki actually uses).
    public static func defaults(for host: HostInfo) -> Settings {
        let memory = max(4, min(Int((Double(host.memoryGB) * 0.6).rounded()), max(host.memoryGB - 3, 4), 32))
        var disk = 64
        if host.freeDiskGB > 0 && host.freeDiskGB < disk + 20 {
            disk = max(minimumDiskGB, host.freeDiskGB - 20)
        }
        return Settings(
            memoryGB: memory, processors: max(1, host.processorCount), diskGB: disk,
            retina: true, microphone: true, rosetta: true,
            whenKirkiShutsDown: .logOut, macMenuBar: .showAtTop, pauseWhenSwitchedAway: true,
            captureSystemKeysInWindow: false, imageManifestURL: ""
        )
    }

    public init(memoryGB: Int, processors: Int, diskGB: Int, retina: Bool, microphone: Bool, rosetta: Bool,
                whenKirkiShutsDown: ShutdownAction, macMenuBar: MenuBarMode, pauseWhenSwitchedAway: Bool,
                captureSystemKeysInWindow: Bool, imageManifestURL: String) {
        self.memoryGB = memoryGB
        self.processors = processors
        self.diskGB = diskGB
        self.retina = retina
        self.microphone = microphone
        self.rosetta = rosetta
        self.whenKirkiShutsDown = whenKirkiShutsDown
        self.macMenuBar = macMenuBar
        self.pauseWhenSwitchedAway = pauseWhenSwitchedAway
        self.captureSystemKeysInWindow = captureSystemKeysInWindow
        self.imageManifestURL = imageManifestURL
    }

    // Settings saved by an older version may lack newer keys: those get their defaults.
    private enum CodingKeys: String, CodingKey {
        case memoryGB, processors, diskGB, retina, microphone, rosetta, whenKirkiShutsDown, macMenuBar,
             pauseWhenSwitchedAway, captureSystemKeysInWindow, imageManifestURL
    }

    public init(from decoder: Decoder) throws {
        let d = Settings.defaults(for: .current)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memoryGB = (try? c.decodeIfPresent(Int.self, forKey: .memoryGB)) ?? d.memoryGB
        processors = (try? c.decodeIfPresent(Int.self, forKey: .processors)) ?? d.processors
        diskGB = (try? c.decodeIfPresent(Int.self, forKey: .diskGB)) ?? d.diskGB
        retina = (try? c.decodeIfPresent(Bool.self, forKey: .retina)) ?? d.retina
        microphone = (try? c.decodeIfPresent(Bool.self, forKey: .microphone)) ?? d.microphone
        rosetta = (try? c.decodeIfPresent(Bool.self, forKey: .rosetta)) ?? d.rosetta
        whenKirkiShutsDown = (try? c.decodeIfPresent(ShutdownAction.self, forKey: .whenKirkiShutsDown)) ?? d.whenKirkiShutsDown
        macMenuBar = (try? c.decodeIfPresent(MenuBarMode.self, forKey: .macMenuBar)) ?? d.macMenuBar
        pauseWhenSwitchedAway = (try? c.decodeIfPresent(Bool.self, forKey: .pauseWhenSwitchedAway)) ?? d.pauseWhenSwitchedAway
        captureSystemKeysInWindow = (try? c.decodeIfPresent(Bool.self, forKey: .captureSystemKeysInWindow)) ?? d.captureSystemKeysInWindow
        imageManifestURL = (try? c.decodeIfPresent(String.self, forKey: .imageManifestURL)) ?? d.imageManifestURL
    }

    /// The settings, kept within what this Mac can do.
    public func clamped(to host: HostInfo) -> Settings {
        var s = self
        s.memoryGB = min(max(s.memoryGB, 2), max(host.memoryGB - 2, 2))
        s.processors = min(max(s.processors, 1), max(host.processorCount, 1))
        s.diskGB = min(max(s.diskGB, Settings.minimumDiskGB), 4096)
        return s
    }

    public var manifestURL: URL {
        let text = imageManifestURL.trimmingCharacters(in: .whitespaces)
        if let env = ProcessInfo.processInfo.environment["KIRKI_MANIFEST_URL"], let url = URL(string: env) { return url }
        if !text.isEmpty, let url = URL(string: text), url.scheme == "https" || url.isFileURL { return url }
        return URL(string: Settings.latestManifestURL)!
    }

    public static func load(host: HostInfo = .current) -> Settings {
        if let data = try? Data(contentsOf: Paths.settings),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            return saved.clamped(to: host)
        }
        return defaults(for: host)
    }

    public func save() throws {
        try Paths.ensure(Paths.support)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.settings, options: .atomic)
    }
}
