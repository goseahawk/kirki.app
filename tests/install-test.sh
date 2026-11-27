#!/bin/bash
# Tests install.sh on Linux, against mocks of the macOS commands it uses (sysadminctl, dscl, sudo,
# curl, ditto, defaults, ...), with its absolute paths moved into a temporary folder and the keyboard
# fed from a list of answers. Nothing on this computer is changed.
#
#     tests/install-test.sh
#
# What it can't show: how the real macOS commands behave. That needs a Mac.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'exec 7>&- 2>/dev/null; rm -rf "$T"' EXIT
export T
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAILED: $*"; }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

mkdir -p "$T/bin" "$T/release" "$T/System/Library/CoreServices" "$T/Users/tester" "$T/Applications"
touch "$T/System/Library/CoreServices/SystemVersion.plist"

# ---- mocks ----
mock() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
mock uname 'case $1 in -s) echo Darwin;; -m) echo arm64;; esac'
mock sysctl 'echo "${MOCK_ARM64:-1}"'
mock sw_vers 'case $1 in -productVersion) echo "${MOCK_MACOS:-15.2}";; -buildVersion) echo 24C101;; esac'
mock id 'case "$*" in
  -u) echo "${MOCK_UID:-501}";;
  -un) echo tester;;
  -Gn) echo "staff everyone admin";;
  "-u kirki") [ -e "$T/kirki-account" ] && echo 502 || exit 1;;
  *) exit 1;; esac'
mock dscl 'echo "dscl $*" >> "$T/log"
case "$*" in
  ". -read /Users/kirki UniqueID") [ -e "$T/kirki-account" ];;
  ". -read /Users/kirki NFSHomeDirectory") [ -e "$T/kirki-account" ] && echo "NFSHomeDirectory: $T/Users/kirki";;
  ". -authonly tester "*) [ "$4" = adminpw ];;
  *) exit 0;; esac'
mock sudo 'case "$1" in
  -S) read -r pw; [ "$pw" = adminpw ];;
  -n) exit 0;;
  *) "$@";; esac'
mock sysadminctl 'echo "sysadminctl $*" >> "$T/log"
case "$1" in
  -addUser) touch "$T/kirki-account"; mkdir -p "$T/Users/kirki/Library";;
  -secureTokenStatus) echo "Secure token is ENABLED for user kirki" >&2;;
  -deleteUser) rm -rf "$T/kirki-account" "$T/Users/kirki";;
esac'
mock curl 'out=""; url=""; while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift;; -*) ;; *) url=$1;; esac; shift; done
[ "$url" = "file:///" ] && exit 0
cp "$T/release/$(basename "$url")" "$out"'
mock shasum 'sha256sum "$3"'
mock ditto 'if [ "$1" = -x ]; then unzip -q "$3" -d "$4"; else cp -a "$1" "$2"; fi'
mock codesign 'exit 0'
mock pgrep 'exit 1'
mock xattr 'exit 0'
mock chown 'echo "chown $*" >> "$T/log"'
mock install 'mode=; dirs=no; args=(); while [ $# -gt 0 ]; do case $1 in -d) dirs=yes;; -o|-g) shift;; -m) mode=$2; shift;; *) args+=("$1");; esac; shift; done
if [ $dirs = yes ]; then mkdir -p "${args[@]}"; else cp "${args[0]}" "${args[1]}"; fi'
mock defaults 'echo "defaults $*" >> "$T/log"; [ "$1" = read ] && echo 26.11.26; exit 0'
mock plutil 'python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],\"rb\"))" "$2"'
mock fdesetup 'echo "FileVault is On."'
mock createhomedir 'exit 0'
mock stty 'exit 0'
mock stat 'echo tester'
mock osascript 'echo "osascript $*" >> "$T/log"'
mock pgrep 'exit 1'
mock pkill 'exit 1'

# ---- a release: kirki-app.zip with what install.sh looks at ----
mkdir -p "$T/build/kirki.app/Contents/MacOS" "$T/build/kirki.app/Contents/Resources"
printf '#!/bin/sh\n' > "$T/build/kirki.app/Contents/MacOS/kirki"
chmod +x "$T/build/kirki.app/Contents/MacOS/kirki"
cp "$HERE/app/Resources/user-picture.png" "$T/build/kirki.app/Contents/Resources/"
(cd "$T/build" && zip -q -r "$T/release/kirki-app.zip" kirki.app)
(cd "$T/release" && sha256sum kirki-app.zip > kirki-app.zip.sha256)

# ---- install.sh with its paths moved into $T ----
sed -e "s|export PATH=\"|export PATH=\"$T/bin:|" \
    -e "s|/System/Library/CoreServices/SystemVersion.plist|$T&|" \
    -e "s|APP=/Applications/kirki.app|APP=$T/Applications/kirki.app|" \
    -e "s|PICTURES=\"/Library/User Pictures/kirki\"|PICTURES=\"$T/Library/User Pictures/kirki\"|" \
    -e "s|/dev/tty|$T/tty|g" \
    "$HERE/install.sh" > "$T/install.sh"
