# Developing kirki for Mac

How kirki for Mac is put together, for anyone changing it or building it. To install and use it, see
the [README](README.md).

kirki for Mac runs [kirki](https://github.com/goseahawk/kirki) (Arch Linux ARM with kirki's KDE Plasma
desktop) in a virtual machine, with Apple's Virtualization framework. Three parts:

- **the app** (`app/`): a Swift app that downloads kirki's disk image, runs it, and in the **kirki login**
  makes a Mac account feel like another system;
- **the image** (`image/`): kirki's own packages and files (from the kirki repository, at the commit in
  `image/kirki.ref`), set up for a virtual machine, plus the small pieces that talk to the app;
- **the installer** (`install.sh`): installs the app and makes the kirki login.

## Project layout

| Path | What it is |
|---|---|
| `install.sh` | the command people run in Terminal; published with each release |
| `app/Package.swift` | the Swift package: `KirkiCore` (testable logic), `kirki` (the app), tests |
| `app/Sources/KirkiCore/` | downloading and checking the image, unpacking it, settings, the app–kirki protocol |
| `app/Sources/kirki/` | the virtual machine, the window and the kirki login, menus and settings |
| `app/Resources/` | Info.plist, entitlements, icon and images (`app/tools/make-assets.py` makes them), DM Sans |
| `app/build-app.sh` | builds and signs `out/kirki.app` and `out/kirki-app.zip` on a Mac |
| `image/build.sh` | builds the disk image on ARM Linux: `out/kirki-vm-VERSION.img.xz` and `out/kirki-vm.json` |
| `image/setup.sh` | runs inside the image while it's built (kirki's `image/setup.sh`, for a VM) |
| `image/lib.sh` | shared by `setup.sh` and `apply-to-installed.sh`: packages, files, boot, services |
| `image/vm-overlay/` | the VM's own files, installed over kirki's `overlay/installed` |
| `image/kirki.ref` | the kirki commit the desktop comes from |
| `image/test-boot.py` | starts a built image in QEMU and checks it (the Release workflow runs it) |
| `apply-to-installed.sh` | updates an installed kirki VM to this version (kirk-update runs it) |
| `tests/install-test.sh` | tests `install.sh` on Linux against mocks of the macOS commands |
| `.github/workflows/app.yml` | builds and tests the app on every change; lints the scripts |
| `.github/workflows/release.yml` | builds the image and the app, tests the image, publishes a release |

## The kirki login

