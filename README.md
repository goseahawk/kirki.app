# kirki for Mac

**kirki for Mac puts the [kirki](https://github.com/goseahawk/kirki) desktop on your Mac, in a web
browser tab.** One command sets it up; then kirki's KDE Plasma desktop, with its look, apps and
settings, is at **http://localhost:3010** in Safari, Chrome or Firefox, whenever you want it.

It runs in a container with Docker Desktop, so nothing about your Mac's disk, startup or accounts
changes, and it works on **Apple silicon and Intel Macs** alike. Your files in kirki are kept from one
session to the next, and updating is the same command again.

kirki for Mac is an independent project, built on [linuxserver.io's webtop](https://github.com/linuxserver/docker-webtop).
It is not affiliated with or endorsed by Apple, Docker, Arch Linux, KDE or linuxserver.io.

## What you need

- A Mac that runs **Docker Desktop** (recent macOS; Apple silicon or Intel). The install command sets
  Docker Desktop up if it isn't there (with Homebrew, or it shows you where to download it).
- About **6 GB of free space** for kirki, plus what you keep in it.
- An **internet connection** to download kirki (about 2 GB) the first time.

## 1. Install

Open **Terminal** (Applications → Utilities), paste this and press Return:

    curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/install.sh | sh

When it's done, kirki opens in your web browser.

## 2. Use kirki

- **Open it:** go to **http://localhost:3010**. Bookmark it, or in Safari choose File → **Add to Dock**,
  and kirki opens like an app.
- **Full screen:** use the browser's full screen (View → Enter Full Screen, or ⌃⌘F). The desktop fits
  whatever size the window is.
- **Copy and paste, files, sound:** the page's own menu (at the edge of the screen) has the clipboard,
  file upload and download, sound and the stream's settings.
- **After restarting your Mac,** kirki is there again as soon as Docker Desktop is running. To have it
  start on its own, turn on "Start Docker Desktop when you sign in" in Docker Desktop's settings.

Only this Mac can open kirki: other computers on your network can't reach it.

## Updating

Run the install command again. kirki's apps and system are replaced with the newest version; your
files and settings in kirki are kept.

## If something isn't right

**The page doesn't load.** Check that Docker Desktop is running (its whale icon is in the menu bar),
then reload. If it still doesn't load, run the install command again.

**Port 3010 is taken by something else.** Install with another port:

    curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/install.sh | KIRKI_PORT=3011 sh

**I want to start from scratch, or remove kirki.** In Terminal:

    curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/uninstall.sh | sh

That removes kirki and everything in it (it also removes the earlier, virtual machine version of kirki
for Mac, if it's there). Docker Desktop stays. Run the install command again to start fresh.

## Building it yourself

See [DEVELOPMENT.md](DEVELOPMENT.md).

## License

MIT. See [LICENSE](LICENSE). kirki, KDE Plasma, Arch Linux and webtop are under their own licenses.
