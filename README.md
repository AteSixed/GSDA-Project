# Game Server Automation

Docker images and Azure deployment scripts for dedicated game servers.

## Repository layout

| Directory | Purpose |
|-----------|---------|
| **`azure/`** | Deploy game server images to Azure Container Instances (ACI). Copy `azure-config.example.json` to `azure-config.json` locally. |
| **`valheim/`** | Local Valheim dedicated server (Docker + SteamCMD). |
| **`docs/`** | Setup notes, Windrose VM findings, and smoke-test checklist. |

**Not in the initial GitHub tree:** `windrosev2/` (until [smoke test](docs/WINDROSE-CONTAINER-SMOKE-TEST.md) passes), legacy `windrose/`, `windrose.bak/`, and any `data/` directories.

## Quick start

### Valheim (local)

```powershell
cd valheim
copy .env.example .env
# Edit .env: set SERVER_PASS (min 5 characters)
docker compose up --build
```

### Valheim or Windrose (Azure)

```powershell
cd azure
copy azure-config.example.json azure-config.json
# Edit azure-config.json with your subscription and resource names
az login
.\deploy-valheim-aci.ps1 -Game valheim -UserName you -ServerName "My Server" -WorldName Dedicated -ServerPass "YourPasswordMin5"
```

See `azure/README.md` and `valheim/README.md` for full options.

## Secrets

- Do not commit `.env` or `azure/azure-config.json`.
- Game passwords and Key Vault values belong in `.env`, deploy parameters, or Key Vault only.