`install.sh` makes a standard macOS account called `kirki` (with `sysadminctl`, passing the admin's
credentials so it gets a secure token: with FileVault on, it's offered at startup) and puts a launch
agent in its `~/Library/LaunchAgents`, `io.github.goseahawk.kirki.session`. At login, that starts
`/Applications/kirki.app/Contents/MacOS/kirki --session` (again if it crashes; not after it quits
normally). It also marks macOS's new-account welcome screens as seen, and makes the account dark with
an auto-hiding Dock, so logging in goes straight to kirki.

In `--session` mode the app:

- covers the main screen with a borderless window (below the camera notch on Macs that have one) and
  sets presentation options: no Dock, no ⌘Tab, the menu bar hidden or sliding in at the top edge.
  `VZVirtualMachineView.capturesSystemKeys` sends ⌘Tab, ⌘Space and the like to kirki. Force Quit and
  the power button's menu stay, as a way out;
- sets kirki's dark wallpaper as the account's desktop picture (seen for a moment while kirki starts)
  and marks the welcome screens as seen again after macOS updates;
- when kirki shuts down, logs out of the Mac (or shuts it down; a setting), by sending loginwindow
  `kAEReallyLogOut` / `kAEShutDown`. If macOS refuses the Apple event, it falls back to
  `launchctl bootout gui/UID`;
- when the app is asked to quit (logging out from the Mac's menu bar, a Mac shutdown), shuts kirki down
  first (`applicationShouldTerminate` → `.terminateLater`).

Without `--session` (opened from the Applications folder), kirki runs in an ordinary window. Each Mac
account has its own kirki, in `~/Library/Application Support/kirki`.

## The virtual machine

`VMConfigurationBuilder` (`app/Sources/kirki/VMConfiguration.swift`):

| Device | Why |
|---|---|
| EFI (`VZEFIBootLoader`) | boots GRUB from the disk's EFI partition, so kernel updates in kirki just work |
| virtio block, `.automatic` caching, `.fsync` | the disk: `vm/disk.img`, a sparse raw file |
| virtio net, NAT | the Mac's own connection; a fixed MAC address per VM |
| virtio GPU, one scanout | the screen at the Mac's resolution (Retina: full pixels, kirki scales 2x); `automaticallyReconfiguresDisplay` |
| USB keyboard, USB absolute pointer | no mouse capture: the pointer moves freely in and out |
| virtio sound, in and out | the Mac's speakers, headphones and microphone |
| virtio console (hvc0) | kirki's kernel log → `~/Library/Logs/kirki/console.log` |
| virtio console port `org.kirki.control` | the control channel (below) |
| virtiofs `rosetta` | Apple's Rosetta for Linux, when installed: x86-64 programs run in kirki |
| entropy, memory balloon | the usual |

Defaults (`AppSettings.defaults`): about 60% of the Mac's memory (at least 4 GB, at most 32, leaving
macOS 3 GB), all its processors, a 64 GB disk. Very large screens (5K) get at most 3840×2160 pixels,
since kirki draws without a GPU.

**Why not a container?** On a Mac a container still runs inside a Linux virtual machine, and kirki
needs a whole system (its own kernel, systemd, a display), so running the VM directly is both simpler
and faster. The Virtualization framework uses Apple silicon's hardware virtualization: processors and
memory run at nearly native speed.

**Graphics.** The framework's virtio GPU has no 3D, so kirki draws with Mesa's llvmpipe on the
processors. To keep that quick, KWin's blur is off in the VM (`/etc/xdg/kwinrc`) and the Retina setting
can halve the pixels. A GPU-accelerated path (virgl or venus) isn't available in the framework.

**Instant resume.** macOS 14 can save a running VM and restore it later (`saveMachineStateTo`), but it
doesn't accept virtio graphics, which kirki needs, so the app shuts kirki down and starts it again
(`VMRunner` checks `validateSaveRestoreSupport()` and uses it if a future macOS allows it).

## The app and kirki talking

`kirk-vm-agent` (in the image, started by udev when the port appears) reads and writes lines on
`/dev/virtio-ports/org.kirki.control`; `GuestChannel` is the app's end. See the comment at the top of
`image/vm-overlay/usr/local/bin/kirk-vm-agent` for the messages. In short:

- kirki says `ready`; the app answers with `hostinfo` (keyboard layout, time zone, Mac model, display
  scale; kept in `/run/kirki/host.env`) and the time;
- the app sets kirki's clock after the Mac wakes (`time`): a VM's clock stands still while the Mac sleeps;
- the app asks kirki to `shutdown` or `reboot`: Plasma closes the apps first, then systemd stops;
- at the very end of stopping, `kirk-vm-power` (a systemd-shutdown hook) says `power reboot` or
  `power poweroff`. The framework reports both as "the guest stopped", so this is how the app knows to
  start kirki again. The kernel's last console line (`reboot: Restarting system` / `Power down`) is a
  backup.

## The image

`image/build.sh` (as root, on 64-bit ARM Linux) downloads kirki at `image/kirki.ref` and Arch Linux ARM,
runs `image/setup.sh` in a chroot (it must get to its last line, which leaves a marker the build checks),
and makes a GPT disk: a 256 MB EFI partition (GRUB as
`EFI/BOOT/BOOTAA64.EFI`) and kirki's Btrfs root with its subvolumes. It's compressed with xz, which the
app reads with macOS's own Compression framework, and split into parts under 2 GiB if needed.
`kirki-vm.json` lists the parts with sizes and SHA-256s.

`image/setup.sh` follows kirki's `image/setup.sh`, with these differences:

- **Kernel:** Arch Linux ARM's `linux-aarch64` instead of `linux-asahi`, and no Asahi packages. The
  generic kernel has the virtio drivers (Asahi's lacks the generic PCI host the framework uses). Its
  `/boot/Image` gets a `/boot/vmlinuz-linux` link, since GRUB's menu generator only finds `vmlinuz-*`.
- **Asahi ALARM's repository** is still added, but last (`kv_asahi_repo`): kirki's setup window,
  Calamares, is only packaged there. pacman takes a package from the first repository that has it, so
  everything else comes from Arch Linux ARM.
- **Sound:** the generic kernel doesn't build Linux's virtio sound driver (`CONFIG_SND_VIRTIO`), so it's
  built with DKMS (`/usr/src/virtio-snd-1`). `fetch-source.sh` takes the driver from Linux's own
  repository for each kernel's version (its file list from that version's Makefile), and keeps a copy
  for offline rebuilds. DKMS rebuilds it whenever the kernel is updated.
- **Package lists** are read from kirki's `image/setup.sh` (`kv_packages` in `image/lib.sh`), minus the
  Asahi ones, so new kirki packages come along by themselves.
- **Files:** kirki's `overlay/installed`, then VM versions of the two that name the Asahi kernel (made
  with `sed` and checked: `kirk-auto-update`'s "restart needed", the snapshot hook's targets), then
  `image/vm-overlay/`:

