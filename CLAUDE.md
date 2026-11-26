# kirki for Mac: notes for Claude

This repo (github.com/goseahawk/kirki.app) is kirki for Mac: a macOS app that runs kirki
(github.com/goseahawk/kirki, Arch Linux ARM with kirki's KDE Plasma desktop) in a virtual machine with
Apple's Virtualization framework, and a "kirki login" (a macOS account whose session is kirki, full
screen) that makes it feel like dual booting while macOS handles the hardware. How it works inside is
in `DEVELOPMENT.md`; read that before changing anything.

- kirki is the source of the desktop. The image takes kirki's packages, `overlay/installed` and scripts
  at the commit in `image/kirki.ref`; only what's specific to a VM lives here (`image/lib.sh`,
  `image/setup.sh`, `image/vm-overlay/`). Desktop and branding changes belong in kirki; bring them here
  by moving `image/kirki.ref`.
- The name shown to people is **kirki** everywhere (lowercase). Internal IDs keep kirki's and kirkus's
  names (`kirk-*` commands, `/var/lib/kirkus`, `org.kirkus.*` themes); the VM's own pieces are
  `kirk-vm-*`. The app's bundle ID is `io.github.goseahawk.kirki`.

## Working with the owner

- The owner usually wants each change committed and pushed, with a clear commit message. Commits use the
  owner's GitHub noreply address. Never put the owner's personal email address in the repo, commits or
  anything sent to an outside service.
- For appearance and branding changes, keep commit messages vague, e.g. "Update branding".
- Keep replies short and plain: what changed, anything to watch out for, and what the owner needs to do
  (usually: run the Release workflow, then run the install command on the Mac).
- The owner's own kirkus computer is a 2015 MacBook Air (Intel), which can't run this.

## Docs

- `README.md` is for **users**: plain steps, no internals. License stays its last section.
- `DEVELOPMENT.md` is for maintainers: internals, building, releases, testing, what isn't confirmed.

## Rules that matter

- **Versions** are `YY.MM.DD` or `YY.MM.DD.N`; release tags are the bare version. A published release
  reaches every new install (install.sh follows "latest") and every installed VM (kirk-update runs its
  `apply-to-installed.sh`). Test with "Just build" or a draft first.
- A release needs `install.sh`, `kirki-app.zip` + `.sha256`, `kirki-vm.json` and the image part(s).
  Each file must stay under 2 GiB (`image/build.sh` splits the image).
- The app targets macOS 14+ and Apple silicon only. Keep `swift test` passing; the App workflow builds
  and tests on every push. There's no Mac here: the CI runner is the compiler.
- Swift: `AppSettings`, not `Settings` (it clashes with SwiftUI's). Virtualization callbacks go through
  `onMain`, not `MainActor.assumeIsolated`, unless the queue is guaranteed main.
- `kirk-vm-agent`'s protocol is shared by the app (`GuestProtocol.swift`) and the image; change both
  together, and keep old messages working (installed VMs update later than the app, or the other way).
- The image's root UUID (`3ebc7cc5-...`) and EFI ID (`4B1D-2E5B`) are fixed: GRUB's embedded config,
  fstab and Timeshift use them.
- Never delete or rewrite people's data from `apply-to-installed.sh`; `/etc/kirk-update.conf` is only
  installed when missing.
- `install.sh` must stay POSIX sh, with `main` called on the last line (truncation guard), and read
  answers from /dev/tty (it arrives through a pipe).

## Testing

There's no Mac here, and Arch Linux ARM's servers are blocked from this environment, so:

- App: push and read the App workflow's logs (it runs `swift test` and `app/build-app.sh` on macOS).
- Image: run the Release workflow with "Just build"; its boot test starts the image in QEMU and saves
  screenshots and logs (`boot-test` artifact).
- Scripts: `shellcheck`, `bash -n`; `tests/install-test.sh`; guest scripts against mocks (see
  DEVELOPMENT.md → Testing). `kirk-vm-grow` can be tried on a loop device (`partx -a` makes the
  partitions here).
- Say clearly what's only been tested that way: the Virtualization framework and the kirki login
  haven't been tried on a real Mac yet.
