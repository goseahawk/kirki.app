#!/usr/bin/env bash
# Updates kirki in the kirki Mac app (the virtual machine) to this version of the project, without
# reinstalling. kirk-update runs it automatically for each new release of github.com/goseahawk/kirki.app
# (REPO in /etc/kirk-update.conf). By hand, from the project folder, in kirki:
#     sudo ./apply-to-installed.sh
#
# It brings kirki's desktop at the version this release was made with (image/kirki.ref), and the parts
# that connect it to the Mac app (image/vm-overlay), exactly as a new image has them: branding, boot
# splash, boot menu, login screen, About page, update hooks, firewall, the sound driver. Your files
# and settings stay; /etc/kirk-update.conf is only installed if it's missing. Safe to run again.
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo KIRK_VERSION="${KIRK_VERSION:-}" KIRK_FORCE="${KIRK_FORCE:-}" KIRKI_SRC="${KIRKI_SRC:-}" "$0" "$@"

VERSION=${KIRK_VERSION:-$(date +%y.%m.%d)}
[[ $VERSION =~ ^[0-9]{2}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] || { echo "Bad version '$VERSION': use YY.MM.DD or YY.MM.DD.N"; exit 1; }
BRAND="kirki $VERSION"
HERE=$(cd "$(dirname "$0")" && pwd)
[[ -f $HERE/image/lib.sh ]] || { echo "Run this from inside the project folder."; exit 1; }
# shellcheck source=image/lib.sh
. "$HERE/image/lib.sh"

if ! grep -qx 'INSTALL_MODE=vm' /etc/kirk-release 2>/dev/null && [[ ${KIRK_FORCE:-} != yes ]]; then
  echo "This updates kirki in the kirki Mac app (a virtual machine), and this isn't it, so nothing was"
  echo "changed. kirki on a Mac's own hardware updates from github.com/goseahawk/kirki; set REPO in"
  echo "/etc/kirk-update.conf to that. (KIRK_FORCE=yes overrides this check.)"
  exit 1
fi

# ---------------------------------------------------------------------------------------- kirki
REF=$(tr -d '[:space:]' < "$HERE/image/kirki.ref")
[[ $REF =~ ^[0-9a-f]{40}$ ]] || { echo "image/kirki.ref must hold a full kirki commit hash."; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [[ -n ${KIRKI_SRC:-} ]]; then
  K=$KIRKI_SRC
else
  echo "== kirki ${REF:0:7} =="
  mkdir -p "$work/kirki"
  curl -fsSL --max-time 300 "https://github.com/goseahawk/kirki/archive/$REF.tar.gz" \
    | tar -xz -C "$work/kirki" --strip-components=1 --no-same-owner
  K=$work/kirki
fi
[[ -d $K/overlay/installed && -f $K/image/setup.sh ]] || { echo "That kirki download is incomplete; nothing was changed."; exit 1; }

# ---------------------------------------------------------------------------------------- packages
echo "== packages =="
# The ones kirki adds to installed systems (its apply-to-installed.sh), and the VM's own. Packages you
# removed yourself from kirki's full list aren't brought back.
PKGS=()
if grep -q '^PKGS=(' "$K/apply-to-installed.sh"; then
  eval "$(awk '/^PKGS=\(/ {on=1} on {print} on && /\)/ {exit}' "$K/apply-to-installed.sh")"
fi
pacman -S --needed --noconfirm "${PKGS[@]}" "${KV_VM_PKGS[@]}"
for p in fastfetch ufw plasma-firewall; do
  pacman -S --needed --noconfirm "$p" || echo "($p isn't available; skipped)"
done

# ------------------------------------------------------------------------------------------- files
echo "== kirki files =="
# Theme folders belong to kirki entirely: replace them, so files a newer version dropped go too.
rm -rf /usr/share/plymouth/themes/kirkus /boot/grub/themes/kirkus /usr/share/sddm/themes/kirkus \
       /usr/share/plasma/look-and-feel/org.kirkus.splash /usr/share/plasma/look-and-feel/org.kirkus.light \
       /usr/share/plasma/desktoptheme/kirkus /usr/share/icons/kirkus /usr/share/icons/kirkus-light \
       /usr/share/wallpapers/kirkus /usr/share/kirkus /usr/share/calamares-kirkus
kv_install_tree "$K/overlay/installed" etc/kirk-update.conf
kv_derive_files "$K"
kv_install_tree "$HERE/image/vm-overlay" etc/kirk-update.conf
kv_kernel_link
systemctl daemon-reload
udevadm control --reload 2>/dev/null || true

kv_set_release_key VERSION "$VERSION"
kv_set_release_key KIRKI_REF "$REF"
/usr/local/bin/kirk-branding

# ---------------------------------------------------------------------------------------- services
kv_enable_services
systemctl restart kirk-vm-agent.service 2>/dev/null || true
command -v ufw >/dev/null && { systemctl start kirk-firewall-setup.service || true; }
systemctl try-restart grub-btrfsd.service 2>/dev/null || true
# First-start setup only ever runs on a fresh install; once there's an account, this system is set up.
if awk -F: '$3 >= 1000 && $3 < 60000 {f=1} END {exit !f}' /etc/passwd; then
  mkdir -p /var/lib/kirkus
  [[ -e /var/lib/kirkus/setup-done ]] || touch /var/lib/kirkus/setup-done
  systemctl disable kirk-setup.service 2>/dev/null || true
fi

# ----------------------------------------------------------------------------------- desktop & apps
echo "== desktop =="
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
  || echo "Could not add Flathub (offline?). Run this again later to add it."
/usr/local/bin/kirk-install-fonts || true
/usr/local/bin/kirk-login-theme kirkus
for d in hicolor kirkus kirkus-light; do gtk-update-icon-cache -q -t -f /usr/share/icons/$d 2>/dev/null || true; done
if [[ -n ${SUDO_USER:-} ]] && command -v kwriteconfig6 >/dev/null; then
  sudo -H -u "$SUDO_USER" kwriteconfig6 --file ksplashrc --group KSplash --key Engine KSplashQML || true
  sudo -H -u "$SUDO_USER" kwriteconfig6 --file ksplashrc --group KSplash --key Theme org.kirkus.splash || true
fi

# ------------------------------------------------------------------------------------------ sound
echo "== sound =="
kv_build_sound || echo "WARNING: the virtio sound driver didn't build; kirki has no sound until it does."

# ------------------------------------------------------------------------------------- boot splash
echo "== boot splash =="
# Rebuilding the boot image on a system that starts fine today: snapshot first, keep a copy of
# mkinitcpio.conf, and put it back if the rebuild fails.
if [[ $(findmnt -no FSTYPE /) == btrfs && -f /etc/timeshift/timeshift.json ]] && command -v timeshift >/dev/null; then
  timeshift --create --comments "kirki $VERSION: before update" --scripted >/dev/null 2>&1 \
    && echo "Timeshift snapshot taken." || echo "(snapshot skipped)"
fi
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.kirki-backup
kv_initramfs_config
plymouth-set-default-theme kirkus
SPLASH_OK=yes
if ! mkinitcpio -P; then
  SPLASH_OK=no
  echo "WARNING: rebuilding the boot image failed. Restoring the previous setup..."
  cp /etc/mkinitcpio.conf.kirki-backup /etc/mkinitcpio.conf
  mkinitcpio -P && echo "Restored. kirki starts exactly as before." \
    || echo "!! Restore also failed. Do NOT restart; paste this output to get help."
fi

# -------------------------------------------------------------------------------------------- GRUB
echo "== GRUB menu =="
kv_grub_defaults "$BRAND"
[[ $SPLASH_OK == yes ]] || sed -i -E '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/ splash//' /etc/default/grub
# grub-mkconfig only replaces grub.cfg if the new one passes its syntax check, so a failure here
# leaves the current, working boot menu in place.
grub-mkconfig -o /boot/grub/grub.cfg \
  || echo "WARNING: grub-mkconfig failed; the existing boot menu was left as it was and still works."

echo
echo "kirki $VERSION (Mac app) is installed. Restart kirki to see everything."
