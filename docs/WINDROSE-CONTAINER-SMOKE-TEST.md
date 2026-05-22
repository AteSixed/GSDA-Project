# Windrose container smoke test

Run this before adding `windrosev2/` to the GitHub repo. Initial publish includes only **`azure/`** and **`valheim/`**.

## Prerequisites

- Docker Desktop (or Docker Engine) running on Linux/WSL2 backend
- Enough disk for SteamCMD download (~several GB for app `4129620`)

## Steps

```powershell
cd windrosev2
copy .env.example .env
docker compose build
docker compose up
```

Watch logs for:

1. **SteamCMD** completes without error (`Success! App '4129620' fully installed` or similar).
2. **Executable found** — log line `Executable: .../WindroseServer-Win64-Shipping.exe` (or `WindroseServer.exe`).
3. **Process stays up** — container does not exit immediately with code `5`.
4. **Optional:** `ServerDescription.json` or invite/ready messages in `logs/last-run.log` under the instance data dir (Docker volume `windrose_data` or bind-mounted `./data`).

## Inspect after failure

```powershell
docker compose logs
docker compose run --rm windrose cat /home/steam/windrose/windrose-main/logs/last-run.log
```

## Pass criteria

| Check | Pass |
|-------|------|
| Image builds | `docker compose build` exits 0 |
| Steam install | Server `.exe` present under `serverfiles/` |
| Launch | Exit code 0, or process runs > 2 minutes without immediate crash |

## If the test passes

1. Remove `/windrosev2/` from the root `.gitignore`.
2. `git add windrosev2/`
3. Commit and push.

## Last attempt (automated)

**2026-05-22:** Smoke test not run — Docker daemon was not available (`dockerDesktopLinuxEngine` pipe missing). Start Docker Desktop and re-run this checklist.
