#!/bin/bash
# Runs once while the kirki container image is built (see Dockerfile): kirki's apps and desktop on
# top of webtop's Arch KDE. Arguments: the version (YY.MM.DD). kirki's own files are in
# /tmp/kirki-overlay (kirki's overlay/installed).
#
# Of kirki's files this takes the desktop: theme, colours, wallpaper, fonts, icons, Konsole and
# fastfetch, the About page and the login scripts that put accounts on the kirki theme. It leaves out
# what's for a real computer, which a container doesn't have or webtop does itself: booting (GRUB,
# Plymouth, the login screen), the first-start setup, updates (a new image replaces the container's
# system; your files are kept), snapshots, the firewall, zram and the touchpad.
set -euo pipefail
VERSION=${1:-dev}
SRC=/tmp/kirki-overlay
say() { printf '\n==== %s\n' "$*"; }

say "Packages"
# kirki's apps that webtop's Arch KDE doesn't have (it has Plasma, Dolphin, Konsole, Kate, Discover)
PKGS=(
  systemsettings kinfocenter kscreen plasma-pa kde-gtk-config breeze breeze-gtk
  ark gwenview okular spectacle kdialog
  firefox noto-fonts noto-fonts-emoji fastfetch fontconfig
)
# spectacle's text recognition wants a language: English, rather than pacman's first choice
PKGS=(tesseract-data-eng "${PKGS[@]}")
# Not a full upgrade: webtop's own KWin is built against its exact Qt, and its web server's modules
# against its exact nginx, so those stay as webtop has them (a newer Qt crashed Plasma). If a package
# here ever needs them newer, the build stops (below) rather than making an image that doesn't start.
HELD='qt6-*,kwin,nginx*'
held_versions() { pacman -Q | grep -E '^(qt6-[^ ]+|kwin|nginx[^ ]*) ' | sort; }
before=$(held_versions)
pacman -Sy
# One at a time: a package that needs a newer Qt (or a Qt part only the newer Qt has, as
# kinfocenter and spectacle can) is left out with a warning, and the rest still go in.
MISSING=()
for p in "${PKGS[@]}"; do
  pacman -S --noconfirm --needed --ignore "$HELD" "$p" || MISSING+=("$p")
done
((${#MISSING[@]} == 0)) || echo "WARNING: left out (they need a newer Qt than webtop's): ${MISSING[*]}"
after=$(held_versions)
if [[ $before != "$after" ]]; then
  echo "ERROR: installing kirki's apps changed packages webtop's desktop depends on:"
  diff <(echo "$before") <(echo "$after") || true
  exit 1
fi

say "kirki's files"
leave_out() {
  case $1 in
    boot/*|etc/X11/*|etc/grub.d/*|etc/sddm.conf.d/*|etc/sysctl.d/*|etc/systemd/*|var/*) return 0 ;;
    etc/kirk-update.conf|etc/pacman.d/hooks/00-kirk-snapshot.hook|etc/pacman.d/hooks/zz-kirk-update.hook) return 0 ;;
    etc/xdg/autostart/kirk-touchpad.desktop) return 0 ;;
    usr/local/bin/kirk-auto-update*|usr/local/bin/kirk-update|usr/local/bin/kirk-setup*) return 0 ;;
    usr/local/bin/kirk-firewall-setup|usr/local/bin/kirk-first-snapshot|usr/local/bin/kirk-pre-snapshot) return 0 ;;
    usr/local/bin/kirk-grub-theme-font|usr/local/bin/kirk-login-*|usr/local/bin/kirk-touchpad-*) return 0 ;;
    usr/local/bin/kirk-about-model) return 0 ;;     # the container's own is in webtop/root
    usr/share/applications/kirkus-*|usr/share/plasma/systemsettings/*) return 0 ;;   # updates, touchpad
    usr/share/calamares-kirkus/*|usr/share/plymouth/*|usr/share/sddm/*|usr/share/polkit-1/*) return 0 ;;
  esac
  return 1
}
n=0
while IFS= read -r -d '' rel; do
  leave_out "$rel" && continue
  case $rel in usr/local/bin/*) mode=755 ;; *) mode=644 ;; esac
  install -D -o root -g root -m "$mode" "$SRC/$rel" "/$rel"
  n=$((n + 1))
done < <(cd "$SRC" && find . -type f -printf '%P\0')
echo "$n files"

cat > /etc/kirk-release <<EOF2
VERSION=$VERSION
INSTALL_DATE=$(date -I)
INSTALL_MODE=webtop
INSTALL_ENGINE=container
SOURCE=release $VERSION
EOF2
/usr/local/bin/kirk-branding
/usr/local/bin/kirk-install-fonts
for d in hicolor kirkus kirkus-light; do
  if [[ -d /usr/share/icons/$d ]]; then gtk-update-icon-cache -q -t -f "/usr/share/icons/$d" 2>/dev/null || true; fi
done
grep -E '^(NAME|PRETTY_NAME)=' /usr/lib/os-release

say "Tidying up"
rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/* /tmp/* /root/.cache /config/.cache
echo "kirki $VERSION is set up in the image."
