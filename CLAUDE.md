# kirki for Mac: notes for Claude

This repo (github.com/goseahawk/kirki.app) is kirki for Mac: kirki's desktop (github.com/goseahawk/kirki,
KDE Plasma) as a container image built on linuxserver.io's webtop (`arch-kde`), shown in a web browser
tab, with Terminal commands that run it on a Mac with Docker Desktop. How it works is in
`DEVELOPMENT.md`; read that before changing anything.

- kirki is the source of the desktop. The image takes kirki's `overlay/installed` at the commit in
  `webtop/kirki.ref`, minus what's for real hardware (`webtop/setup.sh` lists what's left out). Desktop
  and branding changes belong in kirki; bring them here by moving `webtop/kirki.ref`.
- The name shown to people is **kirki** everywhere (lowercase). Internal IDs keep kirki's and kirkus's
  names (`kirk-*` commands, `org.kirkus.*` themes). The image is `ghcr.io/goseahawk/kirki`, the
  container `kirki`, its volume `kirki-home`.
- The earlier version (a macOS app with Apple's Virtualization framework and a "kirki" login) is in
  git history and release 26.11.26; uninstall.sh still removes its pieces.

## Working with the owner

- The owner usually wants each change committed and pushed, with a clear commit message. Commits use the
  owner's GitHub noreply address. Never put the owner's personal email address in the repo, commits or
  anything sent to an outside service.
- For appearance and branding changes, keep commit messages vague, e.g. "Update branding".
- Keep replies short and plain: what changed, anything to watch out for, and what the owner needs to do
  (usually: run the Release workflow, then run the install command on the Mac).
- The owner's own kirkus computer is a 2015 MacBook Air (Intel); the amd64 image runs there too.

## Docs

- `README.md` is for **users**: plain steps, no internals. License stays its last section.
- `DEVELOPMENT.md` is for maintainers: internals, building, releases, testing, what isn't confirmed.

## Rules that matter

- **Versions** are `YY.MM.DD` or `YY.MM.DD.N`; release tags are the bare version. A published release
  (and the image's `latest` tag) reaches everyone who runs install.sh. Test with "Just build" first.
- A release needs `install.sh` and `uninstall.sh`, and the image pushed for arm64 and amd64.
- The container listens on 127.0.0.1 only: the page has no password and its terminal has sudo.
- Never delete people's data except in uninstall.sh after they type REMOVE; updates keep `kirki-home`.
- `install.sh` and `uninstall.sh` must stay POSIX sh, with `main` called on the last line (truncation
  guard), and read answers from /dev/tty (they arrive through a pipe).

## Testing

There's no Mac here, and the container registries and Arch's mirrors are blocked from this
environment, so:

- Scripts: `shellcheck`, `sh -n`; `bash tests/install-test.sh` (mocks of docker, open, curl...).
- Image: run the Release workflow with "Just build"; `webtop/test-image.sh` checks the container and
  prints small base64 JPEG screenshots into the job log (the artifact host is blocked from here).
- Say clearly what's only been tested that way: Docker Desktop on a real Mac hasn't been tried yet.
