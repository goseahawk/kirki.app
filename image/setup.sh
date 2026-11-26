#!/bin/bash
# Turns an Arch Linux ARM root file system into kirki for the Mac app: the kirki desktop, run by the
# kirki app in a virtual machine on macOS. Runs INSIDE the image's chroot, started by image/build.sh,
# which sets:
#   VERSION     the version, YY.MM.DD
#   ROOT_UUID   the root file system's UUID (fixed: each VM has its own disk, so they never meet)
#   EFI_UUID    the EFI partition's FAT volume ID, as XXXX-XXXX
#   KIRKI_REF   the kirki commit the desktop comes from
# and copies kirki to /kirk-src/kirki and this project's image/ folder to /kirk-src/vm/image (both
# left out of the finished image).
#
# It follows kirki's own image/setup.sh step by step. What differs is what only applies to a Mac's own
# hardware: no Asahi packages, Arch Linux ARM's generic kernel (it has the virtio drivers a VM uses),
# GRUB as an ordinary EFI program, and the pieces that connect kirki to the Mac app (image/vm-overlay).
set -euo pipefail
: "${VERSION:?}" "${ROOT_UUID:?}" "${EFI_UUID:?}" "${KIRKI_REF:?}"
K=/kirk-src/kirki
V=/kirk-src/vm
BRAND="kirki $VERSION"
say() { echo; echo "### $*"; }
# shellcheck source=image/lib.sh
. "$V/image/lib.sh"

# ------------------------------------------------------------------------------------- pacman
say "pacman: Arch Linux ARM, and Asahi ALARM's repository last (for the setup window)"
sed -i -e 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
# pacman downloads as the 'alpm' user, which has to exist first
systemd-sysusers
pacman-key --init
pacman-key --populate archlinuxarm
kv_asahi_repo "$K"

