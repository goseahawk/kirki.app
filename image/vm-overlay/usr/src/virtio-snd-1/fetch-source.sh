#!/bin/bash
# DKMS runs this before building virtio-snd for a kernel (PRE_BUILD in dkms.conf), in the build folder.
# It brings Linux's virtio sound driver (sound/virtio) for that kernel's version, from Linux's own
# repository (github.com/torvalds/linux, tag vMAJOR.MINOR), so the driver always matches the kernel
# it's built for: which files it has comes from that version's own Makefile. Downloads are kept in
# /var/lib/kirki-vm/virtio-snd/; with no internet connection, the newest one kept there is used. The
# image comes with the one for the kernel it shipped with.
#
#   fetch-source.sh KERNEL_VERSION     e.g. 7.3.6-1-ARCH
set -u
kver=${1:?usage: fetch-source.sh KERNEL_VERSION}
CACHE=${VIRTIO_SND_CACHE:-/var/lib/kirki-vm/virtio-snd}
BASE=${VIRTIO_SND_BASE:-https://raw.githubusercontent.com/torvalds/linux}

series=$(sed -nE 's/^([0-9]+)\.([0-9]+).*/v\1.\2/p' <<<"$kver")
[[ -n $series ]] || { echo "virtio-snd: can't tell the version of kernel '$kver'"; exit 1; }

fetch() { curl -fsSL --retry 2 --max-time 60 -o "$2" "$BASE/$series/sound/virtio/$1"; }

# download_into DIR: this version's Makefile, its .c files and every local header they include
download_into() {
  local d=$1 objs o h new
  fetch Makefile "$d/Makefile.linux" || return 1
  objs=$(tr -d '\\\t' < "$d/Makefile.linux" | grep -oE '[a-z0-9_]+\.o' | grep -vx 'virtio_snd\.o' | sort -u)
  [[ -n $objs ]] || return 1
  for o in $objs; do fetch "${o%.o}.c" "$d/${o%.o}.c" || return 1; done
  new=yes
  while [[ $new == yes ]]; do
    new=no
    # shellcheck disable=SC2013  # header names have no spaces
    for h in $(grep -ho '#include "[a-z0-9_]*\.h"' "$d"/*.c "$d"/*.h 2>/dev/null | sed 's/.*"\(.*\)"/\1/' | sort -u); do
      [[ -e $d/$h ]] && continue
      fetch "$h" "$d/$h" || return 1
      new=yes
    done
  done
  # Linux builds it only when CONFIG_SND_VIRTIO is set, which is exactly what's missing: build it anyway
  # shellcheck disable=SC2016  # a literal $( in the Makefile
  sed 's/^obj-\$(CONFIG_SND_VIRTIO)/obj-m/' "$d/Makefile.linux" > "$d/Makefile"
  rm -f "$d/Makefile.linux"
  grep -q '^obj-m' "$d/Makefile"
}

if [[ ! -e $CACHE/$series/.complete ]]; then
  tmp=$(mktemp -d)
  if download_into "$tmp"; then
    rm -rf "${CACHE:?}/$series"
    mkdir -p "$CACHE/$series"
    cp "$tmp"/* "$CACHE/$series/"
    touch "$CACHE/$series/.complete"
  else
    echo "virtio-snd: couldn't download the driver for Linux $series."
  fi
  rm -rf "$tmp"
fi

src=$CACHE/$series
if [[ ! -e $src/.complete ]]; then
  # this kernel's isn't available (offline, or a version Linux hasn't tagged): the newest we have
  src=$(find "$CACHE" -mindepth 2 -maxdepth 2 -name .complete -printf '%h\n' 2>/dev/null | sort -V | tail -1)
fi
[[ -n $src && -e $src/.complete ]] || { echo "virtio-snd: no driver source available."; exit 1; }
rm -f ./*.c ./*.h
cp "$src"/*.c "$src"/*.h "$src"/Makefile .
echo "virtio-snd: building Linux $(basename "$src")'s virtio sound driver for $kver"
