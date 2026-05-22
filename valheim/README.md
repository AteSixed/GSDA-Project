# Valheim Dedicated Server (Docker)

Run a Valheim dedicated server in a Linux container. Works with Docker Desktop on Windows and on Linux hosts.

## Prerequisites

- Docker and Docker Compose
- **SERVER_PASS** must be set (min 5 characters)

## Quick start

1. **Copy env template and set your password**
   ```bash
   copy .env.example .env
   ```
   Edit `.env` and set `SERVER_PASS` (and optionally `SERVER_NAME`, `WORLD_NAME`).

2. **Build the image**
   ```bash
   docker compose build
   ```
   First build downloads SteamCMD and the Valheim server (~1–2 GB); it can take several minutes.

3. **Start the server**
   ```bash
   docker compose up -d
   ```
   First run may take a few minutes while the server is installed into the `./data` folder.

4. **Connect**
   - Same PC: In Valheim, Join Game → Join by IP → `127.0.0.1` or `localhost`
   - LAN: Use this machine’s local IP (e.g. `192.168.1.x`) and ensure UDP ports 2456–2458 are allowed in Windows Firewall if needed.

## Data and ports

- **Data:** World and server files are stored in `./data`. You can back up or browse this folder while the container is stopped.
- **Ports:** UDP 2456 (game), 2457, 2458. Ensure they are not in use by another app.

## Commands

- **Logs:** `docker compose logs -f valheim`
- **Stop:** `docker compose down`
- **Restart:** `docker compose restart valheim`

## Environment

| Variable     | Default           | Description                          |
|-------------|-------------------|--------------------------------------|
| SERVER_NAME | Valheim Server    | Name shown in the server list        |
| WORLD_NAME  | Dedicated         | World/save name                      |
| SERVER_PASS | (required)        | Server password (min 5 characters)   |
| PORT        | 2456              | Game port                            |
| PUBLIC      | 1                 | 1 = listed in browser, 0 = private   |
| AUTO_UPDATE | 1                 | 1 = update server on start if needed |

## Updates

When Valheim releases a game update, restart the container with `AUTO_UPDATE=1` (default) so SteamCMD can update the server on next start.
