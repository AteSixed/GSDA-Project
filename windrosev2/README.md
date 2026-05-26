# Windrose Container v2

Linux Docker image for the Windrose dedicated server (Steam app `4129620`), using Wine + Xvfb.

Parity target: a **Windows VM on the LAN** with direct IP join (port **3000**, password).

Status note: local Docker/LAN testing is working, but the best network configuration for **internet-facing container hosting** is still being evaluated. In Azure Container Instances, the same public port cannot be exposed for both TCP and UDP, so ACI Windrose deploys are still experimental compared with the working VM baseline.

## Quick start

```powershell
cd windrosev2
copy .env.example .env
docker compose build
docker compose up -d
```

First run downloads the server via SteamCMD (~3 GB).

## Join over LAN (direct IP + password)

This matches a working VM setup: **`UseDirectConnection: true`**, port **3000**, password protected.

Invite-only join often **fails in Docker** (`P2pProxyAddress: 127.0.0.1` + NAT). Use **direct connection** instead.

### 1. Configure `ServerDescription.json` (server stopped)

Stop the container, then edit the file under your instance (default subdir `<instanceSubdir>`, e.g. `windrose-main`):

`serverfiles/R5/ServerDescription.json`

Inside the Docker volume that path is:

`/home/steam/windrose/<SERVER_DATA_SUBDIR>/serverfiles/R5/ServerDescription.json`

Use `ServerDescription.example.json` in this folder as a template. Important fields:

| Field | Value (LAN direct join) |
|-------|-------------------------|
| `UseDirectConnection` | `true` |
| `DirectConnectionServerPort` | `3000` |
| `DirectConnectionProxyAddress` | `0.0.0.0` |
| `IsPasswordProtected` | `true` |
| `Password` | `<serverPass>` |
| `P2pProxyAddress` | `127.0.0.1` (same as working VM; fine when using direct mode) |

Edit only while the server process is **not** running.

Example copy via exec after `docker compose down`:

```powershell
docker run --rm -v windrosev2_windrose_data:/data alpine sh -c "cat /data/windrose-main/serverfiles/R5/ServerDescription.json"
```

Or mount `./data` in compose if you prefer editing on the host (optional).

### 2. Publish port 3000

`docker-compose.yml` maps **TCP and UDP 3000** (override with `DIRECT_CONNECTION_PORT` in `.env`).

Allow **Windows Firewall** inbound TCP/UDP on that port.

### 3. Connect from the game client

- **Mode:** direct IP / direct connection (not invite code).
- **Address:** Docker host LAN IP `<lanIp>` (`ipconfig` → IPv4 on your LAN adapter), **not** `127.0.0.1` from another PC.
- **Port:** `3000` (or `<directConnectionPort>` from `.env`).
- **Password:** `<serverPass>` from `ServerDescription.json`.

Same PC as Docker: try host LAN IP first; `127.0.0.1` only works if the client can reach the published port on localhost.

### Why invite code failed in Docker

Logs showed `Failed to connect to remote` on **UE P2P** while backend registration succeeded. With `UseDirectConnection: false`, clients rely on P2P/ICE; `127.0.0.1` inside the container is not reachable from the host/LAN. Direct mode + published port matches the working VM pattern.

## Data layout

Persistent data: `./data/<SERVER_DATA_SUBDIR>/` (if bind-mounted) or Docker volume `windrose_data`:

- `serverfiles/` — game install + `R5/ServerDescription.json`
- `wineprefix/` — Wine prefix
- `logs/` — `last-run.log`

## Files

- `Dockerfile` — Ubuntu 24.04, WineHQ, SteamCMD
- `entrypoint.sh` — install/update + `wine` + `xvfb-run`
- `docker-compose.yml` — run config, port 3000, volume
- `ServerDescription.example.json` — LAN direct-join template
- `.env.example` — instance subdir, port override

## Logs and Wine noise

By default `WINEDEBUG=-all` so ACI/Docker logs show SteamCMD and Unreal `Log*` lines, not Wine `fixme:` spam. To debug Wine issues, set in `.env` for example `WINEDEBUG=+err` or `WINEDEBUG=+fixme`, then restart the container.

## Useful commands

```powershell
docker compose logs -f windrose
docker compose down
docker compose up --build -d
docker exec windrose tail -f /home/steam/windrose/windrose-main/serverfiles/R5/Saved/Logs/R5.log
```

## Health checks

1. SteamCMD installs app `4129620`.
2. Container stays up (no immediate exit 5).
3. `R5.log` shows `Registered` / server connection info.
4. Client joins via **host LAN IP:3000** + password.

See [`docs/WINDROSE-CONTAINER-SMOKE-TEST.md`](../docs/WINDROSE-CONTAINER-SMOKE-TEST.md) for smoke-test history.
