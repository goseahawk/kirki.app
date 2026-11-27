# syntax=docker/dockerfile:1
# kirki in a container: linuxserver.io's webtop (Arch Linux with KDE Plasma, shown in a web browser)
# with kirki's desktop on top: its theme, wallpaper, fonts, icons, apps and About page.
#
# Built from the repository's top folder, with kirki (github.com/goseahawk/kirki, at the commit in
# webtop/kirki.ref) checked out in kirki/:
#     git clone https://github.com/goseahawk/kirki kirki && git -C kirki checkout "$(cat webtop/kirki.ref)"
#     docker build -f webtop/Dockerfile --build-arg KIRK_VERSION=26.11.27 -t kirki .
ARG BASE=ghcr.io/linuxserver/webtop:arch-kde
FROM ${BASE}

ARG KIRK_VERSION=dev
# the browser tab's title
ENV TITLE=kirki

COPY webtop/root/ /
COPY kirki/overlay/installed /tmp/kirki-overlay
COPY webtop/setup.sh /tmp/kirki-setup.sh
RUN bash /tmp/kirki-setup.sh "$KIRK_VERSION" && rm -rf /tmp/kirki-overlay /tmp/kirki-setup.sh

LABEL org.opencontainers.image.title="kirki" \
      org.opencontainers.image.description="kirki's KDE Plasma desktop in your web browser" \
      org.opencontainers.image.source="https://github.com/goseahawk/kirki.app" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${KIRK_VERSION}"
