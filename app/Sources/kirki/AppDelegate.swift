import AppKit
import KirkiCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The kirki login: started with --session (by its launch agent, which the installer sets up), or
    /// opened by hand in the kirki account itself. Anywhere else, or with --window, kirki runs in a window.
    let mode: AppMode = {
        let args = CommandLine.arguments
        if args.contains("--window") { return .window }
        return args.contains("--session") || NSUserName() == "kirki" ? .session : .window
    }()
    private var controller: KirkiController!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Brand.registerFonts()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        controller = KirkiController(mode: mode)
        buildMenu()
        // ⌃⌥⌘K opens kirki's settings, even while kirki has the keyboard
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == [.control, .option, .command], event.charactersIgnoringModifiers?.lowercased() == "k" {
                MainActor.assumeIsolated { self?.controller.showSettings() }
                return nil
            }
            return event
        }
        controller.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.reapplyPresentation()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shouldTerminate() ?? .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        mode == .window
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("The kirki app is quitting")
        Log.flush()
    }

    // MARK: Menus

    private func buildMenu() {
        let main = NSMenu()

        let app = NSMenu(title: "kirki")
        app.addItem(withTitle: "About kirki", action: #selector(about(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Restart kirki", action: #selector(restartKirki(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Shut Down kirki", action: #selector(shutDownKirki(_:)), keyEquivalent: "")
        app.addItem(.separator())
        if mode == .session {
            app.addItem(withTitle: "Log Out", action: #selector(logOut(_:)), keyEquivalent: "")
            app.addItem(withTitle: "Quit kirki and Show the Mac Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        } else {
            app.addItem(withTitle: "Hide kirki", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            app.addItem(.separator())
            app.addItem(withTitle: "Quit kirki", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
        main.addItem(withTitle: "kirki", action: nil, keyEquivalent: "").submenu = app

        // For the text in Settings
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        if mode == .window {
            let view = NSMenu(title: "View")
            let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            full.keyEquivalentModifierMask = [.command, .control]
            main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

            let window = NSMenu(title: "Window")
            window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
            NSApp.windowsMenu = window
        }

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "kirki Help", action: #selector(openHelp(_:)), keyEquivalent: "")
        help.addItem(withTitle: "Show Log Files", action: #selector(showLogs(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = help
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    @objc func about(_ sender: Any?) {
        let kirki = InstalledImage.load().map { "kirki \($0.version)\n" } ?? ""
        let credits = NSAttributedString(string: "\(kirki)github.com/goseahawk/kirki.app",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "kirki", .applicationVersion: AppInfo.version,
                                                     .version: "", .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) { controller.showSettings() }
    @objc func restartKirki(_ sender: Any?) { controller.restartKirki() }
    @objc func shutDownKirki(_ sender: Any?) { controller.shutDownKirki() }
    @objc func logOut(_ sender: Any?) { controller.logOutOfMac() }

    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/goseahawk/kirki.app#readme")!)
    }

    @objc func showLogs(_ sender: Any?) {
        Log.flush()
        NSWorkspace.shared.activateFileViewerSelecting([Paths.appLog])
    }
}
