# Windrose Container v2

Fresh baseline for running Windrose dedicated server (`4129620`) in Linux Docker.

This is intentionally minimal and benchmark-oriented, using your working Windows VM as the parity target.

## Files

- `Dockerfile`: Ubuntu + SteamCMD + WineHQ + GE-Proton
- `entrypoint.sh`: install/update + launch with Proton or Wine
- `docker-compose.yml`: local run config and persistent data mount
- `.env.example`: runtime toggles for A/B testing

## Quick start

```powershell
cd windrosev2
copy .env.example .env
docker compose build
docker compose up
```

## Data layout

Persistent data is under `./data/<SERVER_DATA_SUBDIR>/`:

- `serverfiles/` - Steam app install output
- `protonprefix/` - Proton compatibility data
- `wineprefix/` - Wine prefix (if `RUNTIME_MODE=wine`)
- `logs/` - run logs and captured output

## Windows parity checkpoints

Use these checkpoints to decide if a run is good:

1. Server executable is found after SteamCMD install.
2. Process starts without immediate exit.
3. Dedicated server config/state files are generated.
4. Server reaches ready state (invite/connect info appears).
5. Restart preserves expected state from `./data`.

## Iteration strategy

- Change one variable per run (runtime, prefix location, flags).
- Record each run with:
  - image tag/hash
  - env overrides
  - first error line (or success milestone reached)
  - elapsed time to ready/failure

## Useful commands

```powershell
docker compose logs -f windrose
docker compose down
docker compose up --build
```
