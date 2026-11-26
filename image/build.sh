#!/usr/bin/env bash
# Builds the kirki disk image the kirki Mac app runs: kirki's desktop (github.com/goseahawk/kirki, at
# the commit in image/kirki.ref) set up for a virtual machine.
#
#     sudo image/build.sh
#
# Run it on 64-bit ARM Linux: GitHub's ubuntu-24.04-arm runners (the Release workflow), an ARM cloud
# machine, or Linux in a VM on an Apple Silicon Mac. It needs bsdtar, arch-chroot
# (arch-install-scripts), btrfs-progs, dosfstools, fdisk (sfdisk), rsync, curl, xz, python3 and loop
# devices: apt install libarchive-tools arch-install-scripts btrfs-progs dosfstools fdisk rsync curl xz-utils
#
# Settings (environment):
#   KIRK_VERSION   the version, YY.MM.DD or YY.MM.DD.N (default: today's date)
#   KIRK_REPO      the GitHub repository the release is published in (default goseahawk/kirki.app);
#                  the download links in kirki-vm.json point at its release KIRK_VERSION
#   KIRKI_SRC      a kirki checkout to use instead of downloading kirki at image/kirki.ref
#   KIRK_KEEP_RAW  yes: also keep the uncompressed disk image, out/kirki-vm-VERSION.img (for
#                  image/test-boot.py)
#
# Output, in out/:
#   kirki-vm-VERSION.img.xz      the disk image, xz-compressed; split into .partNN files of under
#                                2 GiB if it's bigger (GitHub's limit for a release file)
#   kirki-vm.json                what the Mac app reads: version, download parts, sizes, checksums
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo KIRK_VERSION="${KIRK_VERSION:-}" KIRK_REPO="${KIRK_REPO:-}" \
  KIRKI_SRC="${KIRKI_SRC:-}" KIRK_KEEP_RAW="${KIRK_KEEP_RAW:-}" "$0" "$@"

