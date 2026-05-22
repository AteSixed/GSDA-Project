FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV STEAMAPPID=4129620
ENV SERVER_ROOT=/home/steam/windrose

ARG WINEHQ_PACKAGE=winehq-stable

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && mkdir -pm755 /etc/apt/keyrings \
    && curl -fsSL https://dl.winehq.org/wine-builds/winehq.key | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key \
    && printf '%s\n' \
      'Types: deb' \
      'URIs: https://dl.winehq.org/wine-builds/ubuntu' \
      'Suites: noble' \
      'Components: main' \
      'Architectures: amd64 i386' \
      'Signed-By: /etc/apt/keyrings/winehq-archive.key' \
      > /etc/apt/sources.list.d/winehq-noble.sources \
    && apt-get update \
    && apt-get install -y --install-recommends \
      ${WINEHQ_PACKAGE} \
      fonts-wine \
      lib32gcc-s1 \
      lib32stdc++6 \
      libc6-i386 \
      libegl1 \
      libegl1:i386 \
      libgbm1 \
      mesa-vulkan-drivers \
      procps \
      tini \
      xauth \
      xvfb \
      winbind \
    && rm -rf /var/lib/apt/lists/*

# Keep machine-id stable in minimal containers; Proton/Wine can read this.
RUN cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 32 > /etc/machine-id \
    && echo >> /etc/machine-id

# Xvfb needs this socket directory; create it while still root.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

RUN useradd -m -s /bin/bash steam
USER steam
WORKDIR /home/steam

RUN curl -sSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
    | tar zxvf - -C /home/steam

COPY --chown=steam:steam entrypoint.sh /home/steam/entrypoint.sh
RUN sed -i 's/\r$//' /home/steam/entrypoint.sh && chmod +x /home/steam/entrypoint.sh

ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV SERVER_DATA_SUBDIR=windrose-main
ENV STEAM_UPDATE_ON_START=1
ENV STEAMCMD_FORCE_PLATFORM_WINDOWS=1
ENV XVFB_DISPLAY=:99
ENV XVFB_RUN_SCREEN="-screen 0 1024x768x24"

ENTRYPOINT ["/usr/bin/tini", "--", "/home/steam/entrypoint.sh"]
