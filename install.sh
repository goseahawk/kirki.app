#!/bin/sh
# Installs kirki on a Mac with Apple silicon (M1 or later). Run it in macOS's Terminal:
#
#     curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/install.sh | sh
#
# It installs the kirki app in /Applications, and adds a "kirki" login to the Mac: an account of its
# own, shown in the login window next to yours. Log in to it and you're in kirki's desktop, full
# screen, as if you'd started another system; shut kirki down and you're back at the login window.
# macOS keeps running underneath, so Wi-Fi, sound, Bluetooth, sleep and the battery just work.
# kirki itself (about 2 GB) is downloaded the first time you log in to it.
#
# Options (as environment variables, since the script arrives through a pipe):
#   KIRKI_LOGIN=no       only install (or update) the app; no kirki login. The app then runs kirki
#                        in a window, in your own account.
#   KIRKI_UNINSTALL=yes  remove the kirki login (and kirki with everything in it) and the app
#   KIRKI_APP_ZIP=FILE   install this kirki-app.zip instead of downloading the newest (for testing)
#   KIRKI_RELEASE=URL    where to download from (default: the newest release on GitHub)
#
# Running it again updates the app and keeps the kirki login and everything in it.

# "A && B || die" below means: stop unless every step worked.
# shellcheck disable=SC2015

# Truncation guard: nothing runs unless the whole script arrived (main is called on the last line)
main() {
    set -u
    REPO=goseahawk/kirki.app
    RELEASE=${KIRKI_RELEASE:-https://github.com/$REPO/releases/latest/download}
    APP=/Applications/kirki.app
    ACCOUNT=kirki
    LABEL=io.github.goseahawk.kirki.session
    PICTURES="/Library/User Pictures/kirki"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec"
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

    checks
    TMP=$(mktemp -d /tmp/kirki-install.XXXXXX) || die "Couldn't make a temporary folder."
    trap 'stty echo < /dev/tty 2>/dev/null; rm -rf "$TMP"; kill "$KEEPALIVE" 2>/dev/null' EXIT
    trap 'exit 130' INT TERM
    KEEPALIVE=

    if [ "${KIRKI_UNINSTALL:-}" = yes ]; then
        uninstall
        return
    fi

    echo
    echo "kirki for Mac"
    echo
    if [ "${KIRKI_LOGIN:-yes}" = no ]; then
        echo "This installs the kirki app in your Applications folder."
    elif account_exists; then
        echo "This updates the kirki app. The kirki login and everything in it stay as they are."
    else
        echo "This installs the kirki app, and adds a \"kirki\" login to this Mac: choose it in the login"
        echo "window and you're in kirki's desktop. Your own account and files aren't changed."
    fi
    echo
    ask "Press Return to continue, or Control-C to stop. "

    admin_password
    install_app
    if [ "${KIRKI_LOGIN:-yes}" != no ]; then
        setup_login
    fi
    finish_message
}

say() { printf '%s\n' "$*"; }
die() { printf '\n%s\n' "$*" >&2; exit 1; }

# ask PROMPT: prints PROMPT and reads a line from the keyboard into REPLY (the script itself comes
# through a pipe, so the answer comes from the terminal)
ask() {
    printf '%s' "$1" > /dev/tty
    IFS= read -r REPLY < /dev/tty || die "Stopped."
}

# ask_secret PROMPT: the same, without showing what's typed
ask_secret() {
    printf '%s' "$1" > /dev/tty
    stty -echo < /dev/tty
    IFS= read -r REPLY < /dev/tty || { stty echo < /dev/tty; die "Stopped."; }
    stty echo < /dev/tty
    printf '\n' > /dev/tty
}

checks() {
    [ "$(uname -s)" = Darwin ] && [ -e /System/Library/CoreServices/SystemVersion.plist ] \
        || die "This runs in macOS's Terminal, on a Mac with Apple silicon (M1 or later)."
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] \
        || die "kirki needs a Mac with Apple silicon (M1 or later). This Mac has an Intel processor."
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "${major:-0}" -ge 14 ] 2>/dev/null \
        || die "kirki needs macOS 14 Sonoma or later, and this Mac has $(sw_vers -productVersion). Update macOS first."
    [ "$(id -u)" -ne 0 ] || die "Run this as yourself, without sudo: it asks for your password when it needs it."
    case " $(id -Gn) " in
        *" admin "*) ;;
        *) die "Installing kirki needs an administrator account. Log in as one and run this again." ;;
    esac
    curl --no-progress-meter file:/// >/dev/null 2>&1 \
        || die "Your version of curl is too old, which usually means macOS is out of date. Update macOS first."
}

account_exists() { dscl . -read "/Users/$ACCOUNT" UniqueID >/dev/null 2>&1; }

