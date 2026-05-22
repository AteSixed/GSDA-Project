# Valheim dedicated server in a Linux container
# Uses SteamCMD to install/update the server; game data lives on a mounted volume.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV STEAMAPPID=896660
ENV SERVER_DIR=/home/steam/valheim

# Install dependencies for SteamCMD (32-bit runtime)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        lib32gcc-s1 \
        lib32stdc++6 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Create steam user and install SteamCMD
RUN useradd -m -s /bin/bash steam
USER steam
WORKDIR /home/steam

RUN curl -sSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
    | tar zxvf - -C /home/steam

# Entrypoint will install/update Valheim to SERVER_DIR and start the server
COPY --chown=steam:steam entrypoint.sh /home/steam/entrypoint.sh
RUN sed -i 's/\r$//' /home/steam/entrypoint.sh && chmod +x /home/steam/entrypoint.sh

# Valheim server ports (UDP)
EXPOSE 2456/udp 2457/udp 2458/udp

ENV SERVER_NAME="Valheim Server" \
    WORLD_NAME="Dedicated" \
    SERVER_PASS="" \
    PORT=2456 \
    PUBLIC=1 \
    AUTO_UPDATE=1

ENTRYPOINT ["/home/steam/entrypoint.sh"]
