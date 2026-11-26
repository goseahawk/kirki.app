# shellcheck shell=bash
# Shared by image/setup.sh (building the disk image) and apply-to-installed.sh (updating a kirki that's
# already installed in the Mac app): which packages kirki has in a virtual machine, how its files are
# installed, and how it starts. Everything here runs as root on the kirki system itself, or in its
# chroot while the image is built.
#
# kirki (github.com/goseahawk/kirki) is the source of the desktop: its packages, overlay/installed and
# scripts are used as they are, except for what only makes sense on a Mac's own hardware (the Asahi
# kernel and boot chain). Those differences are all in this file and in image/vm-overlay/.

# Asahi Linux's Mac support, which kirki needs on a Mac's own hardware. A virtual machine has none of
# that hardware, and Arch Linux ARM's generic kernel has the virtio drivers a VM needs instead.
KV_ASAHI_PKGS=(linux-asahi asahi-meta asahi-desktop-meta asahi-scripts asahi-fwextract m1n1 uboot-asahi)
# The generic kernel doesn't build Linux's virtio sound driver, so kirki builds it with DKMS
# (/usr/src/virtio-snd-1), which needs the kernel headers.
KV_VM_PKGS=(linux-aarch64 linux-aarch64-headers dkms)

kv_fail() { echo "ERROR: $*" >&2; return 1; }

