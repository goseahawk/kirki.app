import AppKit
import CoreText
import SwiftUI

/// kirki's look: Ink, Bone and Marigold, and DM Sans (bundled in Resources/fonts).
enum Brand {
    static let inkNS = NSColor(srgbRed: 0x16 / 255.0, green: 0x17 / 255.0, blue: 0x1b / 255.0, alpha: 1)
    static let boneNS = NSColor(srgbRed: 0xf3 / 255.0, green: 0xef / 255.0, blue: 0xe6 / 255.0, alpha: 1)
    static let marigoldNS = NSColor(srgbRed: 0xf2 / 255.0, green: 0xa9 / 255.0, blue: 0x3b / 255.0, alpha: 1)
    static let ink = Color(nsColor: inkNS)
    static let bone = Color(nsColor: boneNS)
    static let marigold = Color(nsColor: marigoldNS)

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts") else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .semibold, .heavy, .black: name = "DMSans-Bold"
        case .medium: name = "DMSans-Medium"
        default: name = "DMSans-Regular"
        }
        return .custom(name, size: size)
    }

    /// The kirki lockup (bird and wordmark) for dark backgrounds
    static let logo: NSImage? = Bundle.main.image(forResource: "logo")
}

/// Runs `body` on the main thread: at once if this is it (Virtualization calls back on the VM's queue,
/// which is the main one), otherwise as soon as it can.
func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