account_home() { dscl . -read "/Users/$ACCOUNT" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: *//p'; }

# Your password: for sudo, and (once) so the kirki login can unlock a FileVault-encrypted disk.
admin_password() {
    ME=$(id -un)
    while :; do
        ask_secret "Your Mac password (for $ME): "
        ADMIN_PW=$REPLY
        if dscl . -authonly "$ME" "$ADMIN_PW" >/dev/null 2>&1; then break; fi
        say "That's not the password for $ME. Try again."
    done
    printf '%s\n' "$ADMIN_PW" | sudo -S -v -p '' 2>/dev/null || die "sudo didn't accept the password."
    # keep sudo's permission until the script ends
    ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 30; done ) &
    KEEPALIVE=$!
}

install_app() {
    say ""
    say "Installing the kirki app..."
    zip=$TMP/kirki-app.zip
    if [ -n "${KIRKI_APP_ZIP:-}" ]; then
        cp "$KIRKI_APP_ZIP" "$zip" || die "Couldn't read $KIRKI_APP_ZIP."
    else
        curl -fL --retry 3 --no-progress-meter -o "$zip" "$RELEASE/kirki-app.zip" \
          && curl -fsSL --retry 3 -o "$zip.sha256" "$RELEASE/kirki-app.zip.sha256" \
          || die "Couldn't download kirki from GitHub. Check the internet connection (GitHub may be blocked on this network) and try again."
        want=$(cut -d' ' -f1 < "$zip.sha256")
        got=$(shasum -a 256 "$zip" | cut -d' ' -f1)
        [ -n "$want" ] && [ "$want" = "$got" ] || die "The download is damaged (its checksum doesn't match). Run the same command again."
    fi
    mkdir -p "$TMP/app"
    ditto -x -k "$zip" "$TMP/app" || die "The app download is damaged. Run the same command again."
    [ -x "$TMP/app/kirki.app/Contents/MacOS/kirki" ] || die "That download doesn't have the kirki app in it."
    codesign --verify --strict "$TMP/app/kirki.app" 2>/dev/null || die "The kirki app's signature doesn't check out; nothing was installed."
    if pgrep -x kirki >/dev/null 2>&1; then
        say "  (kirki is running; it uses the new version the next time it starts)"
    fi
    sudo rm -rf "$APP" && sudo ditto "$TMP/app/kirki.app" "$APP" && sudo chown -R root:wheel "$APP" \
        || die "Couldn't install the app in $APP."
    # Downloaded with curl, so macOS hasn't marked it as "from the internet"; make sure of that.
    sudo xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    say "  $APP: version $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
}

