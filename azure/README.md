# Azure automation (Valheim & game servers)

This folder holds config and automation for deploying game servers (e.g. Valheim) to Azure Container Instances (ACI).

## Config

Copy the example config and fill in your Azure resource names:

```powershell
copy azure-config.example.json azure-config.json
```

**`azure-config.json`** – Local only (gitignored). Resource names and settings (resource group, region, ACR, storage, Key Vault, ACI size). Do not put secrets here; use script parameters or Key Vault.

**`azure-config.example.json`** – Committed template with placeholders.

**ACI size** – Default is 2 CPU, 4 GB memory (good for small Valheim servers). Adjust `aci.cpu` and `aci.memoryInGb` in config if needed.

---

## First-time deployment (game server to ACI)

### Prerequisites

- **Azure CLI** (`az`) – [Install](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli). Log in with `az login` and ensure the correct subscription is selected.
- **Docker** – So the script can build and push the Valheim image to ACR.
- **Config** – `azure-config.json` must have ACR, storage, and (optional) Key Vault filled in.
- **ACR admin user** – So ACI can pull the image. If you get "enable admin first", run:  
  `az acr update -n <acrName> --admin-enabled true`

### Deploy one game server

From the repository root, change into **`azure`** and run the script:

```powershell
cd azure
.\deploy-valheim-aci.ps1 -Game "valheim" -UserName "<userName>" -ServerName "<serverName>" -WorldName "<worldName>" -ServerPass "<serverPass>"
```

- **Game** – `valheim` or `windrose`.
- **UserName** – Used to auto-generate `InstanceName` as `<game>-<userName>-<yyyyMMdd-HHmm>` (with numeric suffix if needed for uniqueness).
- **ServerName** – Name shown in the server list.
- **WorldName** – World/save name (required for Valheim).
- **ServerPass** – Server password (min 5 characters, required for Valheim). Use `-ServerPass` or Key Vault (see below).

Optional:

- **-InstanceName** – Optional override for container group/data folder name. If omitted, script auto-generates one from game + username + timestamp.
- **-ImageTag** – Deploy using this image tag (default: from config `acr.defaultImageTag` or `latest`). Use to pin or roll back to a specific version.
- **-CombatModifier** – World combat modifier (e.g. `easy`, `hard`, `veryhard`).
- **-DeathPenaltyModifier** – Death penalty modifier (e.g. `casual`, `easy`, `hardcore`).
- **-ResourcesModifier** – Resource rate modifier (e.g. `less`, `more`, `most`).
- **-RaidsModifier** – Raid frequency modifier (e.g. `none`, `less`, `more`).
- **-PortalsModifier** – Portal restriction modifier (e.g. `casual`, `hard`, `veryhard`).
- **-WorldSeed** – World seed string (e.g. `<worldSeed>`). Use with a new world name.
- **-SkipImageBuild** – Skip Docker build/push and use the image already in ACR.
- **-PinVersion** – Set `AUTO_UPDATE=0` so the container does not run Steam updates; server stays on the game version in the image. Use when deploying with a specific `-ImageTag` after a bad game update.
- **-KeyVaultSecretName** – Use a Key Vault secret for the password instead of `-ServerPass` (e.g. `<keyVaultSecretName>`).

Example with Key Vault:

```powershell
.\deploy-valheim-aci.ps1 -Game "valheim" -UserName "<userName>" -ServerName "<serverName>" -WorldName "<worldName>" -KeyVaultSecretName "<keyVaultSecretName>"
```

Example Windrose deployment (direct IP + password, port 3000 UDP):

```powershell
.\deploy-valheim-aci.ps1 -Game "windrose" -UserName "<userName>" -ServerName "<serverName>" -ServerPass "<serverPass>" -WindroseDirectPort 3000
```

When the script finishes, it prints the **public IP**. Connect with **direct IP** (not invite code): `<public-ip>:3000` and the password from `-ServerPass`. First boot installs the game via SteamCMD inside the container (can take 15–30+ minutes); watch logs with `az container logs`.

Windrose uses **8 GB** memory by default in config (`games.windrose.aci.memoryInGb`) and deploys via a container-group YAML template. Set `games.windrose.ports` to **TCP or UDP** on port 3000 (not both — ACI rejects duplicate port numbers on one public IP).

