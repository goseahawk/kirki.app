import Carbon
import Foundation
import KirkiCore
import Virtualization

/// kirki's screen in the virtual machine: its size in pixels, and how much kirki should scale its
/// desktop (2 on a Retina screen, so text is as sharp and as big as in macOS).
struct DisplayConfiguration: Equatable {
    var width: Int
    var height: Int
    var scale: Double

    /// The size for a view of `points`, on a screen with `backingScale`. kirki draws with the CPU, so
    /// very large screens (5K and up) get fewer pixels than they have, scaled up by macOS.
    static func fitting(points: CGSize, backingScale: CGFloat, retina: Bool) -> DisplayConfiguration {
        let factor = retina ? max(Double(backingScale), 1) : 1
        var w = Double(points.width) * factor
        var h = Double(points.height) * factor
        let maxPixels = 3840.0 * 2160.0
        if w * h > maxPixels {
            let f = (maxPixels / (w * h)).squareRoot()
            w *= f
            h *= f
        }
        let width = max(640, Int(w) & ~1)
        let height = max(400, Int(h) & ~1)
        let scale = (Double(width) / max(Double(points.width), 1) * 4).rounded() / 4     // to the nearest 0.25
        return DisplayConfiguration(width: width, height: height, scale: max(1, scale))
    }

    var scaleText: String { scale == scale.rounded() ? String(Int(scale)) : String(scale) }
}

/// kirki's files in vm/: its identity (machine identifier, network address) and EFI variables stay
/// the same from one start to the next.
enum VMFiles {
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.disk.path) && InstalledImage.load() != nil
    }

    static func machineIdentifier() -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: Paths.machineIdentifier),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let id = VZGenericMachineIdentifier()
        try? id.dataRepresentation.write(to: Paths.machineIdentifier, options: .atomic)
        return id
    }

    static func efiVariableStore() throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: Paths.efiVariables.path) {
            return VZEFIVariableStore(url: Paths.efiVariables)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: Paths.efiVariables)
    }

    static func macAddress() -> VZMACAddress {
        if let text = try? String(contentsOf: Paths.macAddress, encoding: .utf8),
           let address = VZMACAddress(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return address
        }
        let address = VZMACAddress.randomLocallyAdministered()
        try? address.string.write(to: Paths.macAddress, atomically: true, encoding: .utf8)
        return address
    }

    /// Deletes kirki: its disk and everything about the virtual machine (the settings stay).
    static func erase() throws {
        if FileManager.default.fileExists(atPath: Paths.vm.path) {
            try FileManager.default.removeItem(at: Paths.vm)
        }
        try? FileManager.default.removeItem(at: Paths.downloads)
    }
}

enum VMConfigurationBuilder {
    static let controlPortName = "org.kirki.control"

    static func make(settings: Settings, display: DisplayConfiguration, channel: GuestChannel,
                     console: ConsoleLog) throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        c.cpuCount = min(max(settings.processors, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                         VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = UInt64(settings.memoryGB) << 30
        c.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                           VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // EFI firmware starts GRUB from the disk's EFI partition, as on any PC
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VMFiles.machineIdentifier()
        c.platform = platform
        let boot = VZEFIBootLoader()
        boot.variableStore = try VMFiles.efiVariableStore()
        c.bootLoader = boot

        // The disk: a sparse file, cached by macOS, flushed when kirki asks (as a real disk would be)
        let disk = try VZDiskImageStorageDeviceAttachment(url: Paths.disk, readOnly: false,
                                                          cachingMode: .automatic, synchronizationMode: .fsync)
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        // Network through the Mac's own connection (Wi-Fi, Ethernet, VPN...): kirki sees a wired network
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = VMFiles.macAddress()
        c.networkDevices = [network]

        // The screen, at the Mac's resolution
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: display.width, heightInPixels: display.height)]
        c.graphicsDevices = [gpu]
        c.keyboards = [VZUSBKeyboardConfiguration()]
        c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Sound through the Mac's speakers or headphones (and its microphone, if allowed)
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = [output]
        if settings.microphone {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            streams.append(input)
        }
        sound.streams = streams
        c.audioDevices = [sound]

        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // hvc0: kirki's kernel log (console.log), and the control port kirk-vm-agent talks on
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = console.attachment
        c.serialPorts = [serial]
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let port = VZVirtioConsolePortConfiguration()
        port.name = controlPortName
        port.attachment = channel.attachment
        consoleDevice.ports[0] = port
        c.consoleDevices = [consoleDevice]