| File | What it does |
|---|---|
| `kirk-vm-agent` (+ udev rule, service) | the control channel |
| `kirk-vm-power` (systemd-shutdown) | tells the app "restart" or "shut down" |
| `kirk-vm-grow` (service) | grows the root partition and Btrfs into new disk space at every start |
| `kirk-vm-rosetta` (service) | mounts the Rosetta share and registers it with binfmt_misc |
| `kirk-vm-autologin` (service) | after first-start setup, logs the account in automatically (you've already logged in to the Mac) |
| `kirk-vm-display` (autostart) | the first login on a Retina screen: Plasma at the app's scale |
| `kirk-setup` | kirki's first-start setup with the Mac's keyboard and time zone, Retina scaling, and software rendering for cage |
| `kirk-about-model` | About this System shows the Mac it runs on |
| `kirk-update.conf` | releases come from goseahawk/kirki.app |
| `sleep.conf.d`, `powerdevilrc`, `kscreenlockerrc`, `kwinrc` | the Mac sleeps and locks, not kirki; no blur |

- **Kernel command line:** `console=hvc0 console=tty0` (the log for the app; the splash keeps the screen).
- **Boot menu:** hidden, 1 second; Esc while kirki starts shows it (and its snapshots).

### Updates in kirki

kirki's own `kirk-update` checks this repository's releases (`REPO=goseahawk/kirki.app` in
`/etc/kirk-update.conf`) after each `pacman -Syu`, and runs the new release's `apply-to-installed.sh`.
That downloads kirki at the release's `image/kirki.ref` and installs it the way `setup.sh` does
(`image/lib.sh`), without touching people's settings. Weekly system updates are kirki's
`kirk-auto-update` (its VM version).

### Bringing kirki changes over

kirki's desktop changes reach kirki for Mac when `image/kirki.ref` moves to a newer kirki commit and a
release is made. Check that `kv_packages` and `kv_derive_files` still find what they expect (the build
stops if not), that kirki's `kirk-setup` hasn't gained something the VM version needs, and that
nothing new in `overlay/installed` assumes Mac hardware.

## Building

- **The app**, on a Mac with Xcode 15 or later: `app/build-app.sh` (`KIRK_VERSION=26.11.26` to set the
  version). Tests: `swift test --package-path app`. It's signed ad hoc unless `KIRK_SIGN_IDENTITY` names
  a Developer ID certificate. The Virtualization entitlement works with ad hoc signing.
- **The image**, on ARM Linux: `sudo image/build.sh` (Ubuntu: `apt install libarchive-tools
  arch-install-scripts btrfs-progs dosfstools fdisk rsync curl xz-utils`). 30–90 minutes, about 20 GB.
  `KIRK_KEEP_RAW=yes` keeps the uncompressed image for `python3 image/test-boot.py
  out/kirki-vm-VERSION.img results/` (needs `qemu-system-arm qemu-utils qemu-efi-aarch64`).
- **On GitHub:** Actions → **Release** → Run workflow. "Just build" keeps everything with the run
  (download the `image`, `app` and `boot-test` artifacts); "Draft release" makes a release only you can
  see; "Publish release" makes it the one the install command uses. "Keep the latest release's image"
  skips the image build when only the app changed (the release then points at the older release's
  image files, so don't delete that release).
- **App built on your own Mac** (when GitHub's Macs aren't available): on a Mac with Xcode, run
  `KIRK_VERSION=26.11.26 app/build-app.sh`, then on GitHub: Releases → Draft a new release, tag
  `26.11.26`, attach `out/kirki-app.zip` and `out/kirki-app.zip.sha256`, **Save draft**. Then run
  **Release** with "The kirki app" set to "Use the kirki-app.zip uploaded…" (version empty uses the
  newest draft). It builds the image on Linux, adds it and `install.sh` to that draft, and publishes it
  (or leaves it a draft). The app must be built for the same version as the draft's tag.

To try a build before it's published, put its `kirki-vm.json` somewhere and set it in kirki's settings
file (`imageManifestURL` in `~/Library/Application Support/kirki/settings.json`), or start the app with
`KIRKI_MANIFEST_URL=file:///path/to/kirki-vm.json`. `install.sh` takes `KIRKI_APP_ZIP=FILE`.

### Signing and notarizing

Without a certificate, the app is signed ad hoc. That's enough for `install.sh`, which downloads with
curl (macOS doesn't mark the app as downloaded, so Gatekeeper doesn't stop it). To make the app open
without a warning when downloaded with a browser too, add these repository secrets and the Release
workflow signs it with the hardened runtime and notarizes it:

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE_P12` | a "Developer ID Application" certificate and key, exported as .p12, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12's password |
| `MACOS_SIGN_IDENTITY` | the certificate's name, e.g. `Developer ID Application: Name (TEAMID)` |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | an Apple ID, its team, and an app-specific password |

## Versions and releases

As kirki: `YY.MM.DD`, or `YY.MM.DD.N` for later releases the same day; tags are the bare version. A
release has `install.sh`, `kirki-app.zip` (+ `.sha256`), `kirki-vm.json` and the image part(s). The
install command always uses the latest release, and installed VMs apply it after their next
`pacman -Syu`. Test with "Just build" or a draft first.

## Testing

- `swift test --package-path app`: downloading (resume, checksums), xz decoding with macOS's own
  decoder (several blocks, split parts), sparse writing, the whole installer from a local manifest, the
  protocol, settings. Runs in the App workflow on every change.
- `tests/install-test.sh`: `install.sh` against mocks of `sysadminctl`, `dscl`, `sudo`, `curl` and
  friends, with its paths in a temporary folder. Runs in the App workflow.
- `image/test-boot.py`: the built image in QEMU (EFI, virtio disk, GPU, sound, console ports): kirk-vm-agent
  says ready, the disk grows to 40 GB, the DKMS sound driver finds the sound card, the first-start setup
  opens (screenshots), and "shutdown" ends with `power poweroff`. Runs in the Release workflow.
- The guest scripts were also run against mocks: `kirk-vm-agent` over a pseudo-terminal pair,
  `kirk-vm-grow` on a loop device, the DKMS package with Ubuntu's kernel headers.

**Not confirmed on a real Mac yet:** everything that needs the Virtualization framework itself and a
Mac's login window: the app running kirki, the kirki login (sysadminctl, the launch agent, the Apple
events to loginwindow, the welcome screens being skipped), display resizing, sound and Rosetta in the
framework. The QEMU test stands in for the framework as closely as it can.
