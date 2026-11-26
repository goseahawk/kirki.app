import Foundation
import KirkiCore
import Virtualization

/// One run of kirki's virtual machine, from start to stop. A restart is a new VMRunner.
@MainActor
final class VMRunner: NSObject, VZVirtualMachineDelegate {
    enum Event {
        case running
        /// kirki stopped: restarting, shut down, or (unknown) stopped without saying
        case stopped(PowerIntent)
        case failed(Error)
    }

    let vm: VZVirtualMachine
    let display: DisplayConfiguration
    var onEvent: ((Event) -> Void)?
    private(set) var agentReady = false

    private let channel = GuestChannel()
    private let console = ConsoleLog()
    private let host: HostInfo
    private var intent: PowerIntent = .unknown
    private var deadline: DispatchWorkItem?
    private var finished = false
    /// macOS can save a whole running VM and bring it back instantly (macOS 14), but not every
    /// configuration: today it doesn't take virtio graphics, which kirki needs. Used when it can.
    private let canSaveState: Bool

    init(settings: Settings, display: DisplayConfiguration, host: HostInfo) throws {
        self.display = display
        self.host = host
        let configuration = try VMConfigurationBuilder.make(settings: settings, display: display,
                                                            channel: channel, console: console)
        var saveRestore = false
        do {
            try configuration.validateSaveRestoreSupport()
            saveRestore = true
        } catch {
            Log.info("Instant resume isn't available for kirki's VM on this Mac (\(error.localizedDescription))")
        }
        canSaveState = saveRestore
        vm = VZVirtualMachine(configuration: configuration)
        super.init()
        vm.delegate = self
        channel.onMessage = { [weak self] message in onMain { self?.guestSaid(message) } }
        console.onIntent = { [weak self] intent in
            onMain {
                guard let self, self.intent == .unknown else { return }
                self.intent = intent
            }
        }
        Log.info("kirki's VM: \(settings.processors) processors, \(settings.memoryGB) GB, screen \(display.width)x\(display.height) at \(display.scaleText)x")
    }

    /// Running, starting, or paused: something that has to be stopped before the app quits.
    var isActive: Bool {
        switch vm.state {
        case .stopped, .error: return false
        default: return !finished
        }
    }

    var isPaused: Bool { vm.state == .paused }

    // MARK: Starting

    func start() {
        if canSaveState && FileManager.default.fileExists(atPath: Paths.savedState.path) {
            Log.info("Resuming kirki where it was")
            vm.restoreMachineStateFrom(url: Paths.savedState) { [weak self] error in
                onMain {
                    guard let self else { return }
                    try? FileManager.default.removeItem(at: Paths.savedState)
                    if let error {
                        Log.error("Couldn't resume kirki (\(error.localizedDescription)); starting it afresh")
                        self.coldStart()
                        return
                    }
                    self.vm.resume { result in
                        onMain {
                            switch result {
                            case .success:
                                self.onEvent?(.running)
                                self.channel.send(.ping)       // the agent answers once it notices
                                self.syncTime()
                            case .failure(let error):
                                self.finish(.failed(error))
                            }
                        }
                    }
                }
            }
        } else {
            try? FileManager.default.removeItem(at: Paths.savedState)
            coldStart()
        }
    }

    private func coldStart() {
        vm.start { [weak self] result in
            onMain {
                guard let self else { return }
                switch result {
                case .success:
                    Log.info("kirki is starting")
                    self.onEvent?(.running)
                case .failure(let error):
                    Log.error("kirki couldn't start: \(error)")
                    self.finish(.failed(error))
                }
            }
        }
    }

    // MARK: Stopping

    /// Shuts kirki down the way its own Shut Down does (apps close first), or saves it to resume
    /// instantly next time, where macOS can. After `timeout` seconds it's stopped regardless.
    func shutDown(timeout: TimeInterval) {
        guard !finished else { return }
        if vm.state == .paused {
            vm.resume { [weak self] _ in
                onMain { self?.shutDown(timeout: timeout) }
            }
            return
        }
        if canSaveState && vm.state == .running {
            saveAndStop(timeout: timeout)
            return
        }
        Log.info("Asking kirki to shut down")
        if agentReady {
            channel.send(.shutdown)
        } else if vm.canRequestStop {
            try? vm.requestStop()       // the VM's power button: kirki shuts down cleanly
        }
        arm(timeout)
    }