# kv_packages KIRKI_DIR: sets KV_PKGS and KV_OPTIONAL from kirki's own lists in its image/setup.sh,
# without the Asahi packages and with the VM's.
kv_packages() {
  local setup=$1/image/setup.sh p a skip PKGS=() OPTIONAL=()
  grep -q '^PKGS=($' "$setup" && grep -q '^OPTIONAL=(.*)$' "$setup" \
    || kv_fail "kirki's image/setup.sh no longer has its PKGS=( ... ) and OPTIONAL=( ... ) lists; update image/lib.sh" || return 1
  eval "$(sed -n '/^PKGS=($/,/^)$/p' "$setup")"
  eval "$(grep '^OPTIONAL=(.*)$' "$setup")"
  ((${#PKGS[@]} > 20)) || kv_fail "only ${#PKGS[@]} packages found in kirki's image/setup.sh" || return 1
  KV_PKGS=()
  for p in "${PKGS[@]}"; do
    skip=no
    for a in "${KV_ASAHI_PKGS[@]}"; do [[ $p == "$a" ]] && skip=yes; done
    [[ $skip == yes ]] || KV_PKGS+=("$p")
  done
  KV_PKGS+=("${KV_VM_PKGS[@]}")
  # shellcheck disable=SC2034  # used by image/setup.sh
  KV_OPTIONAL=("${OPTIONAL[@]}")
}

# kv_install_tree DIR [PATH...]: copies every file in DIR onto /, owned by root. Programs get 755,
# everything else 644, the same rule as kirki's. The PATHs (relative, like etc/kirk-update.conf) are
# only installed when they don't exist yet, so settings people changed survive updates.
kv_install_tree() {
  local from=$1 rel mode k skip
  shift
  while IFS= read -r -d '' rel; do
    skip=no
    for k in "$@"; do [[ $rel == "$k" && -e /$rel ]] && skip=yes; done
    [[ $skip == yes ]] && continue
    case $rel in
      usr/local/bin/*|etc/grub.d/*|usr/lib/systemd/system-shutdown/*|usr/src/*.sh) mode=755 ;;
      *) mode=644 ;;
    esac
    install -D -o root -g root -m "$mode" "$from/$rel" "/$rel"
  done < <(cd "$from" && find . -type f -printf '%P\0')
}

# kv_derive_files KIRKI_DIR: installs VM versions of the kirki files that name the Asahi kernel or
# its signing keys. Every change is checked, so the build stops if one of kirki's files changed shape.
kv_derive_files() {
  local src=$1/overlay/installed tmp
  tmp=$(mktemp -d)
  # Weekly updates: refresh Arch Linux ARM's keyring (there's no Asahi ALARM repository in a VM), and
  # "restart needed" follows the generic kernel.
  sed -e 's/ asahi-alarm-keyring//' \
      -e 's/linux-asahi/linux-aarch64/g' \
      -e "s/Arch Linux ARM's and Asahi ALARM's signing keys/Arch Linux ARM's signing keys/" \
      -e 's/the Arch Linux ARM + Asahi system/the Arch Linux ARM system/' \
      "$src/usr/local/bin/kirk-auto-update" > "$tmp/kirk-auto-update"
  if grep -q 'asahi-alarm-keyring' "$tmp/kirk-auto-update" \
     || ! grep -q 'pacman -Q linux-aarch64' "$tmp/kirk-auto-update" \
     || ! grep -q 'pacman -Sy --needed --noconfirm archlinuxarm-keyring &&' "$tmp/kirk-auto-update"; then
    rm -rf "$tmp"
    kv_fail "kirki's kirk-auto-update changed; update kv_derive_files in image/lib.sh"
    return 1
  fi
  install -D -o root -g root -m 755 "$tmp/kirk-auto-update" /usr/local/bin/kirk-auto-update
  # A snapshot before kernel upgrades: the generic kernel instead of the Asahi boot packages
  sed -e 's/^Target = linux-asahi$/Target = linux-aarch64/' \
      -e '/^Target = \(m1n1\|uboot-asahi\|asahi-scripts\|asahi-fwextract\)$/d' \
      "$src/etc/pacman.d/hooks/00-kirk-snapshot.hook" > "$tmp/00-kirk-snapshot.hook"
  if ! grep -qx 'Target = linux-aarch64' "$tmp/00-kirk-snapshot.hook" || grep -qi 'asahi' "$tmp/00-kirk-snapshot.hook"; then
    rm -rf "$tmp"
    kv_fail "kirki's 00-kirk-snapshot.hook changed; update kv_derive_files in image/lib.sh"
    return 1
  fi
  install -D -o root -g root -m 644 "$tmp/00-kirk-snapshot.hook" /etc/pacman.d/hooks/00-kirk-snapshot.hook
  rm -rf "$tmp"
}

# Set KEY=VALUE in a defaults file: replace the first (possibly commented-out) line, else append.
kv_set_var() {
  local key=$1 val=$2 f=$3
  if grep -qE "^#?[[:space:]]*$key=" "$f"; then
    sed -i -E "0,/^#?[[:space:]]*$key=/s|^#?[[:space:]]*$key=.*|$key=$val|" "$f"
  else
    echo "$key=$val" >> "$f"
  fi
}

# kv_set_release_key KEY VALUE: in /etc/kirk-release
kv_set_release_key() {
  touch /etc/kirk-release
  if grep -q "^$1=" /etc/kirk-release; then sed -i "s|^$1=.*|$1=$2|" /etc/kirk-release
  else echo "$1=$2" >> /etc/kirk-release; fi
}

# The initramfs: kirki's hooks without Asahi's (there's no Mac firmware to unpack in a VM). The disk,
# its controller and Btrfs are built into the generic kernel; virtio_gpu is added so the boot splash
# has the screen from the start. Every module is listed, since autodetect only sees the build machine.
kv_initramfs_config() {
  local hooks="base udev plymouth autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
  [[ -f /usr/lib/initcpio/install/grub-btrfs-overlayfs ]] && hooks+=" grub-btrfs-overlayfs"
  sed -i -E "s/^HOOKS=\(.*/HOOKS=($hooks)/" /etc/mkinitcpio.conf
  sed -i -E 's/^MODULES=\(.*/MODULES=(virtio_pci virtio_blk virtio_gpu btrfs)/' /etc/mkinitcpio.conf
  grep -E '^(MODULES|HOOKS)=' /etc/mkinitcpio.conf
}

# kv_grub_defaults BRAND: kirki's boot menu settings. In a VM the kernel also writes to the virtio
# console (hvc0), which the Mac app keeps as a log and reads to tell a restart from a shutdown; tty0
# comes last so the boot splash keeps the screen.
kv_grub_defaults() {
  local brand=$1 G=/etc/default/grub
  kv_set_var GRUB_DISTRIBUTOR "\"$brand\"" $G
  kv_set_var GRUB_TIMEOUT 1 $G
  kv_set_var GRUB_TIMEOUT_STYLE hidden $G
  kv_set_var GRUB_THEME '"/boot/grub/themes/kirkus/theme.txt"' $G
  kv_set_var GRUB_TERMINAL_OUTPUT gfxterm $G
  kv_set_var GRUB_GFXMODE auto $G
  kv_set_var GRUB_GFXPAYLOAD_LINUX keep $G
  sed -i -E '/^GRUB_CMDLINE_LINUX_DEFAULT=/{/splash/!s/"$/ splash"/}' $G
  sed -i -E '/^GRUB_CMDLINE_LINUX_DEFAULT=/{/console=hvc0/!s/"$/ console=hvc0 console=tty0"/}' $G
  if [[ -d /etc/default/grub-btrfs || -f /usr/bin/grub-btrfsd ]]; then
    mkdir -p /etc/default/grub-btrfs
    touch /etc/default/grub-btrfs/config
    kv_set_var GRUB_BTRFS_SUBMENUNAME "\"$brand snapshots\"" /etc/default/grub-btrfs/config
  fi
  /usr/local/bin/kirk-grub-theme-font || true
}

# The services a kirki VM runs. (No Bluetooth: macOS keeps the Mac's Bluetooth, and devices paired
# there just work in kirki.) Weekly updates stay off if they were turned off.
kv_enable_services() {
  systemctl enable NetworkManager.service sddm.service power-profiles-daemon.service \
    fstrim.timer systemd-timesyncd.service cronie.service \
    kirk-vm-agent.service kirk-vm-grow.service kirk-vm-rosetta.service kirk-vm-autologin.service
  if grep -q '^AUTO_SYSTEM_UPDATE=no' /etc/kirk-update.conf 2>/dev/null; then
    systemctl disable kirk-auto-update.timer 2>/dev/null || true
  else
    systemctl enable kirk-auto-update.timer
  fi
  if command -v ufw >/dev/null; then systemctl enable kirk-firewall-setup.service; fi
  if command -v timeshift >/dev/null; then systemctl enable kirk-first-snapshot.service; fi
  if command -v grub-btrfsd >/dev/null; then systemctl enable grub-btrfsd.service; fi
  # The virtio console is the kernel's log for the Mac app, not a place to log in.
  systemctl mask serial-getty@hvc0.service >/dev/null
}

# kv_kernel_version: the installed linux-aarch64's version, as in /usr/lib/modules
kv_kernel_version() {
  pacman -Ql linux-aarch64 2>/dev/null | sed -n 's|^linux-aarch64 /usr/lib/modules/\([^/]*\)/$|\1|p' | head -1
}

# kv_kernel_link: GRUB's menu generator only finds kernels called /boot/vmlinuz-*, and Arch Linux
# ARM's kernel is /boot/Image (with /boot/initramfs-linux.img). A link with the name GRUB expects
# keeps working through kernel updates, which replace Image in place.
kv_kernel_link() {
  [[ -f /boot/Image ]] || kv_fail "/boot/Image is missing: is linux-aarch64 installed?" || return 1
  ln -sfn Image /boot/vmlinuz-linux
}

# kv_build_sound: builds the virtio sound driver for every installed kernel (see /usr/src/virtio-snd-1)
kv_build_sound() {
  local kver
  kver=$(kv_kernel_version)
  [[ -n $kver ]] || kv_fail "no linux-aarch64 kernel found" || return 1
  dkms add virtio-snd/1 >/dev/null 2>&1 || true      # already added on an update
  dkms install --force virtio-snd/1 -k "$kver"
  compgen -G "/usr/lib/modules/$kver/updates/dkms/virtio_snd.ko*" >/dev/null \
    || kv_fail "the virtio sound driver didn't build for $kver" || return 1
  echo "virtio sound driver built for $kver"
}
