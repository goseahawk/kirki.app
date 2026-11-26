import AppKit
import KirkiCore
import Virtualization

/// Runs the app: gets kirki set up the first time, starts it, restarts it when kirki restarts, and
/// in the kirki login, logs out (or shuts the Mac down) when kirki shuts down, like a dual boot.
@MainActor
final class KirkiController {
    let mode: AppMode
    let host = HostInfo.current
    private(set) var settings: AppSettings
    let status = StatusModel()
    let windowController: WindowController

    private var runner: VMRunner?
    private var installTask: Task<Void, Never>?
    private var terminating = false
    private var restartWanted = false
    private var lockFile: Int32 = -1
    private var activity: NSObjectProtocol?
    private var settingsWindow: SettingsWindowController?
    private var observers: [NSObjectProtocol] = []

    init(mode: AppMode) {
        self.mode = mode
        settings = AppSettings.load(host: host)
        windowController = WindowController(mode: mode, status: status)
    }

    func start() {
        Log.info("kirki app \(AppInfo.version) on \(host.model) (\(host.chip), \(host.memoryGB) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)), \(mode == .session ? "kirki login" : "in a window")")
        try? settings.save()
        windowController.present()
        if mode == .session {
            Session.applyPresentation(settings.macMenuBar)
            Session.prepareLoginAccount()
        }
        guard lock() else {
            status.show(title: "kirki is already running",
                        message: "kirki is open in another window or Mac account that uses the same files.",
                        actions: [.init(title: mode == .session ? "Log Out" : "Quit", primary: true, run: { [weak self] in self?.leave() })])
            return
        }
        observeSystem()
        if VMFiles.isInstalled { boot() } else { install() }
    }

    // MARK: Setting kirki up