    func restart(timeout: TimeInterval) {
        guard !finished else { return }
        Log.info("Asking kirki to restart")
        if agentReady {
            channel.send(.reboot)
        } else if vm.canRequestStop {
            try? vm.requestStop()
        }
        arm(timeout)
    }

    private func arm(_ timeout: TimeInterval) {
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self] in
            onMain { self?.forceStop() }
        }
        deadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Turns the VM off at once, like holding a computer's power button.
    func forceStop() {
        guard !finished else { return }
        guard vm.canStop else {
            finish(.stopped(intent))
            return
        }
        Log.error("kirki didn't stop in time; turning it off")
        vm.stop { [weak self] _ in
            onMain {
                guard let self else { return }
                self.finish(.stopped(self.intent))
            }
        }
    }

    private func saveAndStop(timeout: TimeInterval) {
        Log.info("Saving kirki to resume it next time")
        vm.pause { [weak self] result in
            onMain {
                guard let self else { return }
                guard case .success = result else {
                    self.plainShutDown(timeout: timeout)
                    return
                }
                self.vm.saveMachineStateTo(url: Paths.savedState) { error in
                    onMain {
                        if let error {
                            Log.error("Couldn't save kirki (\(error.localizedDescription)); shutting it down instead")
                            try? FileManager.default.removeItem(at: Paths.savedState)
                            self.vm.resume { _ in
                                onMain { self.plainShutDown(timeout: timeout) }
                            }
                            return
                        }
                        self.vm.stop { _ in
                            onMain { self.finish(.stopped(.poweroff)) }
                        }
                    }
                }
            }
        }
    }

    private func plainShutDown(timeout: TimeInterval) {
        if agentReady { channel.send(.shutdown) } else { try? vm.requestStop() }
        arm(timeout)
    }

    // MARK: While it runs

    /// Pauses kirki (it uses no processor time, and keeps its memory).
    func pause() {
        guard vm.canPause else { return }
        vm.pause { result in
            if case .failure(let error) = result { Log.error("Couldn't pause kirki: \(error.localizedDescription)") }
            else { Log.info("kirki is paused") }
        }
    }

    func resume() {
        guard vm.canResume else { return }
        vm.resume { [weak self] result in
            onMain {
                if case .failure(let error) = result { Log.error("Couldn't resume kirki: \(error.localizedDescription)") }
                else {
                    Log.info("kirki carries on")
                    self?.syncTime()
                }
            }
        }
    }

    /// kirki's clock stands still while the Mac sleeps or kirki is paused: set it from the Mac's.
    func syncTime() {
        guard agentReady, !finished else { return }
        channel.send(.time(Date()))
    }

    private func guestSaid(_ message: GuestMessage) {
        switch message {
        case .ready(let version):
            Log.info("kirki is up (agent \(version))")
            agentReady = true
            channel.send(.hostinfo(HostDetails.forGuest(display: display, host: host)))
            channel.send(.time(Date()))
            channel.send(.status)
        case .power(let what):
            intent = PowerIntent.fromPowerMessage(what)
            Log.info("kirki is stopping: \(what)")
        case .status(let values):
            Log.info("kirki status: " + values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: " "))
        case .pong:
            agentReady = true
        case .unknown(let line):
            Log.info("kirki said: \(line.prefix(200))")
        }
    }

    private func finish(_ event: Event) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        channel.close()
        console.close()
        onEvent?(event)
    }

    // MARK: VZVirtualMachineDelegate (on the main queue, where the VM was made)

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        // kirki's last words ("power reboot") may still be on their way through the pipe
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            onMain {
                guard let self else { return }
                Log.info("kirki stopped (\(self.intent.rawValue))")
                self.finish(.stopped(self.intent))
            }
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onMain { [weak self] in
            Log.error("kirki stopped with an error: \(error)")
            self?.finish(.failed(error))
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice,
                                    attachmentWasDisconnectedWithError error: Error) {
        Log.error("kirki's network was disconnected: \(error.localizedDescription)")
    }
}
