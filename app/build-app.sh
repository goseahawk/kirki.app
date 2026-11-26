#!/bin/bash
# Builds kirki.app, the kirki Mac app, on a Mac with Xcode or its command line tools (Swift 5.9+):
#
#     app/build-app.sh
#
# Settings (environment):
#   KIRK_VERSION         the version, YY.MM.DD (default: today's date)
#   KIRK_SIGN_IDENTITY   a "Developer ID Application" certificate in the keychain: signs the app with
#                        it and the hardened runtime, ready for notarizing. Without one the app is
#                        signed ad hoc, which runs on Macs where it's installed with install.sh.
#
# Output, in out/:
#   kirki.app                the app
#   kirki-app.zip (+.sha256) the app zipped, as the release and install.sh have it
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
OUT=$ROOT/out
VERSION=${KIRK_VERSION:-$(date +%y.%m.%d)}
[[ $VERSION =~ ^[0-9]{2}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] || { echo "Bad version '$VERSION': use YY.MM.DD or YY.MM.DD.N"; exit 1; }
[[ $(uname -s) == Darwin ]] || { echo "kirki.app is built on a Mac."; exit 1; }

echo "== Building kirki $VERSION =="
swift build --package-path "$HERE" -c release --arch arm64
BIN=$(swift build --package-path "$HERE" -c release --arch arm64 --show-bin-path)/kirki

APP=$OUT/kirki.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/kirki"
sed "s/@VERSION@/$VERSION/g" "$HERE/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$HERE/Resources/AppIcon.icns" "$HERE/Resources/logo.png" "$HERE/Resources/wallpaper.png" \
   "$HERE/Resources/user-picture.png" "$APP/Contents/Resources/"
cp -R "$HERE/Resources/fonts" "$APP/Contents/Resources/fonts"

echo "== Signing =="
if [[ -n ${KIRK_SIGN_IDENTITY:-} ]]; then
  codesign --force --timestamp --options runtime --entitlements "$HERE/Resources/kirki.entitlements" \
    --sign "$KIRK_SIGN_IDENTITY" "$APP"
else
  # Ad hoc: no certificate. The Virtualization entitlement works with it; Gatekeeper only lets it open
  # without a warning when it wasn't downloaded by a browser (install.sh uses curl, which doesn't mark it).
  codesign --force --entitlements "$HERE/Resources/kirki.entitlements" --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" 2>/dev/null | grep -q com.apple.security.virtualization \
  || { echo "The app is missing its Virtualization entitlement."; exit 1; }

echo "== Packaging =="
rm -f "$OUT/kirki-app.zip" "$OUT/kirki-app.zip.sha256"
(cd "$OUT" && ditto -c -k --keepParent kirki.app kirki-app.zip && shasum -a 256 kirki-app.zip > kirki-app.zip.sha256)
ls -l "$OUT"
echo "Done: $APP"
