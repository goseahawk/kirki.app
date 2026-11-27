#!/bin/bash
# shellcheck disable=SC2016  # the single-quoted commands run inside the container
# Starts a freshly built kirki container image and checks it works as people will use it:
#     webtop/test-image.sh IMAGE RESULTS_DIR
# It checks that the container starts, Plasma comes up, the web page answers on port 3000 (what
# install.sh opens, at http://localhost), and kirki's branding and theme are in place. Then it opens
# the page in Chromium (Playwright, if it's installed) and saves screenshots: the browser's, and
# Plasma's own (spectacle). Small copies of them go into the log as base64, so they can be seen
# without downloading the run's files.
set -uo pipefail
IMAGE=$1
OUT=$2
NAME=kirki-test
PORT=3000
mkdir -p "$OUT"
problems=()
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
fail() { problems+=("$*"); log "PROBLEM: $*"; }
in_kirki() { docker exec "$NAME" "$@"; }
as_abc() { docker exec -u abc "$NAME" "$@"; }

docker rm -f "$NAME" >/dev/null 2>&1
log "Starting $IMAGE"
docker run -d --name "$NAME" --shm-size=1gb -e PUID=1000 -e PGID=1000 -e TZ=Europe/Berlin \
  -p "127.0.0.1:$PORT:3000" "$IMAGE" >/dev/null || { echo "The container didn't start."; exit 1; }

log "Waiting for Plasma (up to 5 minutes)"
up=no
for _ in $(seq 100); do
  if in_kirki pgrep -x plasmashell >/dev/null 2>&1; then up=yes; break; fi
  if [[ $(docker inspect -f '{{.State.Running}}' "$NAME") != true ]]; then break; fi
  sleep 3
done
if [[ $up == yes ]]; then log "plasmashell is running"; else fail "Plasma (plasmashell) didn't start"; fi

code=$(curl -s -o "$OUT/page.html" -w '%{http_code}' --max-time 20 "http://127.0.0.1:$PORT/")
log "web page: HTTP $code"
[[ $code == 200 ]] || fail "the web page didn't answer (HTTP $code)"

os=$(in_kirki sh -c '. /usr/lib/os-release; echo "$PRETTY_NAME"')
log "os-release: $os"
[[ $os == kirki* ]] || fail "os-release says '$os', not kirki"
theme=$(as_abc kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
log "Global Theme default: $theme"
[[ $theme == org.kirkus.splash ]] || fail "the default Global Theme is '$theme', not kirki's (org.kirkus.splash)"
in_kirki test -x /usr/local/bin/kirk-set-theme || fail "kirki's theme script is missing"
in_kirki sh -c 'fc-list | grep -q "DM Sans"' || fail "kirki's font (DM Sans) isn't installed"
in_kirki sh -c 'command -v fastfetch && fastfetch --pipe -l none 2>&1 | head -12' || true

# give the desktop time to finish starting (the login scripts put the account on the kirki theme)
sleep 45

# Plasma's own screenshot, with the session's environment
if [[ $up == yes ]]; then
  env=$(in_kirki sh -c 'p=$(pgrep -xo plasmashell) && tr "\0" "\n" < /proc/$p/environ' |
        grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_CONFIG_DIRS|DISPLAY)=' |
        sed 's/^/-e /' | tr '\n' ' ')
  # shellcheck disable=SC2086
  if docker exec -u abc $env "$NAME" timeout 60 spectacle -b -n -f -o /tmp/plasma.png >/dev/null 2>&1 &&
     docker cp "$NAME:/tmp/plasma.png" "$OUT/plasma.png" >/dev/null 2>&1; then
    log "Plasma screenshot saved"
  else
    log "(couldn't take Plasma's own screenshot)"
  fi
  colours=$(as_abc kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null)
  log "account's colour scheme: ${colours:-(default)}"
fi

# the page in a browser, as people see it
if python3 -c 'import playwright' 2>/dev/null; then
  python3 - "$PORT" "$OUT" <<'PY' || log "(the browser screenshot failed)"
import sys, time
from playwright.sync_api import sync_playwright
port, out = sys.argv[1], sys.argv[2]
with sync_playwright() as p:
    b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
    page = b.new_page(viewport={"width": 1600, "height": 1000})
    page.goto(f"http://127.0.0.1:{port}/", wait_until="load", timeout=60000)
    page.wait_for_timeout(30000)
    page.screenshot(path=f"{out}/browser.png")
    # a while later: has everything caught up with the window's size?
    page.wait_for_timeout(45000)
    page.screenshot(path=f"{out}/browser-later.png")
    print("browser title:", page.title())
    b.close()
PY
fi

for f in browser browser-later plasma; do
  [[ -f $OUT/$f.png ]] || continue
  if python3 -c 'import PIL' 2>/dev/null; then
    python3 - "$OUT/$f.png" <<'PY'
import base64, io, sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("RGB")
print(f"{sys.argv[1]}: {im.size}, mean colour {tuple(round(c) for c in ImageStat.Stat(im).mean)}")
im.thumbnail((640, 640))
buf = io.BytesIO(); im.save(buf, "JPEG", quality=60)
print("---- base64 jpeg ----"); print(base64.b64encode(buf.getvalue()).decode()); print("---- end ----")
PY
  fi
done

if [[ $up == yes ]] && ! in_kirki pgrep -x plasmashell >/dev/null 2>&1; then
  fail "Plasma (plasmashell) started, then stopped"
fi
in_kirki pgrep -x kwin_wayland >/dev/null 2>&1 || fail "KWin (kwin_wayland) isn't running"
docker logs "$NAME" > "$OUT/container.log" 2>&1
if ((${#problems[@]})); then
  echo "---- processes ----"; in_kirki ps -eo user,pid,etime,args | cut -c1-160 | head -60
  echo "---- container log (last 120 lines, repeats left out) ----"
  uniq -c -f 1 "$OUT/container.log" | tail -n 120
  docker rm -f "$NAME" >/dev/null
  log "FAILED:"; printf '  %s\n' "${problems[@]}"
  exit 1
fi
docker rm -f "$NAME" >/dev/null
log "All checks passed."