setup_login() {
    say ""
    if account_exists; then
        say "Updating the kirki login..."
    else
        say "Adding the kirki login to this Mac."
        say "Choose a password for it: you type it in the login window, like for any account. (Inside kirki,"
        say "you choose your own account and password the first time it starts.)"
        while :; do
            ask_secret "Password for the kirki login: "
            KPW=$REPLY
            [ -n "$KPW" ] || { say "It can't be empty."; continue; }
            ask_secret "The same password again: "
            [ "$REPLY" = "$KPW" ] && break
            say "Those didn't match. Try again."
        done
        sudo mkdir -p "$PICTURES"
        sudo cp "$APP/Contents/Resources/user-picture.png" "$PICTURES/kirki.png"
        sudo chmod 644 "$PICTURES/kirki.png"
        # With your credentials, the new account gets a secure token: it can unlock a FileVault disk,
        # so it's offered when the Mac starts, next to your account.
        sudo sysadminctl -addUser "$ACCOUNT" -fullName "kirki" -password "$KPW" -picture "$PICTURES/kirki.png" \
            -adminUser "$ME" -adminPassword "$ADMIN_PW" >/dev/null 2>&1
        account_exists || die "macOS didn't create the kirki login. Nothing else was changed; try again, or add it in System Settings > Users & Groups."
        KPW=
        say "  Added the kirki login."
    fi

    home=$(account_home)
    [ -n "$home" ] || die "The kirki login has no home folder."
    [ -d "$home" ] || sudo createhomedir -c -u "$ACCOUNT" >/dev/null 2>&1 || true
    [ -d "$home" ] || die "Couldn't make the kirki login's home folder ($home)."
    uid=$(id -u "$ACCOUNT")

    # The login picture, also for an account made before
    if [ -f "$PICTURES/kirki.png" ] || sudo cp "$APP/Contents/Resources/user-picture.png" "$PICTURES/kirki.png" 2>/dev/null; then
        sudo dscl . -create "/Users/$ACCOUNT" Picture "$PICTURES/kirki.png" 2>/dev/null || true
    fi

    # At login, start kirki full screen (--session); start it again if it ever crashes.
    agents=$home/Library/LaunchAgents
    sudo install -d -o "$uid" -g staff -m 755 "$home/Library" "$agents"
    cat > "$TMP/agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/kirki</string>
		<string>--session</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>ThrottleInterval</key>
	<integer>5</integer>
</dict>
</plist>
EOF
    plutil -lint "$TMP/agent.plist" >/dev/null || die "The kirki login's start-up file is malformed."
    sudo install -o "$uid" -g staff -m 644 "$TMP/agent.plist" "$agents/$LABEL.plist"

    # The kirki login's Mac side: dark, quiet, no welcome screens for a new account.
    prefs=$home/Library/Preferences
    sudo install -d -o "$uid" -g staff -m 700 "$prefs"
    product=$(sw_vers -productVersion)
    build=$(sw_vers -buildVersion)
    sa=$prefs/com.apple.SetupAssistant
    for key in DidSeeAccessibility DidSeeActivationLock DidSeeAppearanceSetup DidSeeApplePaySetup \
               DidSeeAvatarSetup DidSeeCloudSetup DidSeeiCloudLoginForStorageServices DidSeeIntelligence \
               DidSeeLockdownMode DidSeePrivacy DidSeeScreenTime DidSeeSiriSetup DidSeeSyncSetup \
               DidSeeSyncSetup2 DidSeeTermsOfAddress DidSeeTouchIDSetup DidSeeTrueTonePrivacy \
               DidSeeWallpaperSetup DidSeeAgeRange SkipFirstLoginOptimization; do
        sudo defaults write "$sa" "$key" -bool true
    done
    for key in LastSeenCloudProductVersion LastSeenDiagnosticsProductVersion LastSeenSiriProductVersion \
               LastSeenAppleIntelligenceProductVersion; do
        sudo defaults write "$sa" "$key" -string "$product"
    done
    sudo defaults write "$sa" LastSeenBuddyBuildVersion -string "$build"
    sudo defaults write "$prefs/.GlobalPreferences" AppleInterfaceStyle -string Dark
    sudo defaults write "$prefs/com.apple.dock" autohide -bool true
    sudo defaults write "$prefs/com.apple.dock" autohide-delay -float 1000
    sudo defaults write "$prefs/com.apple.dock" show-recents -bool false
    sudo defaults write "$prefs/com.apple.dock" persistent-apps -array
    sudo defaults write "$prefs/com.apple.finder" CreateDesktop -bool false
    sudo chown -R "$uid:staff" "$prefs"

    if [ "$(fdesetup status 2>/dev/null)" = "FileVault is On." ]; then
        if sysadminctl -secureTokenStatus "$ACCOUNT" 2>&1 | grep -q ENABLED; then
            say "  FileVault is on: the kirki login is offered when the Mac starts."
        else
            say "  FileVault is on, but the kirki login can't unlock the disk yet: start the Mac with your"
            say "  own account, then log out and choose kirki."
        fi
    fi
}

finish_message() {
    say ""
    say "kirki is installed."
    say ""
    if [ "${KIRKI_LOGIN:-yes}" = no ]; then
        say "Open kirki from your Applications folder. The first time, it downloads kirki (about 2 GB)."
        return
    fi
    say "To start kirki: Apple menu > Log Out, then choose kirki in the login window."
    say "  - The first time, kirki downloads itself (about 2 GB), then asks for your language, keyboard"
    say "    and account, the way a new computer does."
    say "  - When you shut kirki down, you're back at the login window, where you can choose macOS."
    say "  - With Fast User Switching (Control Center), you can switch between macOS and kirki in seconds."
    say "  - Settings: move the pointer to the top of the screen and choose kirki > Settings, or press"
    say "    Control-Option-Command-K."
    ask "Log out now? (y/N) "
    case $REPLY in
        [yY]*) osascript -e 'tell application "System Events" to log out' >/dev/null 2>&1 \
                 || say "Choose Log Out from the Apple menu." ;;
    esac
}

uninstall() {
    say ""
    say "This removes the kirki app and the kirki login, with kirki and everything in it: its files,"
    say "apps and settings. (If you also ran kirki in a window in other accounts, their copies stay;"
    say "remove ~/Library/Application Support/kirki in those accounts to delete them.)"
    ask "Type REMOVE to go ahead: "
    [ "$REPLY" = REMOVE ] || die "Nothing was removed."
    admin_password
    if account_exists; then
        if [ "$(stat -f %Su /dev/console 2>/dev/null)" = "$ACCOUNT" ]; then
            die "The kirki login is in use. Log out of it first, then run this again."
        fi
        sudo sysadminctl -deleteUser "$ACCOUNT" -adminUser "$ME" -adminPassword "$ADMIN_PW" >/dev/null 2>&1 \
            || sudo sysadminctl -deleteUser "$ACCOUNT" >/dev/null 2>&1
        account_exists && die "macOS didn't remove the kirki login. Remove it in System Settings > Users & Groups."
        say "Removed the kirki login."
    fi
    sudo rm -rf "$APP" "$PICTURES"
    say "Removed the kirki app. kirki is uninstalled."
}

main "$@"
