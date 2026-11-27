#!/bin/bash
# shellcheck disable=SC2016  # the mocks are single-quoted on purpose: they expand when they run
# Tests install.sh and uninstall.sh on Linux, against mocks of the macOS and Docker commands they use.
#     bash tests/install-test.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; failed=0
check() { if eval "$1"; then pass=$((pass + 1)); echo "  ok: $2"; else failed=$((failed + 1)); echo "  FAIL: $2"; sed 's/^/      | /' "$T/out"; fi; }

mkdir -p "$T/bin" "$T/state"
mock() { printf '#!/bin/sh\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
mock uname 'echo Darwin'
mock open 'echo "open $*" >> "$T/log"'
mock readlink 'echo /var/db/timezone/zoneinfo/Europe/Berlin'
mock curl 'echo 200'
mock sleep 'exit 0'
mock brew 'echo "brew $*" >> "$T/log"; exit 1'
mock dscl 'exit 1'
mock pgrep 'exit 1'
mock stat 'echo tester'
mock id 'case "$1" in -u) echo 501 ;; -un) echo tester ;; *) echo 501 ;; esac'
# docker: "running" unless $T/state/stopped; containers and volumes are files in $T/state
mock docker '
echo "docker $*" >> "$T/log"
S="$T/state"
case $1 in
  info) [ -e "$S/stopped" ] && exit 1; exit 0 ;;
  pull) [ -e "$S/no-pull" ] && exit 1; touch "$S/image"; exit 0 ;;
  container) [ -e "$S/container" ] ;;
  rm) rm -f "$S/container"; exit 0 ;;
  run) touch "$S/container" "$S/volume"; exit 0 ;;
  volume) [ -e "$S/volume" ] || exit 1; rm -f "$S/volume" ;;
  images) [ -e "$S/image" ] && echo "ghcr.io/goseahawk/kirki:latest@abc123"; exit 0 ;;
  rmi) rm -f "$S/image" ;;
  image) exit 0 ;;
esac'
for f in install.sh uninstall.sh; do
  # (command -v docker: only the mock counts, not a real Docker on the test machine)
  sed -e "s|export PATH=\"|export PATH=\"$T/bin:|" -e "s|/dev/tty|$T/tty|g" -e "s|command -v docker|command -v $T/bin/docker|" -e "s|\\\$T|$T|g" "$HERE/$f" > "$T/$f"
done
sed -i "s|\$T|$T|g" "$T"/bin/*

# run SCRIPT ANSWERS...: runs it as `curl ... | sh` would, with these keyboard answers
run() {
  local script=$1; shift
  rm -f "$T/tty" "$T/log"; touch "$T/log"
  # a FIFO kept open, so each read gets the next answer, as from a keyboard
  mkfifo "$T/tty"
  exec 7<>"$T/tty"
  printf '%s\n' "$@" >&7
  HOME="$T/home" sh < "$T/$script" > "$T/out" 2>&1
  local rc=$?
  exec 7>&-
  return $rc
}
mkdir -p "$T/home"

echo "== fresh install"
run install.sh ""
rc=$?
check "[ $rc -eq 0 ]" "exits 0"
check "grep -q 'docker pull ghcr.io/goseahawk/kirki:latest' '$T/log'" "the image is downloaded"
check "grep -q -- '-p 127.0.0.1:3010:3000' '$T/log'" "only this Mac can reach it, on port 3010"
check "grep -q -- '-v kirki-home:/config' '$T/log'" "your files are kept in a volume"
check "grep -q -- '--restart unless-stopped' '$T/log'" "it starts again with Docker Desktop"
check "grep -q 'TZ=Europe/Berlin' '$T/log'" "kirki gets the Mac's time zone"
check "grep -q 'open http://localhost:3010' '$T/log'" "the browser opens kirki"

echo "== running it again: an update"
run install.sh ""
check "grep -q 'docker rm -f kirki' '$T/log' && [ -e '$T/state/container' ]" "the old container is replaced"
check "grep -q 'files in kirki are kept' '$T/out'" "it says your files are kept"

echo "== Docker Desktop not running"
touch "$T/state/stopped"
( sleep 0.3; rm -f "$T/state/stopped" ) &
mock sleep 'command sleep 0.2'
sed -i "s|command sleep|$(command -v sleep)|" "$T/bin/sleep"
run install.sh ""
rc=$?
wait
check "[ $rc -eq 0 ] && grep -q 'open -a Docker' '$T/log'" "Docker Desktop is started, then kirki"
mock sleep 'exit 0'

echo "== no Docker"
mv "$T/bin/docker" "$T/bin/docker.off"
run install.sh "" "n"
rc=$?
check "[ $rc -ne 0 ] && grep -q 'docker.com/products/docker-desktop' '$T/out'" "it says where to get Docker Desktop"
check "grep -q 'brew' '$T/out' || ! grep -q 'brew install' '$T/log'" "Homebrew isn't used when you say no"
mv "$T/bin/docker.off" "$T/bin/docker"

echo "== a failed download"
touch "$T/state/no-pull"
run install.sh ""
rc=$?
rm -f "$T/state/no-pull"
check "[ $rc -ne 0 ] && grep -q \"Couldn't download kirki\" '$T/out'" "it stops with a clear message"

echo "== another port"
KIRKI_PORT=4000 run install.sh ""
check "grep -q -- '-p 127.0.0.1:4000:3000' '$T/log'" "KIRKI_PORT is used"
KIRKI_PORT=abc run install.sh ""
check "[ \$? -ne 0 ] && grep -q 'must be a number' '$T/out'" "a bad port is refused"

echo "== uninstall"
run install.sh ""
run uninstall.sh "no thanks"
check "[ \$? -ne 0 ] && [ -e '$T/state/container' ] && grep -q 'Nothing was removed' '$T/out'" "anything but REMOVE removes nothing"
mkdir -p "$T/home/Documents"
run uninstall.sh "REMOVE"
rc=$?
check "[ $rc -eq 0 ]" "exits 0"
check "[ ! -e '$T/state/container' ] && [ ! -e '$T/state/volume' ] && [ ! -e '$T/state/image' ]" "the container, volume and image are removed"
check "! grep -q sudo '$T/log' && [ -d '$T/home/Documents' ]" "nothing else is touched"

echo "== uninstall: the earlier VM version is cleaned up too"
mkdir -p "$T/home/Library/Application Support/kirki/vm" "$T/home/Library/Logs/kirki"
mock sudo 'echo "sudo $*" >> "$T/log"'
sed -i "s|\$T|$T|g" "$T/bin/sudo"
run uninstall.sh "REMOVE"
check "[ ! -e '$T/home/Library/Application Support/kirki' ] && [ ! -e '$T/home/Library/Logs/kirki' ]" "the old copy in your account is removed"

echo "== truncation guard"
rm -f "$T/log"; touch "$T/log"
head -n 60 "$T/install.sh" > "$T/cut.sh"
HOME="$T/home" sh < "$T/cut.sh" > "$T/out" 2>&1
check "[ ! -s '$T/log' ] && ! grep -q 'kirki for Mac' '$T/out'" "a cut-off script does nothing"

echo
echo "$pass passed, $failed failed"
[ $failed -eq 0 ]
