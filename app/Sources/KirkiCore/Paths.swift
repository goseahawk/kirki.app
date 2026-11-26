import Foundation

/// Where kirki keeps its files, in the Mac account that runs it.
///
///     ~/Library/Application Support/kirki/
///         settings.json          the app's settings
///         vm/disk.img            kirki's disk (a sparse file: it only takes the space kirki uses)
///         vm/...                 the virtual machine's EFI variables, identity and network address
///         downloads/             the image while it downloads (deleted once kirki is set up)
///     ~/Library/Logs/kirki/      kirki.log (the app) and console.log (kirki's kernel)
///
/// KIRKI_HOME moves all of it somewhere else (for testing).
public enum Paths {
    public static var support: URL {
        if let home = ProcessInfo.processInfo.environment["KIRKI_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("kirki", isDirectory: true)
    }

    public static var vm: URL { support.appendingPathComponent("vm", isDirectory: true) }
    public static var downloads: URL { support.appendingPathComponent("downloads", isDirectory: true) }
    public static var settings: URL { support.appendingPathComponent("settings.json") }

    public static var disk: URL { vm.appendingPathComponent("disk.img") }
    public static var efiVariables: URL { vm.appendingPathComponent("efi-variables.fd") }
    public static var machineIdentifier: URL { vm.appendingPathComponent("machine-identifier") }
    public static var macAddress: URL { vm.appendingPathComponent("mac-address") }
    public static var installedImage: URL { vm.appendingPathComponent("image.json") }
    public static var savedState: URL { vm.appendingPathComponent("saved-state.vzvmsave") }
    public static var lock: URL { vm.appendingPathComponent("lock") }
    public static var wallpaper: URL { support.appendingPathComponent("wallpaper.png") }

    public static var logs: URL {
        if ProcessInfo.processInfo.environment["KIRKI_HOME"] != nil {
            return support.appendingPathComponent("logs", isDirectory: true)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/kirki", isDirectory: true)
    }

    public static var appLog: URL { logs.appendingPathComponent("kirki.log") }
    public static var consoleLog: URL { logs.appendingPathComponent("console.log") }

    /// Makes a folder (and its parents) if it isn't there yet.
    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