VERSION=${KIRK_VERSION:-$(date +%y.%m.%d)}
[[ $VERSION =~ ^[0-9]{2}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] || { echo "Bad version '$VERSION': use YY.MM.DD or YY.MM.DD.N"; exit 1; }
REPO=${KIRK_REPO:-goseahawk/kirki.app}
[[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Bad repository '$REPO': use owner/name"; exit 1; }

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$HERE/build
DL=$WORK/dl
ROOT=$WORK/root
IMG=$WORK/img
OUT=$HERE/out
NAME=kirki-vm-$VERSION
RAW=$WORK/$NAME.img
KIRKI_REF=$(tr -d '[:space:]' < "$HERE/image/kirki.ref")
[[ $KIRKI_REF =~ ^[0-9a-f]{40}$ ]] || { echo "image/kirki.ref must hold a full kirki commit hash"; exit 1; }
# Fixed for the image: every VM has its own disk, so two never meet. GRUB, fstab and Timeshift use them.
ROOT_UUID=3ebc7cc5-64a0-4165-90c0-e6949f86a7e7
EFI_UUID=4B1D-2E5B
ESP_MIB=256
PART_MAX=$((1900 * 1024 * 1024))          # split the download into parts no bigger than this
BASE_URL=https://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
echo "Building kirki for the Mac app, $VERSION (kirki ${KIRKI_REF:0:7}; releases from github.com/$REPO)"

# ---------------------------------------------------------------------------------------- checks
case $(uname -m) in
  aarch64|arm64) ;;
  *) if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
       echo "This computer is $(uname -m), and the image is 64-bit ARM: build it on ARM Linux (or install"
       echo "qemu-user-static with binfmt support to build under emulation, which takes hours)."
       exit 1
     fi
     echo "Not an ARM computer: building under qemu emulation. Expect several hours." ;;
esac
missing=()
for c in bsdtar arch-chroot mkfs.btrfs btrfs mkfs.fat sfdisk rsync curl xz python3 losetup sha256sum; do
  command -v "$c" >/dev/null || missing+=("$c")
done
if ((${#missing[@]})); then
  echo "Missing tools: ${missing[*]}"
  echo "  Debian/Ubuntu: apt install libarchive-tools arch-install-scripts btrfs-progs dosfstools fdisk rsync curl xz-utils python3"
  exit 1
fi

# Never leave anything mounted or attached, whatever happens. (A subshell, so its "set +e" doesn't
# turn error checking off for the rest of the build.)
LOOPS=()
cleanup() (
  set +e
  for m in "$IMG" "$ROOT"; do
    while grep -q " ${m}[/ ]" /proc/mounts 2>/dev/null; do
      awk -v m="$m" '$2 == m || index($2, m "/") == 1 {print $2}' /proc/mounts | sort -r | xargs -r umount -l
      sleep 0.2
    done
  done
)
detach() { local l; for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done; LOOPS=(); }
trap 'cleanup; detach; true' EXIT

# ---------------------------------------------------------------------------------------- kirki
cleanup
rm -rf "$ROOT" "$IMG" "$WORK/kirki"
mkdir -p "$DL" "$ROOT" "$IMG" "$OUT"
if [[ -n ${KIRKI_SRC:-} ]]; then
  KIRKI=$(cd "$KIRKI_SRC" && pwd)
  echo "== Using kirki from $KIRKI =="
else
  echo "== Downloading kirki ${KIRKI_REF:0:7} =="
  mkdir -p "$WORK/kirki"
  curl -fsSL --retry 3 "https://github.com/goseahawk/kirki/archive/$KIRKI_REF.tar.gz" \
    | tar -xz -C "$WORK/kirki" --strip-components=1
  KIRKI=$WORK/kirki
fi
for f in overlay/installed image/setup.sh apply-to-installed.sh; do
  [[ -e $KIRKI/$f ]] || { echo "$KIRKI doesn't look like kirki: no $f"; exit 1; }
done

# ---------------------------------------------------------------------------------------- base
if [[ ! -s $DL/base.tar.gz ]] || [[ -n $(find "$DL/base.tar.gz" -mtime +6 2>/dev/null) ]]; then
  echo "== Downloading Arch Linux ARM =="
  curl -fL --retry 3 -o "$DL/base.tar.gz.part" "$BASE_URL"
  curl -fsSL --retry 3 -o "$DL/base.tar.gz.md5" "$BASE_URL.md5"
  (cd "$DL" && [[ $(md5sum < base.tar.gz.part | cut -d' ' -f1) == "$(cut -d' ' -f1 base.tar.gz.md5)" ]]) \
    || { echo "The Arch Linux ARM download is damaged (checksum mismatch). Run again."; exit 1; }
  mv "$DL/base.tar.gz.part" "$DL/base.tar.gz"
fi
echo "== Unpacking =="
bsdtar -xpf "$DL/base.tar.gz" -C "$ROOT"
mount --bind "$ROOT" "$ROOT"          # arch-chroot wants the new root to be a mount point
mkdir -p "$ROOT/kirk-src/kirki" "$ROOT/kirk-src/vm"
cp -r "$KIRKI/overlay" "$KIRKI/image" "$KIRKI/apply-to-installed.sh" "$ROOT/kirk-src/kirki/"
cp -r "$HERE/image" "$ROOT/kirk-src/vm/"

# ---------------------------------------------------------------------------------------- set up
echo "== Setting up kirki in the image (this is the long part) =="
arch-chroot "$ROOT" env VERSION="$VERSION" ROOT_UUID="$ROOT_UUID" EFI_UUID="$EFI_UUID" KIRKI_REF="$KIRKI_REF" \
  /bin/bash /kirk-src/vm/image/setup.sh
# setup.sh leaves this as its very last step: anything less is a failed build
[[ -e $ROOT/kirk-src/setup-complete ]] || { echo "Setting up the image didn't finish (see the errors above)."; exit 1; }
rm -rf "$ROOT/kirk-src"
cleanup

# ---------------------------------------------------------------------------------------- disk
echo "== Making the disk =="
size=$(du -B M -s -x "$ROOT" | cut -dM -f1)
root_mib=$((size + size / 8 + 768))    # room for the first start; the app grows it to the size you choose
disk_mib=$((1 + ESP_MIB + root_mib + 1))
echo "Contents: $(du -sh -x "$ROOT" | cut -f1); disk: ${disk_mib} MiB"
rm -f "$RAW"
truncate -s "${disk_mib}M" "$RAW"
# GPT: the EFI partition, then kirki's root (marked as a 64-bit ARM root partition), which is last so
# it can grow into the space the app adds at the end of the disk.
sfdisk --quiet "$RAW" <<EOF
label: gpt
first-lba: 2048
size=${ESP_MIB}MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name="kirki"
EOF
read -r esp_start esp_size root_start root_size < <(sfdisk -J "$RAW" | python3 -c '
import json, sys
p = json.load(sys.stdin)["partitiontable"]["partitions"]
print(p[0]["start"], p[0]["size"], p[1]["start"], p[1]["size"])')
# One loop device per partition, by offset (works without partition scanning)
esp_dev=$(losetup --find --show --offset $((esp_start * 512)) --sizelimit $((esp_size * 512)) "$RAW"); LOOPS+=("$esp_dev")
root_dev=$(losetup --find --show --offset $((root_start * 512)) --sizelimit $((root_size * 512)) "$RAW"); LOOPS+=("$root_dev")
mkfs.fat -F 32 -n EFI -i "${EFI_UUID/-/}" "$esp_dev" >/dev/null
mkfs.btrfs -q -U "$ROOT_UUID" -L kirki "$root_dev"
mount "$root_dev" "$IMG"
for sv in @ @home @log @cache; do btrfs subvolume create "$IMG/$sv" >/dev/null; done
umount "$IMG"
# Mounted the way the installed system mounts it, so each part lands in its own subvolume.
# zstd:9 here only makes the image smaller; the installed system writes with zstd:1.
O=compress=zstd:9,noatime
mount -o "$O,subvol=@" "$root_dev" "$IMG"
mkdir -p "$IMG/home" "$IMG/var/log" "$IMG/var/cache/pacman/pkg" "$IMG/boot/efi"
mount -o "$O,subvol=@home" "$root_dev" "$IMG/home"
mount -o "$O,subvol=@log" "$root_dev" "$IMG/var/log"
mount -o "$O,subvol=@cache" "$root_dev" "$IMG/var/cache/pacman/pkg"
rsync -aHAX --info=stats1 --exclude '/boot/efi/*' "$ROOT/" "$IMG/"
mount "$esp_dev" "$IMG/boot/efi"
mkdir -p "$IMG/boot/efi/EFI/BOOT"
cp "$IMG/boot/grub/arm64-efi/core.efi" "$IMG/boot/efi/EFI/BOOT/BOOTAA64.EFI"

echo "== Boot menu =="
# Generated on the mounted image, so GRUB finds the root file system by the UUID it will have.
if ! arch-chroot "$IMG" grub-mkconfig -o /boot/grub/grub.cfg; then
  echo "grub-mkconfig failed; trying again without the snapshots submenu"
  chmod -x "$IMG/etc/grub.d/41_snapshots-btrfs" 2>/dev/null || true
  arch-chroot "$IMG" grub-mkconfig -o /boot/grub/grub.cfg
  chmod +x "$IMG/etc/grub.d/41_snapshots-btrfs" 2>/dev/null || true
fi
grep -q "/@/boot/vmlinuz-linux " "$IMG/boot/grub/grub.cfg" || { echo "grub.cfg has no kirki entry."; exit 1; }
grep -q "console=hvc0" "$IMG/boot/grub/grub.cfg" || { echo "grub.cfg doesn't send the kernel's log to the app."; exit 1; }
grep -q "initramfs-linux.img" "$IMG/boot/grub/grub.cfg" || { echo "grub.cfg has no initramfs."; exit 1; }
cleanup
detach
rm -rf "$ROOT"

# ---------------------------------------------------------------------------------------- package
echo "== Compressing (several minutes) =="
rm -f "$OUT/$NAME".img* "$OUT/kirki-vm.json"
raw_size=$(stat -c %s "$RAW")
raw_sha=$(sha256sum "$RAW" | cut -d' ' -f1)
# xz: macOS reads it with its own Compression framework (the app has no other decompressor)
xz -T0 -6 -c "$RAW" > "$OUT/$NAME.img.xz"
xz_size=$(stat -c %s "$OUT/$NAME.img.xz")
xz_sha=$(sha256sum "$OUT/$NAME.img.xz" | cut -d' ' -f1)
parts=()
if ((xz_size > PART_MAX)); then
  (cd "$OUT" && split -b "$PART_MAX" -d -a 2 "$NAME.img.xz" "$NAME.img.xz.part" && rm "$NAME.img.xz")
  for p in "$OUT/$NAME.img.xz.part"*; do parts+=("$(basename "$p")"); done
else
  parts=("$NAME.img.xz")
fi
python3 - "$OUT" "$VERSION" "$REPO" "$KIRKI_REF" "$raw_size" "$raw_sha" "$xz_size" "$xz_sha" "${parts[@]}" > "$OUT/kirki-vm.json" <<'PY'
import hashlib, json, os, sys
out, version, repo, kirki, raw_size, raw_sha, xz_size, xz_sha, *parts = sys.argv[1:]
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
manifest = {
    "format": 1,
    "version": version,
    "kirki": kirki,
    "image": {
        "compression": "xz",
        "size": int(xz_size),
        "sha256": xz_sha,
        "uncompressedSize": int(raw_size),
        "uncompressedSha256": raw_sha,
        "parts": [
            {
                "url": f"https://github.com/{repo}/releases/download/{version}/{p}",
                "size": os.path.getsize(os.path.join(out, p)),
                "sha256": sha256(os.path.join(out, p)),
            }
            for p in parts
        ],
    },
}
json.dump(manifest, sys.stdout, indent=2)
print()
PY
if [[ ${KIRK_KEEP_RAW:-} == yes ]]; then mv "$RAW" "$OUT/$NAME.img"; else rm -f "$RAW"; fi
chmod 644 "$OUT"/*

echo
echo "Done: kirki $VERSION for the Mac app is in $OUT/"
ls -l "$OUT"
cat "$OUT/kirki-vm.json"
