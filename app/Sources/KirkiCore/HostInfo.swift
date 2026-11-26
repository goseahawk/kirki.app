import Foundation

/// What kirki needs to know about the Mac it runs on.
public struct HostInfo: Equatable {
    public var physicalMemory: UInt64
    public var processorCount: Int
    /// The Mac's model identifier, e.g. "Mac14,2"
    public var model: String
    /// The chip, e.g. "Apple M2"
    public var chip: String
    /// Free space where kirki keeps its disk
    public var freeDiskBytes: Int64

    public var memoryGB: Int { Int(physicalMemory / (1 << 30)) }
    public var freeDiskGB: Int { Int(freeDiskBytes / (1 << 30)) }

    public init(physicalMemory: UInt64, processorCount: Int, model: String, chip: String, freeDiskBytes: Int64) {
        self.physicalMemory = physicalMemory
        self.processorCount = processorCount
        self.model = model
        self.chip = chip
        self.freeDiskBytes = freeDiskBytes
    }

    public static var current: HostInfo {
        HostInfo(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            model: sysctl("hw.model") ?? "Mac",
            chip: sysctl("machdep.cpu.brand_string") ?? "Apple silicon",
            freeDiskBytes: freeSpace(at: FileManager.default.homeDirectoryForCurrentUser)
        )
    }

    public static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func freeSpace(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values.volumeAvailableCapacity ?? 0)
    }
}

/// The Mac's keyboard layouts (their input source IDs, com.apple.keylayout.NAME) as X keyboard
/// layouts, so kirki's first-start setup suggests the layout you use on the Mac. Plain layouts, as
/// kirki uses on a Mac's own keyboard; you can pick a variant in kirki's settings.
public enum KeyboardLayouts {
    static let table: [String: (String, String)] = [
        "US": ("us", ""), "ABC": ("us", ""), "ABC-Extended": ("us", ""), "USExtended": ("us", ""),
        "Australian": ("us", ""), "Canadian": ("us", ""), "Irish": ("ie", ""), "IrishExtended": ("ie", ""),
        "USInternational-PC": ("us", "intl"), "Dvorak": ("us", "dvorak"), "DVORAK-QWERTYCMD": ("us", "dvorak"),
        "Dvorak-Left": ("us", "dvorak-l"), "Dvorak-Right": ("us", "dvorak-r"), "Colemak": ("us", "colemak"),
        "British": ("gb", ""), "British-PC": ("gb", ""),
        "Canadian-CSA": ("ca", "multix"), "CanadianFrench-PC": ("ca", ""),
        "French": ("fr", ""), "French-PC": ("fr", ""), "French-numerical": ("fr", ""),
        "Belgian": ("be", ""), "SwissFrench": ("ch", "fr"), "SwissGerman": ("ch", ""),
        "German": ("de", ""), "Austrian": ("at", ""),
        "Spanish": ("es", ""), "Spanish-ISO": ("es", ""), "LatinAmerican": ("latam", ""),
        "Italian": ("it", ""), "Italian-Pro": ("it", ""),
        "Portuguese": ("pt", ""), "Brazilian": ("br", ""), "Brazilian-ABNT2": ("br", ""), "Brazilian-Pro": ("br", ""),
        "Dutch": ("nl", ""), "Danish": ("dk", ""), "Finnish": ("fi", ""), "FinnishExtended": ("fi", ""),
        "Norwegian": ("no", ""), "NorwegianExtended": ("no", ""),
        "Swedish": ("se", ""), "Swedish-Pro": ("se", ""), "Icelandic": ("is", ""),
        "Estonian": ("ee", ""), "Latvian": ("lv", ""), "Lithuanian": ("lt", ""),
        "Polish": ("pl", ""), "PolishPro": ("pl", ""),
        "Czech": ("cz", ""), "Czech-QWERTY": ("cz", "qwerty"),
        "Slovak": ("sk", ""), "Slovak-QWERTY": ("sk", "qwerty"),
        "Hungarian": ("hu", ""), "Hungarian-QWERTY": ("hu", "qwerty"),
        "Romanian": ("ro", ""), "Romanian-Standard": ("ro", ""),
        "Croatian": ("hr", ""), "Croatian-PC": ("hr", ""), "Slovenian": ("si", ""),
        "Serbian": ("rs", ""), "Serbian-Latin": ("rs", "latin"),
        "Turkish": ("tr", "f"), "Turkish-QWERTY": ("tr", ""), "Turkish-QWERTY-PC": ("tr", ""),
        "Greek": ("gr", ""), "GreekPolytonic": ("gr", "polytonic"),
        "Russian": ("ru", ""), "RussianWin": ("ru", ""), "Russian-Phonetic": ("ru", "phonetic"),
        "Ukrainian": ("ua", ""), "Ukrainian-PC": ("ua", ""),
        "Bulgarian": ("bg", ""), "Bulgarian-Phonetic": ("bg", "phonetic"),
        "Hebrew": ("il", ""), "Hebrew-QWERTY": ("il", ""),
        "Arabic": ("ara", ""), "Arabic-QWERTY": ("ara", ""), "Persian": ("ir", ""), "Thai": ("th", ""),
    ]

    /// The X layout and variant for a Mac keyboard layout ID, or nil if kirki doesn't know it.
    public static func xkb(forMacLayoutID id: String) -> (layout: String, variant: String)? {
        let prefix = "com.apple.keylayout."
        guard id.hasPrefix(prefix) else { return nil }
        let name = String(id.dropFirst(prefix.count))
        return table[name].map { (layout: $0.0, variant: $0.1) }
    }
}
