import AppKit
import KirkiCore
import SwiftUI
import Virtualization

enum AppMode {
    /// The kirki login: kirki fills the screen and is the whole session, like starting another system
    case session
    /// kirki in a window, alongside the Mac's other apps
    case window
}

/// A borderless window still takes the keyboard (kirki needs it).
final class KirkiWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The app's one window. In the kirki login it covers the whole screen (below the camera notch, on
/// Macs that have one); otherwise it's an ordinary window. It shows kirki, or the status screen.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    let mode: AppMode
    let window: KirkiWindow
    private let container = NSView()
    private let statusView: NSHostingView<StatusView>
    private(set) var vmView: VZVirtualMachineView?
    private var topInset: NSLayoutConstraint?

    init(mode: AppMode, status: StatusModel) {
        self.mode = mode
        statusView = NSHostingView(rootView: StatusView(model: status))
        if mode == .session {
            let screen = Self.mainScreen
            window = KirkiWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.hasShadow = false
            window.isMovable = false
            window.setFrame(screen.frame, display: false)
        } else {
            window = KirkiWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            window.title = "kirki"
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.tabbingMode = .disallowed
            window.collectionBehavior = [.fullScreenPrimary]
            window.center()
            _ = window.setFrameAutosaveName("kirki")
        }
        window.backgroundColor = Brand.inkNS
        window.isReleasedWhenClosed = false
        container.wantsLayer = true
        container.layer?.backgroundColor = Brand.inkNS.cgColor
        window.contentView = container
        super.init()
        window.delegate = self
        place(statusView, belowNotch: false)
    }

    /// The screen with the menu bar
    static var mainScreen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    func present() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showStatus() {
        if mode == .window { window.contentResizeIncrements = NSSize(width: 1, height: 1) }   // any shape again
        vmView?.virtualMachine = nil
        vmView = nil
        place(statusView, belowNotch: false)
    }

    func showVM(_ vm: VZVirtualMachine, capturesSystemKeys: Bool) {
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = capturesSystemKeys
        // kirki's screen keeps the size it started with; the view scales it (a window keeps its shape).
        // Changing it underneath kirki isn't followed by the setup window, so its bottom was cut off.
        view.automaticallyReconfiguresDisplay = false
        vmView = view
        place(view, belowNotch: mode == .session)
        window.makeFirstResponder(view)
    }

    func setCapturesSystemKeys(_ on: Bool) {
        vmView?.capturesSystemKeys = on
    }

    /// The size kirki's screen should be. Always the whole screen's (below the notch): in the kirki
    /// login that's the window, and in a window it's what full screen shows, so going full screen
    /// fits exactly. A window keeps the same shape as kirki's screen (see fitWindow), so nothing is
    /// cut off: kirki doesn't change its resolution when the window changes size.
    func display(retina: Bool) -> DisplayConfiguration {
        let screen = mode == .session ? Self.mainScreen : (window.screen ?? Self.mainScreen)
        let points = CGSize(width: screen.frame.width, height: screen.frame.height - screen.safeAreaInsets.top)
        return DisplayConfiguration.fitting(points: points, backingScale: screen.backingScaleFactor, retina: retina)
    }

    /// In a window: give it kirki's screen's shape, as big as fits where it is, and keep that shape
    /// when it's resized.
    func fitWindow(to display: DisplayConfiguration) {
        guard mode == .window else { return }
        let aspect = NSSize(width: display.width, height: display.height)
        window.contentAspectRatio = aspect
        guard !window.styleMask.contains(.fullScreen) else { return }
        let visible = (window.screen ?? Self.mainScreen).visibleFrame
        let current = window.contentLayoutRect.size
        let chrome = window.frame.height - current.height        // the title bar
        let maxW = min(max(current.width, 640), visible.width)
        let maxH = min(max(current.height, 400), visible.height - chrome)
        let k = min(maxW / aspect.width, maxH / aspect.height)
        let size = NSSize(width: (aspect.width * k).rounded(), height: (aspect.height * k).rounded())
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = min(max(window.frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(window.frame.maxY - frame.height, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    /// The kirki login: displays were added, removed or changed. Cover the main screen again.
    func screensChanged() {
        guard mode == .session else { return }
        let screen = Self.mainScreen
        window.setFrame(screen.frame, display: true)
        topInset?.constant = screen.safeAreaInsets.top
    }

    private func place(_ view: NSView, belowNotch: Bool) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        let inset = belowNotch ? Self.mainScreen.safeAreaInsets.top : 0
        let top = view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset)
        topInset = belowNotch ? top : nil
        NSLayoutConstraint.activate([
            top,
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // In a window, closing it quits the app, which shuts kirki down first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

/// The kirki Settings window.
@MainActor
final class SettingsWindowController {
    let window: NSWindow

    init(model: SettingsModel) {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        window = NSWindow(contentViewController: hosting)
        window.title = "kirki Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating            // above kirki, in the kirki login too
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