Current status: Windrose **does run** in ACI, but the best public-network configuration is still being determined. UDP-only and TCP-only direct-IP tests have both been tried; neither has yet matched the reliability of the native Windows VM reference, so treat ACI Windrose hosting as experimental for now.

Current logging/runtime defaults for Windrose ACI:

- `WINEDEBUG=-all` to keep container logs readable
- `WINEPREFIX_USE_CONTAINER_TMP=1` because Azure Files did not behave well for a persistent Wine prefix
- much slower startup than the Windows VM baseline; expect long `loadDB` / `makebak` phases before the server is really ready

### Game-specific options in config

`azure-config.json` now has a `games` section (`games.valheim`, `games.windrose`) that defines:

- image repository and source folder (`imageRepository`, `repoFolder`)
- runtime mount path (`mountPath`)
- exposed ports (`ports`)
- server option contract (`serverOptions.required`, `serverOptions.optional`)

Windrose config also includes SteamCMD metadata:

- `steamAppId: 4129620`
- `steamLogin: anonymous`
- `steamValidate: true`
- `configFiles`: `ServerDescription.json`, `WorldDescription.json`

### Ports

- **Valheim:** UDP **2456** (via `az container create`).
- **Windrose:** UDP **3000** on ACI (via container group YAML; example config). Azure does not allow the same port number for both TCP and UDP on one container group ([ACI limitation](https://stackoverflow.com/questions/61053139)); local Docker and a VM can expose both. If join fails, try switching `games.windrose.ports` to `TCP` and redeploy for comparison.

### Public IP

ACI is created with a **dynamic** public IP. It stays the same while the container group exists and is restarted; it can change if the group is deleted and recreated. For a **static** public IP you’d use a VNet and Application Gateway (or similar); that can be added in a later automation step.

---

## After deployment

- **Logs:** `az container logs --resource-group <resourceGroup> --name <instanceName> --follow`
- **Stop:** `az container stop --resource-group <resourceGroup> --name <instanceName>`
- **Start:** `az container start --resource-group <resourceGroup> --name <instanceName>`
- **Delete:** `az container delete --resource-group <resourceGroup> --name <instanceName> --yes`

### Version control (lock / roll back)

To handle Valheim updates that break things:

1. **Create a versioned image when things are good**  
   Build and push with a tag (e.g. date or version), and optionally push `latest`:
   ```powershell
   .\deploy-valheim-aci.ps1 -ServerName "<serverName>" -WorldName "<worldName>" -ServerPass "<serverPass>" -InstanceName "<instanceName>" -ImageTag "<imageTag>"
   ```
   (Omit `-SkipImageBuild` so it builds; the script tags the image as `<imageTag>` and pushes it. New deployments can then use `-ImageTag <imageTag>`.)

2. **Deploy or redeploy with a specific tag**  
   Use an image tag you know is good:
   ```powershell
   .\deploy-valheim-aci.ps1 -ServerName "<serverName>" -WorldName "<worldName>" -ServerPass "<serverPass>" -InstanceName "<instanceName>" -ImageTag "<imageTag>" -SkipImageBuild
   ```

3. **Lock at that version (no in-container Steam update)**  
   Add `-PinVersion` so the container does not run SteamCMD on start; it stays on the game version in the image:
   ```powershell
   .\deploy-valheim-aci.ps1 ... -ImageTag "<imageTag>" -PinVersion -SkipImageBuild
   ```

4. **List tags in ACR**  
   See which image tags exist:  
   `az acr repository show-tags --name <acrName> --repository valheim-server --orderby time_desc -o table`

**Summary:** Build and tag images when Valheim is known-good (e.g. `-ImageTag <imageTag>`). If a later update breaks things, redeploy with that tag and `-PinVersion` so servers stay on the old game version until you fix or skip the bad update.

---

### File share structure

- **gamedata** – One share; each server uses a **subdirectory** (same name as the instance, e.g. `<instanceName>`). Game install and world/autobackups for that server live under `gamedata/<instanceName>/`.
- **gameserverbackups** – Separate share for backup copies. The deploy script creates a **subdirectory per server** (e.g. `gameserverbackups/<instanceName>/`). A separate backup job (e.g. scheduled script or Azure Function) should copy from `gamedata/<instanceName>/` to `gameserverbackups/<instanceName>/` on a schedule. Valheim’s in-game autobackups stay in gamedata; this share is for your own backup copies.
