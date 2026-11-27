#!/bin/sh
# Removes kirki from this Mac completely, to start again from scratch: the kirki app, the kirki login
# with kirki and everything in it, and your own account's copy of kirki. Run it in macOS's Terminal:
#
#     curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/uninstall.sh | sh
#
# or, in a copy of this repository: sh uninstall.sh
# It's install.sh's uninstall (KIRKI_UNINSTALL=yes): this one next to it if there is one, otherwise
# the newest release's.
here=$(dirname "$0")
if [ -f "$here/install.sh" ] && [ "$(basename "$0")" = uninstall.sh ]; then
    KIRKI_UNINSTALL=yes exec sh "$here/install.sh"
fi
curl -fsSL https://github.com/goseahawk/kirki.app/releases/latest/download/install.sh | KIRKI_UNINSTALL=yes sh
