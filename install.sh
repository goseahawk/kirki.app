#!/bin/sh
# Installs kirki on a Mac: kirki's KDE Plasma desktop, in a container, shown in your web browser.
# Run it in macOS's Terminal:
#
#     curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/install.sh | sh
#
# kirki runs with Docker Desktop (it's installed first if it isn't there; free for personal use).
# The container starts again whenever Docker Desktop does, and kirki is at http://localhost:3010 in
# Safari, Chrome or Firefox. Only this Mac can open it.
#
# Options (as environment variables, since the script arrives through a pipe):
#   KIRKI_PORT=N     the port on this Mac (default 3010): kirki is at http://localhost:N
#   KIRKI_IMAGE=REF  the container image (default ghcr.io/goseahawk/kirki:latest)
#
# Running it again updates kirki to the newest version. Your files and settings in kirki are kept
# (they're in the Docker volume "kirki-home"); the rest of kirki's system is replaced.

# Truncation guard: nothing runs unless the whole script arrived (main is called on the last line)
main() {
    set -u
    IMAGE=${KIRKI_IMAGE:-ghcr.io/goseahawk/kirki:latest}
    PORT=${KIRKI_PORT:-3010}
    NAME=kirki
    VOLUME=kirki-home
    URL="http://localhost:$PORT"
    export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    checks
    echo
    echo "kirki for Mac"
    echo
    echo "This sets up kirki's desktop on this Mac, in a container run by Docker Desktop, and opens it"
    echo "in your web browser. Your Mac's own files and settings aren't changed."
    echo
    ask "Press Return to continue, or Control-C to stop. "

    need_docker
    start_docker
    run_kirki
    open_kirki
}

say() { printf '%s\n' "$*"; }
die() { printf '\n%s\n' "$*" >&2; exit 1; }

# ask PROMPT: prints PROMPT and reads a line from the keyboard into REPLY (the script itself comes
# through a pipe, so answers are read from the terminal)
ask() {
    printf '%s' "$1"
    REPLY=
    read -r REPLY < /dev/tty || REPLY=
}

checks() {
    [ "$(uname -s)" = Darwin ] || die "This is for macOS. On Linux, run the image with Docker: see github.com/goseahawk/kirki.app"
    [ "$(id -u)" -ne 0 ] || die "Run this as yourself, not with sudo."
    case $PORT in
        ''|*[!0-9]*) die "KIRKI_PORT must be a number, got '$PORT'." ;;
    esac
}

have_docker() { command -v docker >/dev/null 2>&1; }

# Docker Desktop: installed with Homebrew if there is Homebrew, otherwise from docker.com by hand
need_docker() {
    have_docker && return 0
    say ""
    say "kirki needs Docker Desktop, which isn't installed."
    if command -v brew >/dev/null 2>&1; then
        ask "Install it now with Homebrew? (Y/n) "
        case $REPLY in
            [nN]*) ;;
            *)
                brew install --cask docker-desktop || brew install --cask docker \
                    || die "Homebrew couldn't install Docker Desktop."
                have_docker && return 0
                ;;
        esac
    fi
    say ""
    say "Download Docker Desktop for Mac from https://www.docker.com/products/docker-desktop/"
    say "(choose \"Apple silicon\" or \"Intel chip\", to match this Mac), install it, open it once and"
    say "accept its terms. Then run the kirki install command again."
    open "https://www.docker.com/products/docker-desktop/" 2>/dev/null || true
    exit 1
}

# Docker Desktop has to be running (it can take a minute to start)
start_docker() {
    docker info >/dev/null 2>&1 && return 0
    say "Starting Docker Desktop..."
    open -a Docker 2>/dev/null || open -b com.docker.docker 2>/dev/null || true
    n=0
    while ! docker info >/dev/null 2>&1; do
        n=$((n + 1))
        [ $n -le 90 ] || die "Docker Desktop didn't start. Open it (and accept its terms if it asks), then run this again."
        sleep 2
    done
    say "Docker Desktop is running."
}

# The Mac's time zone, for kirki's clock
mac_timezone() {
    tz=$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')
    case $tz in
        */*) printf '%s' "$tz" ;;
        *) printf 'UTC' ;;
    esac
}

run_kirki() {
    say ""
    say "Downloading kirki (about 2 GB the first time)..."
    docker pull "$IMAGE" || die "Couldn't download kirki ($IMAGE). Check the internet connection and try again."
    if docker container inspect "$NAME" >/dev/null 2>&1; then
        say "Replacing the kirki that's there (your files in kirki are kept)..."
        docker rm -f "$NAME" >/dev/null || die "Couldn't stop the kirki that's running."
    fi
    # Only this Mac can reach it (127.0.0.1): kirki's page has no password, and its terminal can
    # become root in the container. --shm-size: Chromium-based apps and the desktop need it.
    docker run -d --name "$NAME" --restart unless-stopped \
        --shm-size=1gb \
        -e PUID=1000 -e PGID=1000 -e TZ="$(mac_timezone)" -e TITLE=kirki \
        -p "127.0.0.1:$PORT:3000" \
        -v "$VOLUME:/config" \
        "$IMAGE" >/dev/null \
        || die "kirki didn't start. If port $PORT is in use, run this again with KIRKI_PORT=3011 (say) in front of sh."
    # no longer used images (an older kirki) take a lot of room
    docker image prune -f --filter "label=org.opencontainers.image.title=kirki" >/dev/null 2>&1 || true
}

open_kirki() {
    say "Starting kirki's desktop..."
    n=0
    while [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL/" 2>/dev/null)" != 200 ]; do
        n=$((n + 1))
        [ $n -le 60 ] || die "kirki started but its page doesn't answer yet. Try $URL in a minute."
        sleep 2
    done
    open "$URL" 2>/dev/null || true
    say ""
    say "kirki is ready: $URL"
    say ""
    say "- Bookmark it, or add it to the Dock (Safari: File > Add to Dock) to open kirki like an app."
    say "- kirki keeps running while Docker Desktop does. To have it ready after a restart, turn on"
    say "  \"Start Docker Desktop when you sign in\" in Docker Desktop's settings."
    say "- To update kirki, run the install command again. To remove it, run:"
    say "    curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/uninstall.sh | sh"
}

main "$@"
