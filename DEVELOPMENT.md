# kirki for Mac: development

kirki for Mac is kirki's desktop as a container image, shown in a web browser, plus the Terminal
commands that run it on a Mac with Docker Desktop.

- **The image** (`webtop/`): linuxserver.io's [webtop](https://github.com/linuxserver/docker-webtop)
  `arch-kde` image (Arch Linux, KDE Plasma on Wayland, streamed to the browser by
  [Selkies](https://github.com/selkies-project/selkies)), with kirki's desktop on top. Published as
  `ghcr.io/goseahawk/kirki` for arm64 and amd64.
- **install.sh**: checks for Docker Desktop (installs it with Homebrew, or points to docker.com),
  starts it, pulls the image, and runs the container, then opens `http://localhost:3010`.
- **uninstall.sh**: removes the container, its volume and image, and the earlier VM version's pieces.

The earlier kirki for Mac (an app running kirki in Apple's Virtualization framework, with a "kirki"
login) is in the git history and release 26.11.26.

## Layout

| Path | What |
|---|---|
| `webtop/Dockerfile` | the image: webtop's `arch-kde`, kirki's files, `TITLE=kirki` |
| `webtop/setup.sh` | runs while the image is built: kirki's apps (pacman) and kirki's files |
| `webtop/kirki.ref` | the kirki commit the image takes its files from |
| `webtop/root/` | files of the image's own: the web page's icon, `kirk-about-model` |
| `webtop/test-image.sh` | starts a built image and checks it (the Release workflow runs it) |
| `install.sh`, `uninstall.sh` | what people run in Terminal (POSIX sh, answers from /dev/tty) |
| `tests/install-test.sh` | tests both scripts on Linux against mocks of docker, open, curl... |

## What comes from kirki

kirki is the source of the desktop. `webtop/setup.sh` installs everything in kirki's
`overlay/installed` except what's for a real computer: booting (GRUB, Plymouth, SDDM), the first-start
setup (Calamares), kirk-update and automatic updates (a new image replaces the system), snapshots, the
firewall, zram and the touchpad. Kept: the Global Theme, colours, Plasma Style, icons, wallpaper,
splash, DM Sans, Konsole and fastfetch, the About page and the login scripts (`kirk-set-theme`, ...).
`/etc/kirk-release` says `INSTALL_MODE=webtop`; `kirk-about-model` says "kirki in a container".

Desktop and branding changes belong in kirki; bring them here by moving `webtop/kirki.ref`.

## How it runs

    docker run -d --name kirki --restart unless-stopped --shm-size=1gb \
      -e PUID=1000 -e PGID=1000 -e TZ=<the Mac's> -e TITLE=kirki \
      -p 127.0.0.1:3010:3000 -v kirki-home:/config ghcr.io/goseahawk/kirki:latest

- **Port 3000** is webtop's plain-HTTP port. Browsers treat `http://localhost` as a secure context,
  which Selkies needs (WebCodecs), so there's no self-signed certificate warning as with port 3001.
- **127.0.0.1 only**: the page has no password, and its terminal has passwordless sudo.
- **`/config`** is the account's home (user `abc`), in the named volume `kirki-home`: updates replace the
  container and keep it.
- Docker Desktop runs Linux in a VM of its own with no GPU, so Plasma is drawn by the CPU (webtop's
  `startwm_wayland.sh` turns KWin's compositing off on a new account) and the stream is encoded by the CPU.

## Releases

Actions → **Release** → Run workflow. "Just build" builds and tests both images; "Publish release"
also pushes them (`:VERSION-arm64`, `:VERSION-amd64`, then `:VERSION` and `:latest` for both) and makes
the GitHub release with `install.sh` and `uninstall.sh`. A published release reaches everyone who runs
the install command, and everyone who runs it again to update.

**Once, after the first release:** GHCR makes new packages private. Make it public:
github.com/goseahawk?tab=packages → kirki → Package settings → Change visibility → Public. The
workflow warns while it isn't.

Building by hand (Docker, any machine; `--platform linux/arm64` or `amd64`):

    git clone https://github.com/goseahawk/kirki kirki && git -C kirki checkout "$(cat webtop/kirki.ref)"
    docker build -f webtop/Dockerfile --build-arg KIRK_VERSION=26.11.27 -t kirki .
    KIRKI_IMAGE=kirki sh install.sh        # on a Mac; or: webtop/test-image.sh kirki results/

## Testing

- `bash tests/install-test.sh`: install, update, Docker Desktop not running or missing, a failed
  download, ports, uninstall (with and without the earlier VM version), the truncation guard.
- The Release workflow's `webtop/test-image.sh`: the container starts, Plasma runs, the page answers,
  os-release, the default Global Theme and DM Sans are kirki's; screenshots from Plasma (spectacle) and
  from Chromium opening the page (Playwright), with small base64 copies in the job log.
- Not confirmed on a Mac yet: Docker Desktop on macOS, Safari with Selkies, "Add to Dock", sound and
  the clipboard through the browser.