# ------------------------------------------------------------------------------------- base
say "Base system"
mkdir -p /boot/efi
pacman -Syu --noconfirm
# Firmware for real ARM boards; a virtual machine has no use for it.
mapfile -t extra < <(pacman -Qq | grep -E '^(linux-firmware.*|firmware-raspberrypi|raspberrypi-bootloader.*)$' || true)
if ((${#extra[@]})); then pacman -Rdd --noconfirm "${extra[@]}"; fi

kv_packages "$K"
say "Installing kirki packages (${#KV_PKGS[@]})"
pacman -S --needed --noconfirm "${KV_PKGS[@]}"
MISSING=()
for p in "${KV_OPTIONAL[@]}"; do
  pacman -S --needed --noconfirm "$p" || MISSING+=("$p")
done
((${#MISSING[@]} == 0)) || echo "WARNING: not available, left out: ${MISSING[*]}"
kv_kernel_link

# ------------------------------------------------------------------------------------- GRUB
say "GRUB (started by the virtual machine's EFI firmware from the EFI partition)"
# As in kirki: a GRUB image that finds the root file system by UUID and reads everything else from
# /@/boot/grub. build.sh copies it to EFI/BOOT/BOOTAA64.EFI, where EFI firmware looks on a disk with
# no boot entries (the kirki app gives every VM fresh EFI variables).
cat > /tmp/grub-core.cfg <<EOF
search.fs_uuid $ROOT_UUID root
set prefix=(\$root)'/@/boot/grub'
EOF
sed -i '/efi_uga/d' /etc/grub.d/00_header           # no such module on arm64
rm -f /etc/grub.d/30_uefi-firmware                   # no firmware settings screen to go to
mkdir -p /boot/grub/fonts /boot/grub/locale
touch /boot/grub/device.map
dd if=/dev/zero of=/boot/grub/grubenv bs=1024 count=1 status=none
rm -rf /boot/grub/arm64-efi
cp -r /usr/lib/grub/arm64-efi /boot/grub/
rm -f /boot/grub/arm64-efi/*.module
cp /usr/share/grub/unicode.pf2 /boot/grub/fonts/
for i in /usr/share/locale/*/LC_MESSAGES/grub.mo; do
  [[ -f $i ]] && cp "$i" "/boot/grub/locale/$(echo "$i" | cut -d/ -f5).mo"
done
grub-mkimage --directory /usr/lib/grub/arm64-efi -c /tmp/grub-core.cfg --prefix /boot/grub \
  --output /boot/grub/arm64-efi/core.efi --format arm64-efi --compression auto \
  ext2 part_gpt search btrfs
rm -f /tmp/grub-core.cfg

# ------------------------------------------------------------------------------------- fstab
say "fstab"
# kirki's Btrfs layout. The root partition and file system grow to fill the virtual disk, whose
# size is set in the Mac app (kirk-vm-grow); the EFI partition is only read by the firmware.
O=noatime,compress=zstd:1,space_cache=v2,discard=async
cat > /etc/fstab <<EOF
# kirki for the Mac app (virtual machine)
UUID=$ROOT_UUID  /                      btrfs  $O,subvol=@      0 0
UUID=$ROOT_UUID  /home                  btrfs  $O,subvol=@home  0 0
UUID=$ROOT_UUID  /var/log               btrfs  $O,subvol=@log   0 0
UUID=$ROOT_UUID  /var/cache/pacman/pkg  btrfs  $O,subvol=@cache 0 0
UUID=$EFI_UUID   /boot/efi  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro,nofail,x-systemd.device-timeout=10s  0 2
EOF

# ------------------------------------------------------------------------------------- accounts
say "Accounts"
# Arch Linux ARM ships an 'alarm' account (password alarm) and root with password root.
userdel -r alarm 2>/dev/null || true
passwd -l root >/dev/null
# systemd-firstboot would stop the first start to ask questions; the kirki setup asks them instead
mkdir -p /etc/systemd/system/systemd-firstboot.service.d
cat > /etc/systemd/system/systemd-firstboot.service.d/no-prompt.conf <<'EOF'
[Service]
ExecStart=
ExecStart=systemd-firstboot
EOF
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf
echo kirki > /etc/hostname

# ------------------------------------------------------------------------------------- kirki
say "kirki files"
# kirki's files, then VM versions of the few that name Asahi, then the VM's own (image/vm-overlay).
kv_install_tree "$K/overlay/installed"
kv_derive_files "$K"
kv_install_tree "$V/image/vm-overlay"
cat > /etc/kirk-release <<EOF
VERSION=$VERSION
INSTALL_DATE=$(date -I)
INSTALL_MODE=vm
INSTALL_FS=btrfs
INSTALL_ENGINE=image
HW_APPLE_SILICON=no
KIRKI_REF=$KIRKI_REF
SOURCE=release $VERSION
EOF
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
/usr/local/bin/kirk-branding
/usr/local/bin/kirk-install-fonts
/usr/local/bin/kirk-login-theme kirkus
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo ||
  echo "WARNING: couldn't add Flathub; kirk-update adds it later."
for d in hicolor kirkus kirkus-light; do gtk-update-icon-cache -q -t -f "/usr/share/icons/$d" 2>/dev/null || true; done

if command -v timeshift >/dev/null; then
  mkdir -p /etc/timeshift
  cat > /etc/timeshift/timeshift.json <<EOF
{
  "backup_device_uuid" : "$ROOT_UUID",
  "parent_device_uuid" : "",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "false",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "schedule_monthly" : "false",
  "schedule_weekly" : "true",
  "schedule_daily" : "true",
  "schedule_hourly" : "false",
  "schedule_boot" : "false",
  "count_monthly" : "2",
  "count_weekly" : "3",
  "count_daily" : "5",
  "count_hourly" : "6",
  "count_boot" : "5",
  "snapshot_size" : "0",
  "snapshot_count" : "0",
  "date_format" : "%Y-%m-%d %H:%M:%S",
  "exclude" : [],
  "exclude-apps" : []
}
EOF
fi

# ------------------------------------------------------------------------------------- sound
say "Sound: Linux's virtio sound driver, built with DKMS"
kv_build_sound

# ------------------------------------------------------------------------------------- boot
say "Boot splash and boot menu"
kv_initramfs_config
plymouth-set-default-theme kirkus
mkinitcpio -P
[[ -s /boot/initramfs-linux.img ]] || { echo "mkinitcpio didn't make /boot/initramfs-linux.img"; exit 1; }
kv_grub_defaults "$BRAND"
# grub.cfg itself is written by build.sh, once the image is mounted where GRUB will find it

# ------------------------------------------------------------------------------------- services
say "Services"
kv_enable_services
systemctl enable kirk-setup.service

# ------------------------------------------------------------------------------------- tidy up
say "Tidying up"
pacman -Scc --noconfirm >/dev/null 2>&1 || true
rm -rf /var/cache/pacman/pkg/* /tmp/* /root/.cache
# each install gets its own machine ID on its first start
: > /etc/machine-id
touch /kirk-src/setup-complete       # build.sh checks for it
echo "kirki $VERSION for the Mac app is set up in the image."
