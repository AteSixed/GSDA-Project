# GSDA — Game Server Deployment Automation

Automate dedicated game servers in two ways: run them locally in Docker, or deploy them to **Azure Container Instances (ACI)** with persistent storage and a public IP.

This repo is the source for container images and the Azure deploy script. Game data, passwords, and your Azure resource names stay on your machine (see [Secrets](#secrets)).

**Repository:** [github.com/AteSixed/GSDA-Project](https://github.com/AteSixed/GSDA-Project)

---

## What it does

| Path | Role |
|------|------|
| **`valheim/`** | Linux Docker image for a Valheim dedicated server. SteamCMD installs/updates the server on start; world data lives in a mounted volume. |
| **`windrosev2/`** | Windrose dedicated server (Steam app 4129620) in Docker with Wine + Xvfb. Smoke-tested locally; see [`windrosev2/README.md`](windrosev2/README.md). |
| **`azure/`** | PowerShell deploy script: build the game image, push to Azure Container Registry (ACR), create an ACI container with Azure Files for saves, expose UDP game port + public IP. |

**Typical flows**

- **Local lab / LAN** — `docker compose` under `valheim/` for quick testing without Azure cost.
- **Internet-facing host** — `deploy-valheim-aci.ps1` builds from `valheim/`, pushes to your ACR, and runs the server in ACI with data on a file share.

The Azure script is game-aware (`valheim` today; `windrose` is configured for when that container is published). Each game’s Dockerfile and options live in its own folder.

---

## Prerequisites

| Use case | You need |
|----------|----------|
| Local Valheim | [Docker](https://docs.docker.com/get-docker/) + Docker Compose |
| Azure deploy | Docker, [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az login`), and Azure resources: resource group, ACR, storage account (file shares), optional Key Vault |

First-time Azure setup (ACR admin user, share layout, versioning) is documented in [`azure/README.md`](azure/README.md).

---

## Quick start

### Local Valheim

```powershell
cd valheim
copy .env.example .env
# Edit .env — set SERVER_PASS (min 5 characters)
docker compose up --build
```

Connect in-game: **Join by IP** → `127.0.0.1` (same PC) or `<lanIp>`. UDP ports **2456–2458**.

More: [`valheim/README.md`](valheim/README.md) (env vars, logs, updates).

### Local Windrose

```powershell
cd windrosev2
copy .env.example .env
docker compose up --build
```

First run downloads the dedicated server via SteamCMD (~3 GB). More: [`windrosev2/README.md`](windrosev2/README.md).

### Valheim on Azure

```powershell
cd azure
copy azure-config.example.json azure-config.json
# Edit azure-config.json — subscription, resource group, ACR, storage, etc.
az login
.\deploy-valheim-aci.ps1 -Game valheim -UserName "<userName>" -ServerName "<serverName>" -WorldName "<worldName>" -ServerPass "<serverPass>"
```

The script prints a **public IP** when finished; join with that IP (port 2456). Instance name defaults to `valheim-<userName>-<timestamp>` unless you pass `-InstanceName`.

### Windrose on Azure

```powershell
cd azure
.\deploy-valheim-aci.ps1 -Game windrose -UserName "<userName>" -ServerName "<serverName>" -ServerPass "<serverPass>"
```

Join with **direct IP** at `<publicIp>` **port 3000** (UDP on ACI) and `<serverPass>` — same model as a direct-connection VM. First start can take a long time while SteamCMD installs inside ACI.

More: [`azure/README.md`](azure/README.md) (Key Vault, image tags, world modifiers, stop/start/logs).

---

## Repository layout

```
├── azure/          Deploy script + config example
├── valheim/        Local Docker server
├── windrosev2/     Windrose Docker server (Wine)
└── docs/           Notes, VM findings, smoke-test results
```

**Not in this repo (local only):** `.env`, `azure/azure-config.json`, `**/data/` game installs, legacy `windrose/` and `windrose.bak/` trees.

---

## How to use (overview)

1. **Pick local or Azure** for the game you care about (Valheim is fully supported in-tree).
2. **Copy the example config** — `.env.example` → `.env` (Valheim) or `azure-config.example.json` → `azure-config.json` (Azure).
3. **Run** — `docker compose` locally, or `deploy-valheim-aci.ps1` for cloud.
4. **Operate** — local: `docker compose logs -f`; Azure: `az container logs` (commands in `azure/README.md`).
5. **Update** — Valheim: restart with `AUTO_UPDATE=1` locally, or redeploy / use `-ImageTag` and `-PinVersion` in Azure to control game version.

---

## Secrets

Never commit:

- `valheim/.env` (server password)
- `azure/azure-config.json` (subscription and resource names)

Use deploy parameters (`-ServerPass`) or Key Vault (`-KeyVaultSecretName`) for passwords in Azure. See each folder’s README for details.

---

## Further reading

| Document | Contents |
|----------|----------|
| [`valheim/README.md`](valheim/README.md) | Environment variables, ports, compose commands |
| [`azure/README.md`](azure/README.md) | ACI sizing, file shares, versioning, Windrose config |
| [`docs/SETUP-AND-STATUS.md`](docs/SETUP-AND-STATUS.md) | Project history and environment notes |
| [`docs/WINDROSE-CONTAINER-SMOKE-TEST.md`](docs/WINDROSE-CONTAINER-SMOKE-TEST.md) | Checklist before adding Windrose to the repo |
