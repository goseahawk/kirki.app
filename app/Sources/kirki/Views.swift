import AppKit
import KirkiCore
import SwiftUI
import Virtualization

/// What the app shows when kirki itself isn't on screen: getting kirki ready, kirki shut down, or
/// something gone wrong, always with a way forward.
@MainActor
final class StatusModel: ObservableObject {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        var primary = false
        let run: () -> Void
    }

    @Published var title = ""
    @Published var message = ""
    /// 0...1 for a progress bar, or nil
    @Published var progress: Double?
    /// A spinner, when there's no progress to show
    @Published var busy = false
    @Published var detail = ""
    @Published var actions: [Action] = []
    /// Error details, for anyone who wants them
    @Published var technical: String?

    func show(title: String, message: String = "", progress: Double? = nil, busy: Bool = false,
              detail: String = "", actions: [Action] = [], technical: String? = nil) {
        self.title = title
        self.message = message
        self.progress = progress
        self.busy = busy
        self.detail = detail
        self.actions = actions
        self.technical = technical
    }
}

struct StatusView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            VStack(spacing: 22) {
                if let logo = Brand.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 300)
                        .padding(.bottom, 8)
                }
                Text(model.title)
                    .font(Brand.font(26, weight: .bold))
                    .foregroundColor(Brand.bone)
                    .multilineTextAlignment(.center)
                if !model.message.isEmpty {
                    Text(model.message)
                        .font(Brand.font(16))
                        .foregroundColor(Brand.bone.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress = model.progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(Brand.marigold)
                        .frame(width: 380)
                } else if model.busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.regular)
                        .tint(Brand.marigold)
                        .environment(\.colorScheme, .dark)
                }
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(Brand.font(13))
                        .foregroundColor(Brand.bone.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                if !model.actions.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(model.actions) { action in
                            Button(action.title, action: action.run)
                                .buttonStyle(KirkiButtonStyle(primary: action.primary))
                        }
                    }
                    .padding(.top, 6)
                }
                if let technical = model.technical {
                    ScrollView {
                        Text(technical)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Brand.bone.opacity(0.55))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 600, maxHeight: 120)
                }
            }
            .padding(40)
        }
    }
}

struct KirkiButtonStyle: ButtonStyle {
    var primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.font(15, weight: .medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .foregroundColor(primary ? Brand.ink : Brand.bone)
            .background(RoundedRectangle(cornerRadius: 10).fill(primary ? Brand.marigold : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(primary ? Color.clear : Brand.bone.opacity(0.35), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Settings

@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            do { try settings.save() } catch { Log.error("Couldn't save the settings: \(error)") }
            onChange(settings)
        }
    }
    @Published var rosettaInstalled = VZLinuxRosettaDirectoryShare.availability == .installed
    let host: HostInfo
    let mode: AppMode
    let diskNowGB: Int
    let installedVersion: String?
    let onChange: (Settings) -> Void
    let restart: () -> Void
    let erase: () -> Void

    init(settings: Settings, host: HostInfo, mode: AppMode, onChange: @escaping (Settings) -> Void,
         restart: @escaping () -> Void, erase: @escaping () -> Void) {
        self.settings = settings
        self.host = host
        self.mode = mode
        self.diskNowGB = Int(DiskFile.size() >> 30)
        self.installedVersion = InstalledImage.load()?.version
        self.onChange = onChange
        self.restart = restart
        self.erase = erase
    }

    var rosettaSupported: Bool { VZLinuxRosettaDirectoryShare.availability != .notSupported }

    func installRosetta() {
        VZLinuxRosettaDirectoryShare.installRosetta { [weak self] error in
            onMain {
                if let error { Log.error("Rosetta wasn't installed: \(error.localizedDescription)") }
                self?.rosettaInstalled = VZLinuxRosettaDirectoryShare.availability == .installed
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmErase = false

    private var maxMemory: Int { max(2, model.host.memoryGB - 2) }
    private var minDisk: Int { max(Settings.minimumDiskGB, model.diskNowGB) }
    private var maxDisk: Int { max(minDisk, model.diskNowGB + model.host.freeDiskGB - 10) }

    var body: some View {
        Form {
            Section {
                Stepper(value: $model.settings.memoryGB, in: 2...maxMemory) {
                    LabeledContent("Memory", value: "\(model.settings.memoryGB) GB of \(model.host.memoryGB) GB")
                }
                Stepper(value: $model.settings.processors, in: 1...max(1, model.host.processorCount)) {
                    LabeledContent("Processors", value: "\(model.settings.processors) of \(model.host.processorCount)")
                }
                Stepper(value: $model.settings.diskGB, in: minDisk...max(minDisk, maxDisk), step: 8) {
                    LabeledContent("Disk", value: "\(model.settings.diskGB) GB")
                }
                Text("kirki's disk only takes the space kirki actually uses. It can grow, but not shrink.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("What kirki gets from this Mac")
            }

            Section {
                Toggle("Full Retina resolution", isOn: $model.settings.retina)
                Text("Sharp text, as in macOS. Turn it off for a faster desktop at half the resolution.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Microphone", isOn: $model.settings.microphone)
                if model.rosettaSupported {
                    Toggle("Intel and AMD programs (Rosetta)", isOn: $model.settings.rosetta)
                    if model.settings.rosetta && !model.rosettaInstalled {
                        HStack {
                            Text("Rosetta isn't installed on this Mac yet.").font(.caption)
                            Spacer()
                            Button("Install Rosetta") { model.installRosetta() }
                        }
                    }
                }
            } header: {
                Text("Hardware")
            }

            Section {
                Picker("When kirki shuts down", selection: $model.settings.whenKirkiShutsDown) {
                    Text("Log out (back to the login window)").tag(ShutdownAction.logOut)
                    Text("Shut down the Mac").tag(ShutdownAction.shutDownMac)
                }
                Picker("Mac menu bar", selection: $model.settings.macMenuBar) {
                    Text("Show it when the pointer reaches the top").tag(MenuBarMode.showAtTop)
                    Text("Never show it").tag(MenuBarMode.hidden)
                }
                Text("The menu bar has Wi-Fi, Bluetooth, sound, battery and Control Center. Settings are always a ⌃⌥⌘K away.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("The kirki login")
            }

            Section {
                Toggle("Pause kirki while another Mac account is in use", isOn: $model.settings.pauseWhenSwitchedAway)
                if model.mode == .window {
                    Toggle("Send shortcuts like ⌘Tab and ⌘Space to kirki", isOn: $model.settings.captureSystemKeysInWindow)
                }
            }

            Section {
                HStack {
                    Text(model.installedVersion.map { "kirki \($0) · app \(AppInfo.version)" } ?? "app \(AppInfo.version)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart kirki Now") { model.restart() }
                }
                HStack {
                    Text("Erasing deletes kirki and everything in it, and sets it up fresh.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Erase kirki…", role: .destructive) { confirmErase = true }
                }
            } footer: {
                Text("Changes take effect the next time kirki starts.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .confirmationDialog("Erase kirki and everything in it?", isPresented: $confirmErase) {
            Button("Erase kirki", role: .destructive) { model.erase() }
        } message: {
            Text("Your files, apps and settings in kirki are deleted, and kirki is set up again from the start.")
        }
    }
}
