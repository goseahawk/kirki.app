#!/bin/sh
# Removes kirki from this Mac completely, to start again from scratch. Run it in macOS's Terminal:
#
#     curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/uninstall.sh | sh
#
# It removes kirki's container, its Docker volume "kirki-home" (your files and settings in kirki) and
# its image. Docker Desktop itself stays; remove it as any app if nothing else uses it.
# It also removes what the earlier kirki for Mac (a virtual machine) installed, if it's there: the
# kirki app, the "kirki" login with everything in it, and your own account's copy of kirki.

# Truncation guard: nothing runs unless the whole script arrived (main is called on the last line)
main() {
    set -u
    NAME=kirki
    VOLUME=kirki-home
    REPO_IMAGE=ghcr.io/goseahawk/kirki
    ACCOUNT=kirki
    OLD_APP=/Applications/kirki.app
    export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    [ "$(uname -s)" = Darwin ] || die "This is for macOS."
    [ "$(id -u)" -ne 0 ] || die "Run this as yourself, not with sudo."
    say ""
    say "This removes kirki from this Mac completely, with everything in it: your files, apps and"
    say "settings in kirki are deleted. Docker Desktop stays."
    ask "Type REMOVE to go ahead: "
    [ "$REPLY" = REMOVE ] || die "Nothing was removed."

    remove_container
    remove_old_vm
    say ""
    say "kirki is uninstalled. To start again, run the install command:"
    say "    curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/install.sh | sh"
}

say() { printf '%s\n' "$*"; }
die() { printf '\n%s\n' "$*" >&2; exit 1; }
ask() {
    printf '%s' "$1"
    REPLY=
    read -r REPLY < /dev/tty || REPLY=
}

remove_container() {
    if ! command -v docker >/dev/null 2>&1; then
        say "Docker isn't installed: no kirki container to remove."
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        say "Starting Docker Desktop (to remove kirki's container)..."
        open -a Docker 2>/dev/null || true
        n=0
        while ! docker info >/dev/null 2>&1; do
            n=$((n + 1))
            [ $n -le 90 ] || die "Docker Desktop didn't start. Open it, then run this again."
            sleep 2
        done
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 && say "Removed kirki's container."
    docker volume rm "$VOLUME" >/dev/null 2>&1 && say "Removed kirki's files and settings (the volume $VOLUME)."
    images=$(docker images --format '{{.Repository}}:{{.Tag}}@{{.ID}}' | sed -n "s|^$REPO_IMAGE:[^@]*@||p" | sort -u)
    if [ -n "$images" ]; then
        # shellcheck disable=SC2086
        docker rmi -f $images >/dev/null 2>&1 && say "Removed kirki's image."
    fi
    return 0
}

account_exists() { dscl . -read "/Users/$ACCOUNT" UniqueID >/dev/null 2>&1; }

# The earlier kirki for Mac: an app that ran kirki in a virtual machine, and a "kirki" login
remove_old_vm() {
    old_data="$HOME/Library/Application Support/kirki"
    if ! account_exists && [ ! -e "$OLD_APP" ] && [ ! -e "$old_data" ]; then
        return 0
    fi
    say ""
    say "Removing the earlier kirki for Mac (the virtual machine). This asks for your Mac password."
    if account_exists; then
        if [ "$(stat -f %Su /dev/console 2>/dev/null)" = "$ACCOUNT" ]; then
            die "The kirki login is in use. Log out of it first, then run this again."
        fi
        home=$(dscl . -read "/Users/$ACCOUNT" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: *//p')
        sudo sysadminctl -deleteUser "$ACCOUNT" >/dev/null 2>&1 || true
        account_exists && die "macOS didn't remove the kirki login. Remove it in System Settings > Users & Groups, then run this again."
        case $home in
            /Users/"$ACCOUNT") [ -d "$home" ] && sudo rm -rf "$home" ;;
        esac
        say "Removed the kirki login."
    fi
    if pgrep -xu "$(id -u)" kirki >/dev/null 2>&1; then
        say "Shutting down the kirki app..."
        osascript -e 'tell application id "io.github.goseahawk.kirki" to quit' >/dev/null 2>&1 || true
        n=0
        while pgrep -xu "$(id -u)" kirki >/dev/null 2>&1 && [ $n -lt 60 ]; do sleep 1; n=$((n + 1)); done
        pkill -9 -xu "$(id -u)" kirki 2>/dev/null || true
    fi
    rm -rf "$old_data" "$HOME/Library/Logs/kirki" "$HOME/Library/Caches/io.github.goseahawk.kirki" \
        "$HOME/Library/Saved Application State/io.github.goseahawk.kirki.savedState"
    defaults delete io.github.goseahawk.kirki >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/io.github.goseahawk.kirki.plist"
    if [ -e "$OLD_APP" ] || [ -e "/Library/User Pictures/kirki" ]; then
        sudo rm -rf "$OLD_APP" "/Library/User Pictures/kirki"
    fi
    say "Removed the earlier kirki app and its files."
}

main "$@"