        // Rosetta, so kirki can run programs made for Intel and AMD computers (kirk-vm-rosetta)
        if settings.rosetta {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed:
                let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                rosetta.share = try VZLinuxRosettaDirectoryShare()
                c.directorySharingDevices = [rosetta]
            case .notInstalled:
                Log.info("Rosetta isn't installed on this Mac (kirki's settings can install it)")
            case .notSupported:
                break
            @unknown default:
                break
            }
        }

        try c.validate()
        return c
    }
}

/// What kirki learns about the Mac when it starts (kirk-vm-agent saves it in /run/kirki/host.env):
/// the keyboard layout and time zone for its first-start setup, the model for its About page, and how
/// much to scale its desktop.
enum HostDetails {
    static func forGuest(display: DisplayConfiguration, host: HostInfo) -> [String: String] {
        var info: [String: String] = [
            "TIMEZONE": TimeZone.current.identifier,
            "LOCALE": Locale.current.identifier,
            "MAC_MODEL": host.model,
            "MAC_CHIP": host.chip,
            "DISPLAY_SCALE": display.scaleText,
            "APP_VERSION": AppInfo.version,
        ]
        if let id = currentKeyboardLayoutID(), let xkb = KeyboardLayouts.xkb(forMacLayoutID: id) {
            info["KEYBOARD_LAYOUT"] = xkb.layout
            if !xkb.variant.isEmpty { info["KEYBOARD_VARIANT"] = xkb.variant }
        }
        return info
    }

    static func currentKeyboardLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

/// The control port: one line per message, both ways (KirkiCore's GuestMessage and HostMessage).
final class GuestChannel: @unchecked Sendable {
    private let toGuest = Pipe()
    private let fromGuest = Pipe()
    private let splitter = LineSplitter()
    private let writes = DispatchQueue(label: "io.github.goseahawk.kirki.channel")
    /// Called on the main queue
    var onMessage: ((GuestMessage) -> Void)?

    lazy var attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: toGuest.fileHandleForReading,
        fileHandleForWriting: fromGuest.fileHandleForWriting)

    init() {
        fromGuest.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = self.splitter.append(data).filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                for line in lines { self.onMessage?(GuestMessage(line: line)) }
            }
        }
    }

    func send(_ message: HostMessage) {
        let data = Data((message.line + "\n").utf8)
        if case .hostinfo = message { Log.info("To kirki: \(message.line)") }
        writes.async { [toGuest] in
            try? toGuest.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func close() {
        fromGuest.fileHandleForReading.readabilityHandler = nil
    }
}

/// kirki's kernel console (hvc0), kept in ~/Library/Logs/kirki/console.log (the previous start's is
/// console.1.log). Its last words also say whether kirki is restarting or shutting down.
final class ConsoleLog: @unchecked Sendable {
    private let pipe = Pipe()
    private let splitter = LineSplitter()
    private var file: FileHandle?
    private var written = 0
    /// Called on the main queue
    var onIntent: ((PowerIntent) -> Void)?

    lazy var attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil,
                                                          fileHandleForWriting: pipe.fileHandleForWriting)

    init() {
        let fm = FileManager.default
        try? Paths.ensure(Paths.logs)
        let old = Paths.logs.appendingPathComponent("console.1.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: Paths.consoleLog, to: old)
        fm.createFile(atPath: Paths.consoleLog.path, contents: nil)
        file = try? FileHandle(forWritingTo: Paths.consoleLog)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if self.written < 20_000_000 {
                try? self.file?.write(contentsOf: data)
                self.written += data.count
            }
            for line in self.splitter.append(data) {
                if let intent = PowerIntent.fromConsole(line) {
                    DispatchQueue.main.async { self.onIntent?(intent) }
                }
            }
        }
    }

    func close() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? file?.close()
        file = nil
    }
}