grep -q "$T/bin" "$T/install.sh" && grep -q "$T/tty" "$T/install.sh" || { echo "couldn't adapt install.sh"; exit 1; }

# run ANSWERS... : runs the adapted install.sh with these keyboard answers; output in $T/out
run() {
  rm -f "$T/tty" "$T/log"
  mkfifo "$T/tty"
  exec 7<>"$T/tty"
  printf '%s\n' "$@" >&7
  # the script arrives through a pipe, as with curl | sh
  sh < "$T/install.sh" > "$T/out" 2>&1
  local rc=$?
  exec 7>&-
  return $rc
}

echo "== fresh install, with the kirki login"
run "" "wrongpw" "adminpw" "kpw" "typo" "kpw" "kpw" "n"
rc=$?
check "[ $rc -eq 0 ]" "exits 0"
check "[ -x '$T/Applications/kirki.app/Contents/MacOS/kirki' ]" "the app is installed"
check "grep -q \"That's not the password\" '$T/out'" "a wrong admin password is asked again"
check "grep -q \"didn't match\" '$T/out'" "mismatched kirki passwords are asked again"
check "grep -q 'sysadminctl -addUser kirki -fullName kirki -password kpw -picture .*kirki.png -adminUser tester -adminPassword adminpw' '$T/log'" "the account is made with a secure token"
agent="$T/Users/kirki/Library/LaunchAgents/io.github.goseahawk.kirki.session.plist"
check "[ -f '$agent' ]" "the launch agent is installed"
check "python3 -c \"import plistlib; d=plistlib.load(open('$agent','rb')); assert d['ProgramArguments'][1]=='--session' and d['RunAtLoad'] and d['KeepAlive']=={'SuccessfulExit': False} and d['LimitLoadToSessionType']=='Aqua'\"" "the agent starts kirki full screen at login, again after a crash"
check "grep -q 'com.apple.SetupAssistant DidSeeCloudSetup -bool true' '$T/log'" "new-account welcome screens are skipped"
check "grep -q 'AppleInterfaceStyle -string Dark' '$T/log'" "the kirki login is dark"
check "[ -f '$T/Library/User Pictures/kirki/kirki.png' ]" "the login picture is in place"
check "grep -q 'offered when the Mac starts' '$T/out'" "FileVault: says the login is offered at startup"
check "grep -q 'choose kirki in the login window' '$T/out'" "says how to start kirki"

echo "== running it again: an update"
run "" "adminpw" "n"
rc=$?
check "[ $rc -eq 0 ]" "exits 0"
check "! grep -q 'sysadminctl -addUser' '$T/log'" "the account isn't made again"
check "grep -q 'updates the kirki app' '$T/out'" "says it's an update"
check "[ -f '$agent' ]" "the launch agent is still there"

echo "== app only (KIRKI_LOGIN=no)"
rm -rf "$T/kirki-account" "$T/Users/kirki"
export KIRKI_LOGIN=no
run "" "adminpw"
rc=$?
unset KIRKI_LOGIN
check "[ $rc -eq 0 ]" "exits 0"
check "! grep -q sysadminctl '$T/log'" "no account"
check "grep -q 'Open kirki from your Applications folder' '$T/out'" "says to open the app"

echo "== uninstall"
run "" "adminpw" "kpw" "kpw" "n" >/dev/null
mkdir -p "$T/me/Library/Application Support/kirki/vm" "$T/me/Library/Logs/kirki" "$T/me/Documents"
export KIRKI_UNINSTALL=yes
HOME="$T/me" run "REMOVE" "adminpw"
rc=$?
unset KIRKI_UNINSTALL
check "[ $rc -eq 0 ]" "exits 0"
check "[ ! -e '$T/me/Library/Application Support/kirki' ] && [ ! -e '$T/me/Library/Logs/kirki' ]" "your own account's copy of kirki is removed"
check "[ -d '$T/me/Documents' ]" "nothing else in your account is touched"
check "grep -q 'sysadminctl -deleteUser kirki' '$T/log'" "the account is deleted"
check "[ ! -e '$T/Applications/kirki.app' ]" "the app is removed"
export KIRKI_UNINSTALL=yes
run "no thanks"
rc=$?
unset KIRKI_UNINSTALL
check "[ $rc -ne 0 ] && grep -q 'Nothing was removed' '$T/out'" "anything but REMOVE removes nothing"

echo "== a damaged download"
echo garbage >> "$T/release/kirki-app.zip"
run "" "adminpw"
rc=$?
check "[ $rc -ne 0 ] && grep -q 'checksum' '$T/out'" "refuses it"
(cd "$T/release" && sha256sum kirki-app.zip > kirki-app.zip.sha256)

echo "== the wrong Mac"
MOCK_ARM64=0 run ""
check "[ $? -ne 0 ] && grep -q 'Intel processor' '$T/out'" "Intel Macs are told kirki needs Apple silicon"
MOCK_MACOS=13.6 run ""
check "[ $? -ne 0 ] && grep -q 'macOS 14' '$T/out'" "macOS 13 is told to update"
MOCK_UID=0 run ""
check "[ $? -ne 0 ] && grep -q 'without sudo' '$T/out'" "running as root is refused"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
