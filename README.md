# kirki for Mac

**kirki for Mac puts the [kirki](https://github.com/goseahawk/kirki) desktop on any Mac with Apple
silicon, as easily as an app.** It adds a **kirki** login to your Mac: choose it in the login window and
you're in kirki, full screen, as if you'd started another system. Shut kirki down and you're back at
the login window, where you can choose macOS.

It feels like dual booting, but nothing about your disk or your Mac's startup changes: kirki runs on
top of macOS, in Apple's own virtualization, at nearly the Mac's full speed. That's also why your Mac's
hardware just works in kirki: Wi-Fi, sound, Bluetooth headphones and keyboards, the trackpad, sleep and
the battery are all handled by macOS.

- **Every Apple silicon Mac.** M1, M2, M3, M4 and later. (kirki on a Mac's own hardware needs M1 or M2.)
- **Easy to install.** One command in Terminal. Your own account and files aren't touched.
- **The real kirki.** The same KDE Plasma desktop, look, apps and weekly self-updates as kirki, on Arch
  Linux ARM.
- **Switch in seconds.** With Fast User Switching, macOS and kirki can both stay open.

kirki for Mac is an independent project. It is not affiliated with or endorsed by Apple, Arch Linux,
Arch Linux ARM or KDE.

## What you need

- A Mac with **Apple silicon** (M1 or later). Intel Macs can't run it.
- **macOS 14 Sonoma or later**, and an administrator account (the one you use, usually).
- About **15 GB of free space** to start with. kirki's disk grows as you add things to it, up to the
  size set in its settings (64 GB to begin with).
- An **internet connection**: kirki downloads itself (about 2 GB) the first time.

## 1. Install

Open **Terminal** (Applications → Utilities), paste this and press Return:

    curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/install.sh | sh

It asks for your Mac password, then for a password for the new **kirki** login (you type it in the login
window, like any account's). That's all it asks.

## 2. Start kirki

1. Choose  → **Log Out**.
2. In the login window, choose **kirki** and enter its password.
3. The first time, kirki downloads itself, then asks for your language, keyboard, time zone and an
   account for inside kirki (with its own password, for installing apps and making changes). The
   keyboard and time zone are suggested from the Mac's.

After that, choosing kirki in the login window takes you straight to your kirki desktop.

If your Mac uses **FileVault**, kirki is also offered when the Mac starts, next to your own account:
choose it there and the Mac starts straight into kirki.

## 3. Using kirki on a Mac

- **Shutting down kirki** (from kirki's own menu) brings you back to the login window. Restarting
  kirki restarts just kirki.
- **The Mac's menu bar** slides down when you move the pointer to the very top of the screen: Wi-Fi,
  Bluetooth, sound, battery, Control Center and the kirki menu are there. (You can hide it for good in
  kirki's settings.)
- **Wi-Fi and Bluetooth** are chosen in the Mac's menu bar. Inside kirki, the network shows as a wired
  connection, and it's always connected when your Mac is.
- **Keys:** ⌘ (Command) is kirki's Meta key: tap it to open the app menu. Copy and paste are Control+C
  and Control+V in most kirki apps, as on any PC.
- **Sleep:** close the lid or let the Mac sleep as usual. kirki pauses with it and carries on when the
  Mac wakes. kirki's screen is locked with your Mac's password (or Touch ID).
- **Switching to macOS without shutting down:** turn on Fast User Switching (System Settings → Control
  Center → Fast User Switching), then choose your account from its menu. kirki pauses while you're
  away and carries on when you're back.
- **Apps for Intel and AMD PCs** run too, with Apple's Rosetta: install them from Flathub with
  `flatpak install --arch=x86_64 flathub NAME`.

## Settings

Move the pointer to the top of the screen and choose **kirki → Settings**, or press
**Control-Option-Command-K**.

- **Memory, processors and disk** kirki gets from your Mac. The disk can grow but not shrink, and only
  takes the space kirki actually uses.
- **Full Retina resolution**: sharp text, as in macOS. Turn it off for a faster desktop.
- **Microphone** and **Intel and AMD programs (Rosetta)**.
- **When kirki shuts down:** log out (back to the login window) or shut down the Mac.
- **Erase kirki**: starts over with a fresh kirki.

Most settings take effect the next time kirki starts.

## kirki in a window

You can also open **kirki** from the Applications folder in your own account: kirki then runs in a
window, next to your Mac apps. That's a separate kirki, with its own files and its own download.

## Updates

**kirki updates itself** once a week, the same way kirki always does (see kirki's
[UPDATING.md](https://github.com/goseahawk/kirki/blob/main/UPDATING.md)). To update the **app**, run the
install command again.

## Troubleshooting

**The install command says GitHub can't be reached.** Check your internet connection. Some networks
block GitHub; try another network.

**kirki's download stopped.** It carries on where it left off: choose **Try Again**, or log out and in
again.

**The kirki login shows the Mac desktop instead of kirki.** kirki was quit. Open kirki from the
Applications folder (it starts full screen again), or log out and in again.

**Something's wrong inside kirki.** Restart kirki (from kirki's menu, or kirki → Restart kirki in the
Mac's menu bar). If kirki won't start at all, kirki → Settings → **Erase kirki** sets it up fresh
(everything in it is deleted).

**I want to see what's happening.** Help → **Show Log Files** in the Mac's menu bar: `kirki.log` is the
app, `console.log` is kirki's own start-up messages.

**I want to remove kirki.** In Terminal, in your own account:

    curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/install.sh | KIRKI_UNINSTALL=yes sh

That removes the kirki login (with everything in kirki) and the app.

## Building it yourself

See [DEVELOPMENT.md](DEVELOPMENT.md): the app builds on a Mac with Xcode (`app/build-app.sh`), kirki's
disk image on ARM Linux (`image/build.sh`), and the **Release** workflow builds both on GitHub.

## License

The code is under the MIT License (see `LICENSE`). The kirki logo and the images made from it are
**not** covered by it; they may not be reused without permission. DM Sans is under the SIL Open Font
License. kirki's desktop comes from [kirki](https://github.com/goseahawk/kirki) (MIT License). Apple,
Mac, macOS and Rosetta are trademarks of Apple Inc.; Arch Linux and Arch Linux ARM are trademarks of
their respective owners.