    private func install() {
        windowController.showStatus()
        status.show(title: "Getting kirki ready", message: "Looking for the newest kirki…", busy: true,
                    actions: escapeActions())
        let installer = ImageInstaller(manifestURL: settings.manifestURL, diskGB: settings.diskGB)
        let throttle = Throttle(interval: 0.2)
        // install() is async and not tied to the main actor: the work happens off the main thread,
        // and this task comes back to the main thread when it's done.
        installTask = Task { [weak self] in
            do {
                let installed = try await installer.install { stage in
                    guard throttle.allow(stage) else { return }
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.showInstall(stage) }
                    }
                }
                self?.installed(installed)
            } catch is CancellationError {
                return
            } catch {
                self?.installFailed(error)
            }
        }
    }

    private func showInstall(_ stage: ImageInstaller.Stage) {
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        switch stage {
        case .checking:
            status.show(title: "Getting kirki ready", message: "Looking for the newest kirki…", busy: true, actions: escapeActions())
        case .downloading(let done, let total, let rate):
            var detail = "\(bytes.string(fromByteCount: done)) of \(bytes.string(fromByteCount: total))"
            if rate > 0 {
                let minutes = Int((Double(total - done) / rate / 60).rounded(.up))
                detail += minutes <= 1 ? " · less than a minute left" : " · about \(minutes) minutes left"
            }
            status.show(title: "Getting kirki ready", message: "Downloading kirki. You only need to do this once.",
                        progress: total > 0 ? Double(done) / Double(total) : nil, detail: detail, actions: escapeActions())
        case .unpacking(let done, let total):
            status.show(title: "Getting kirki ready", message: "Setting up kirki's disk.",
                        progress: total > 0 ? Double(done) / Double(total) : nil, detail: "This takes a minute or two.")
        case .finishing:
            status.show(title: "Getting kirki ready", message: "Almost there…", busy: true)
        }
    }

    private func installed(_ image: InstalledImage) {
        installTask = nil
        guard !terminating else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        boot()
    }

    private func installFailed(_ error: Error) {
        installTask = nil
        Log.error("Setting kirki up failed: \(error)")
        if terminating {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        let offline = (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut, .cannotConnectToHost].contains($0.code) } ?? false
        status.show(title: offline ? "kirki can't be downloaded right now" : "kirki couldn't be set up",
                    message: offline ? "This Mac isn't connected to the internet, or GitHub can't be reached. Connect, then try again; the download carries on where it stopped."
                                     : error.localizedDescription,
                    actions: [.init(title: "Try Again", primary: true, run: { [weak self] in self?.install() })] + escapeActions(),
                    technical: offline ? nil : String(describing: error))
    }

    // MARK: Running kirki

    private func boot() {
        do {
            try DiskFile.grow(toGB: settings.diskGB)
            let display = windowController.display(retina: settings.retina)
            let runner = try VMRunner(settings: settings, display: display, host: host)
            runner.onEvent = { [weak self, weak runner] event in
                guard let self, let runner, runner === self.runner else { return }
                self.handle(event)
            }
            self.runner = runner
            windowController.showVM(runner.vm, capturesSystemKeys: mode == .session || settings.captureSystemKeysInWindow)
            windowController.fitWindow(to: display)
            beginActivity()
            runner.start()
        } catch {
            fail("kirki couldn't start", error: error)
        }
    }

    private func handle(_ event: VMRunner.Event) {
        switch event {
        case .running:
            break
        case .stopped(let intent):
            runner = nil
            endActivity()
            if terminating {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if restartWanted || intent == .reboot {
                restartWanted = false
                Log.info("Starting kirki again")
                boot()
            } else {
                kirkiWasShutDown()
            }
        case .failed(let error):
            runner = nil
            endActivity()
            if terminating {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                fail("kirki stopped unexpectedly", error: error)
            }
        }
    }

    /// kirki was shut down from inside: in the kirki login, that ends the Mac session too.
    private func kirkiWasShutDown() {
        Log.info("kirki was shut down")
        windowController.showStatus()
        var actions: [StatusModel.Action] = [.init(title: "Start kirki", primary: true, run: { [weak self] in self?.boot() })]
        if mode == .session {
            actions.append(.init(title: "Log Out", run: { SystemActions.logOut() }))
            actions.append(.init(title: "Shut Down", run: { SystemActions.shutDownMac() }))
            status.show(title: "kirki is shut down", message: settings.whenKirkiShutsDown == .logOut
                        ? "Logging out of the Mac…" : "Shutting down the Mac…", actions: actions)
            switch settings.whenKirkiShutsDown {
            case .logOut: SystemActions.logOut()
            case .shutDownMac: SystemActions.shutDownMac()
            }
        } else {
            actions.append(.init(title: "Quit", run: { NSApp.terminate(nil) }))
            status.show(title: "kirki is shut down", actions: actions)
        }
    }

    private func fail(_ title: String, error: Error? = nil, message: String? = nil) {
        if let error { Log.error("\(title): \(error)") }
        windowController.showStatus()
        status.show(title: title, message: message ?? error?.localizedDescription ?? "",
                    actions: [.init(title: "Try Again", primary: true, run: { [weak self] in self?.retry() })] + escapeActions(),
                    technical: error.map { String(describing: $0) })
    }

    private func retry() {
        if runner != nil { return }
        if VMFiles.isInstalled { boot() } else { install() }
    }

    /// The way out when kirki isn't running
    private func escapeActions() -> [StatusModel.Action] {
        mode == .session ? [.init(title: "Log Out", run: { SystemActions.logOut() })]
                         : [.init(title: "Quit", run: { NSApp.terminate(nil) })]
    }

    private func leave() {
        if mode == .session { SystemActions.logOut() } else { NSApp.terminate(nil) }
    }

    // MARK: Menu commands

    func restartKirki() {
        guard let runner else { retry(); return }
        restartWanted = true
        runner.restart(timeout: 60)
    }

    func shutDownKirki() {
        runner?.shutDown(timeout: 60)
    }

    /// The kirki login: the app became active again (after a Mac dialog, or switching back).
    func reapplyPresentation() {
        if mode == .session { Session.applyPresentation(settings.macMenuBar) }
    }

    func logOutOfMac() {
        // loginwindow asks the app to quit, which shuts kirki down first
        SystemActions.logOut()
    }

    func showSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(settings: settings, host: host, mode: mode,
                                      onChange: { [weak self] in self?.settingsChanged($0) },
                                      restart: { [weak self] in self?.restartKirki() },
                                      erase: { [weak self] in self?.erase() })
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show()
    }

    private func settingsChanged(_ new: AppSettings) {
        settings = new
        if mode == .session { Session.applyPresentation(new.macMenuBar) }
        if mode == .window { windowController.setCapturesSystemKeys(new.captureSystemKeysInWindow) }
    }

    private func erase() {
        settingsWindow?.window.close()
        settingsWindow = nil
        let wipe = { [weak self] in
            guard let self else { return }
            do {
                try VMFiles.erase()
                Log.info("kirki was erased")
            } catch {
                self.fail("kirki couldn't be erased", error: error)
                return
            }
            self.install()
        }
        if let runner {
            restartWanted = false
            runner.onEvent = { [weak self] _ in
                self?.runner = nil
                self?.endActivity()
                wipe()
            }
            runner.forceStop()
        } else {
            wipe()
        }
    }

    // MARK: Quitting

    /// The app is asked to quit (Quit, closing the window, or logging out of the Mac): shut kirki down
    /// first, then quit.
    func shouldTerminate() -> NSApplication.TerminateReply {
        if let installTask {
            installTask.cancel()
            self.installTask = nil
        }
        guard let runner, runner.isActive else { return .terminateNow }
        terminating = true
        Log.info("Quitting: shutting kirki down first")
        runner.shutDown(timeout: 45)
        return .terminateLater
    }

    // MARK: The Mac around kirki

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.pauseWhenSwitchedAway else { return }
                Log.info("Another Mac account is in use: pausing kirki")
                self.runner?.pause()
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.runner?.isPaused == true { self.runner?.resume() }
                if self.mode == .session { Session.applyPresentation(self.settings.macMenuBar) }
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated { self?.runner?.syncTime() }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowController.screensChanged() }
        })
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "kirki is running")
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("kirki is running")
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        ProcessInfo.processInfo.enableSuddenTermination()
        ProcessInfo.processInfo.enableAutomaticTermination("kirki is running")
    }

    /// One app per kirki: the disk can't be used twice.
    private func lock() -> Bool {
        try? Paths.ensure(Paths.vm)
        lockFile = open(Paths.lock.path, O_CREAT | O_RDWR, 0o644)
        return lockFile >= 0 && flock(lockFile, LOCK_EX | LOCK_NB) == 0
    }
}

/// Lets progress through at most every `interval` seconds, but always when the stage changes.
final class Throttle: @unchecked Sendable {
    private let interval: TimeInterval
    private var last = Date.distantPast
    private var lastKind = ""
    private let lock = NSLock()

    init(interval: TimeInterval) { self.interval = interval }

    func allow(_ stage: ImageInstaller.Stage) -> Bool {
        let kind = stage.name
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard kind != lastKind || now.timeIntervalSince(last) >= interval else { return false }
        last = now
        lastKind = kind
        return true
    }
}
