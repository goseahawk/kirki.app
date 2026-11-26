import AppKit
import Foundation
import KirkiCore

/// The kirki login: what makes a Mac account feel like starting another system.
@MainActor
enum Session {
    /// No Dock, no app switching, and the menu bar either hidden or sliding down at the top edge.
    /// (Force Quit and the power button's menu stay, as a way out.)
    static func applyPresentation(_ menuBar: MenuBarMode) {
        var options: NSApplication.PresentationOptions = [.hideDock, .disableProcessSwitching, .disableHideApplication]
        options.insert(menuBar == .showAtTop ? .autoHideMenuBar : .hideMenuBar)
        NSApp.presentationOptions = options
    }

    /// Sets up the Mac side of the kirki login: kirki's dark wallpaper behind kirki (seen for a moment
    /// while it starts, like a boot screen), and macOS's welcome screens for new accounts marked as
    /// seen again (after a macOS update, macOS would show them before kirki starts).
    static func prepareLoginAccount() {
        let fm = FileManager.default
        if let source = Bundle.main.url(forResource: "wallpaper", withExtension: "png") {
            try? Paths.ensure(Paths.support)
            try? fm.removeItem(at: Paths.wallpaper)
            try? fm.copyItem(at: source, to: Paths.wallpaper)
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(Paths.wallpaper, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                    .fillColor: Brand.inkNS,
                ])
            }
        }
        let domain = "com.apple.SetupAssistant" as CFString
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let product = os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)"
                                           : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        for key in seenKeys {
            CFPreferencesSetAppValue(key as CFString, kCFBooleanTrue, domain)
        }
        for key in ["LastSeenCloudProductVersion", "LastSeenDiagnosticsProductVersion", "LastSeenSiriProductVersion",
                    "LastSeenAppleIntelligenceProductVersion"] {
            CFPreferencesSetAppValue(key as CFString, product as CFString, domain)
        }
        if let build = HostInfo.sysctl("kern.osversion") {
            CFPreferencesSetAppValue("LastSeenBuddyBuildVersion" as CFString, build as CFString, domain)
        }
        CFPreferencesAppSynchronize(domain)
    }

    /// The new-account screens macOS's Setup Assistant shows (the installer writes the same).
    static let seenKeys = [
        "DidSeeAccessibility", "DidSeeActivationLock", "DidSeeAppearanceSetup", "DidSeeApplePaySetup",
        "DidSeeAvatarSetup", "DidSeeCloudSetup", "DidSeeiCloudLoginForStorageServices", "DidSeeIntelligence",
        "DidSeeLockdownMode", "DidSeePrivacy", "DidSeeScreenTime", "DidSeeSiriSetup", "DidSeeSyncSetup",
        "DidSeeSyncSetup2", "DidSeeTermsOfAddress", "DidSeeTouchIDSetup", "DidSeeTrueTonePrivacy",
        "DidSeeWallpaperSetup", "DidSeeAgeRange", "SkipFirstLoginOptimization",
    ]
}

/// Logging out and shutting down the Mac, by asking loginwindow (as the Apple menu does).
enum SystemActions {
    static func logOut() {
        Log.info("Logging out of the Mac")
        if send("rlgo") { return }                  // kAEReallyLogOut: no "are you sure?"
        // If macOS didn't let kirki ask, end the login session directly (kirki is already off).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())"]
        do { try p.run() } catch { Log.error("Couldn't log out: \(error)") }
    }

    static func shutDownMac() {
        Log.info("Shutting down the Mac")
        if !send("shut") { logOut() }               // kAEShutDown
    }

    /// Sends a core Apple event (class 'aevt') to loginwindow.
    private static func send(_ code: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(eventClass: fourCC("aevt"), eventID: fourCC(code), targetDescriptor: target,
                                           returnID: AEReturnID(-1), transactionID: AETransactionID(0))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
            return true
        } catch {
            Log.error("loginwindow didn't take '\(code)': \(error.localizedDescription)")
            return false
        }
    }

    private static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
