# Windrose Windows VM findings for Linux container POC

Date: 2026-04-20  
Host: Sherman (Bazzite, KVM/libvirt)  
Guest: `windroseVM-Win25` (Windows Server 2025)

This document captures the successful Windows VM baseline and the key lessons from failed Linux container attempts so future Proton/Wine container experiments can be faster and more deterministic.

---

## 1) Known-good result

- Windrose dedicated server installs and runs on a Windows Server 2025 VM.
- RDP into the VM works from other systems on the LAN after moving VM networking from libvirt NAT to a host bridge.
- VM storage now uses a Linux-native ext4 partition (`/mnt/vmstore`) instead of NTFS user-mount paths.
- Snapshot milestones exist and provide rollback points.
- A game client successfully connected to the server (end-to-end validation of launch, backend registration, and join path).
- Client join paths include both:
  - invite/join code flow
  - direct IP flow
- Runtime quality note: client join succeeds, but loading is very slow and in-session gameplay shows noticeable lag.
- VM resource bottleneck observed during runtime: memory reached ~7.4/8.0 GB (about 92%), with only ~609 MB available and commit near limit (9.2/9.9 GB), consistent with paging pressure and poor load-time/gameplay responsiveness.
- After increasing VM RAM to 16 GB, client join/load became much faster and initial gameplay lag was not observed in immediate retest.
- Current post-fix runtime observation: memory usage sits around ~7.8 GB in use, indicating substantial steady-state RAM demand even after load completes.
- Connectivity validation expanded: a user from a remote network successfully connected, indicating routing and external network reachability are functioning.

Current snapshots:
- `post-update-clean`
- `post-install-updated`

---

## 2) Hypervisor/network setup that worked

### Storage

- Original pool target under `/run/media/kk/Games Fast (500G)` caused qemu access failures.
- Root causes:
  - user-session mount path (`/run/media/kk/...`) not stable for system services
  - NTFS not ideal for libvirt VM image workloads on Linux
  - path traversal and SELinux labeling friction

Final storage layout that worked:
- Created ext4 partition on `sda3` (150 GB), mounted at `/mnt/vmstore`
- libvirt `default` pool target: `/mnt/vmstore/libvirt-images`
- SELinux label fixed to `virt_image_t` on VM image directory

### VM network

- libvirt `default` NAT network (`192.168.122.0/24`) worked host->guest but not LAN client->guest.
- Correct long-term fix: create Linux bridge `br0` and attach VM NIC to bridge.
- Host now carries LAN IP on `br0`; VM gets direct LAN IP (`192.168.40.x`) and is directly reachable for RDP.

---

## 3) Windows VM profile (baseline)

Domain name:
- `windroseVM-Win25`

Create profile used:
- 8 GB RAM
- 4 vCPU
- 60 GB qcow2 disk
- Q35 + UEFI
- NIC model `e1000e` (bridged)
- graphics: SPICE

Install media:
- `/mnt/vmstore/libvirt-images/win2025.iso`

Notes:
- VM creation initially failed on host TPM setup (`swtpm_setup`) due to local CA state path permissions.
- Resolved by proceeding without TPM for this initial build path.

---

## 4) Linux container POC findings (important failures)

From earlier Windrose container experiments in `windrose/`:

- Proton mode:
  - install stage looked healthy
  - server process exited quickly with code 5
  - `last-run.log` often sparse

- Wine mode:
  - previous `winedbg` hangs fixed by overriding `winedbg.exe=d`
  - recurring `wineboot` / prefix errors including:
    - `wine: could not load kernel32.dll, status c0000135`
  - issue persisted even with temporary in-container prefixes (`WINEPREFIX_USE_CONTAINER_TMP=1`), so this was not only bind mount corruption

Operational conclusion:
- Windows VM is currently the only verified working baseline for Windrose server on this hardware.
- Linux container path remains experimental and should be tested against a strict matrix, not ad hoc single runs.

---

## 5) Data to capture from Windows VM now

Capture these while behavior is known-good:

1. **Exact launch command and args**
- executable path, startup flags, world/server-name args, log args

2. **Required ports/protocol**
- game/query/admin ports
- UDP vs TCP per port
- confirm firewall rules needed for LAN and WAN use

3. **Persistent data paths**
- saves/config/logs/caches
- files that must survive updates/redeploy

4. **Runtime prerequisites**
- VC++/.NET/runtime components
- any services required by the dedicated server

5. **Startup behavior**
- cold start timing
- memory and CPU at idle and during active gameplay
- common warning/error lines that are benign vs fatal

6. **Update mechanics**
- Steam app id and update sequence that consistently yields a runnable server
- whether first launch mutates files in ways Linux container startup must preserve

### 5.0 Runtime prerequisite discovered during first launch

Observed launch failure dialog:
- `WindroseServer-Win64-Shipping.exe - System Error`
- `The code execution cannot proceed because MSVCP140.dll was not found.`

Interpretation:
- Microsoft Visual C++ runtime is required and not present in a fresh Windows Server image.
- Expected fix is installing Microsoft Visual C++ Redistributable 2015-2022 (x64).  
- In practice, installing both x64 and x86 redistributables avoids secondary missing-DLL errors for mixed helper binaries.

Container relevance:
- Wine/Proton-based container startup may require equivalent VC runtime components in prefix initialization.
- This missing-runtime error provides a concrete parity checkpoint between Windows VM and Linux container runs.

### 5.0.1 Official dedicated-server documentation highlights (`DedicatedServer.md`)

From the bundled vendor documentation:
- configuration is split into:
  - `ServerDescription.json` (single server-level file)
  - `WorldDescription.json` (one file per world)
- recommended workflow:
  - first start/stop once to generate defaults
  - edit JSON only while server is shut down
- client join methods:
  - invite code
  - direct IP / direct connection mode

Port guidance in docs:
- direct-connection behavior is controlled by `UseDirectConnection`.
- `DirectConnectionServerPort` is the direct mode listener port.
- if direct mode is enabled, that port should be reachable for **both TCP and UDP**.
- vendor example uses port `7777`.

Interpretation for this project:
- internal localhost gRPC seen in runtime logs (for example `127.0.0.1:42025`) is control-plane traffic and separate from the direct client-listen port used by direct connection mode.

### 5.1 Default Windrose install layout (Windows VM reference)

Observed path:
- `C:\Program Files (x86)\Steam\steamapps\common\Windrose Dedicated Server`

Top-level contents observed:
- directories:
  - `Engine/`
  - `R5/`
- docs/manifests:
  - `DedicatedServer.md`
  - `Manifest_DebugFiles_Win64.txt`
  - `Manifest_NonUFSFiles_Win64.txt`
  - `Manifest_UFSFiles_Win64.txt`
- startup/entry:
  - `StartServerForeground.bat`
  - `WindroseServer.exe`
- bundled steam/runtime DLLs:
  - `steamclient.dll`, `steamclient64.dll`
  - `steamwebrtc.dll`, `steamwebrtc64.dll`
  - `tier0_s.dll`, `tier0_s64.dll`
  - `vstdlib_s.dll`, `vstdlib_s64.dll`

Why this matters for Linux container parity:
- confirms expected root-level executable and launcher names
- confirms Steam runtime DLLs ship beside server binaries
- gives a quick baseline to compare with container install results after SteamCMD/update steps

### 5.2 Foreground launcher script (Windows baseline)

Source file:
- `StartServerForeground.bat`

Observed contents:
```bat
@echo off
pushd %~dp0%

:: Starts WindroseServer with visible console window for log monitoring
start /abovenormal R5\Binaries\Win64\WindroseServer-Win64-Shipping.exe -log

popd
```

Interpretation:
- canonical server executable is:
  - `R5\Binaries\Win64\WindroseServer-Win64-Shipping.exe`
- known-good baseline launch flag:
  - `-log`
- script assumes working directory is the install root (`pushd %~dp0%`)
- process priority hint used by vendor launcher:
  - `start /abovenormal`

Container relevance:
- container entrypoint should launch the same executable path and preserve expected working directory semantics
- `-log` should be retained for early parity/debug runs so container logs are comparable to Windows baseline

### 5.3 Startup log baseline (early server boot)

Observed from initial successful boot log:
- executable:
  - `WindroseServer-Win64-Shipping.exe`
- command line:
  - `-log`
- base directory:
  - `C:/Program Files (x86)/Steam/steamapps/common/Windrose Dedicated Server/R5/Binaries/Win64/`
- engine:
  - `UE 5.6.1-0+UE5` (shipping build)
- compiler/runtime hint:
  - `Compiled with Visual C++: 19.38.33145.00`
- platform identity in log:
  - `Platform=WindowsServer`
  - OS reported as Windows Server 2022 (24H2), build `10.0.26100.32690`
- networking init:
  - WinSock initialized
  - HTTP thread created
  - online subsystem loaded as `NULL`
- curl stack:
  - libcurl 8.12.1
  - OpenSSL 1.1.1t
  - `bVerifyPeer = false` (certificate verification disabled by current runtime config)

Why this matters:
- confirms a known-good startup signature to compare against future Linux Proton/Wine logs
- confirms runtime/compiler family aligned with VC++ redistributable dependency (`MSVCP140.dll` finding)
- confirms expected working directory and executable path used by vendor launcher
- provides a concrete "early boot complete" checkpoint before gameplay/session validation

### 5.4 Full startup sequence markers (healthy boot checklist)

From the full Windows VM startup log, the following sequence indicates a healthy dedicated-server startup:

1. **Engine and runtime init**
- `ExecutableName: WindroseServer-Win64-Shipping.exe`
- `Command Line: -log`
- `Platform=WindowsServer`
- `Build Configuration: Shipping`

2. **Game engine initialized**
- `LogInit: Display: Game Engine Initialized.`
- `LogInit: Display: Starting Game.`
- `LogLoad: LoadMap: /Game/Maps/Lobby/R5ServerLobby`

3. **Coop proxy and persistence initialized**
- creates/uses `R5/Saved/SaveProfiles/Default/RocksDB/`
- creates/updates `R5/ServerDescription.json`
- backup rotation path: `R5/Saved/SaveProfiles/Default_Backups/<timestamp>`

4. **Backend connectivity and registration**
- repeated successful `/ping` responses to regional API gateways
- successful dedicated server authentication
- transitions to registered state:
  - `WaitingForAuthorization => WaitingForRegistration => Registered`
- prints server connection info block (invite code etc.)

5. **World load and ready state**
- transitions from lobby map to gameplay map:
  - `/Game/Maps/GYM/Genlandia/GenlandiaMulty`
- server state transition:
  - `OpenedServerLobby => LoadedIslandData => WaitingForFirstAccount`

Use these as parity checkpoints in Linux container logs. If a container run fails before step 3 or 4, focus on runtime/dependency and network egress first.

### 5.5 Network dependencies observed in healthy run

Observed outbound HTTPS dependencies:
- `https://r5coopapigateway-eu-release.windrose.support:443`
- `https://r5coopapigateway-ru-release.windrose.support:443`
- `https://r5coopapigateway-kr-release.windrose.support:443`

Observed auth/registration flow:
- `/ping` checks
- `/api/v1/Auth/AuthenticateDedicatedServer`

Container implication:
- Linux container deployments must allow outbound TLS to these endpoints (DNS + 443 egress), or server registration will stall/fail even if local process launch succeeds.
- Join-mode implication:
  - invite/join code path depends on successful backend registration flow
  - direct IP path still depends on dedicated server process health and reachable listener/network path

### 5.6 Persistent file/data paths confirmed

From the healthy Windows startup:
- root:
  - `C:/Program Files (x86)/Steam/steamapps/common/Windrose Dedicated Server/R5/`
- logs:
  - `R5/Saved/Logs`
- server metadata:
  - `R5/ServerDescription.json`
- save/profile data:
  - `R5/Saved/SaveProfiles/Default/RocksDB/`
- automated backups:
  - `R5/Saved/SaveProfiles/Default_Backups/`

Container implication:
- these path classes should map to persistent volumes/bind mounts for restart safety and rollback.

### 5.6.1 `ServerDescription.json` (observed baseline)

Observed file:
- `R5/ServerDescription.json`

Observed structure:
```json
{
  "Version": 1,
  "DeploymentId": "0.10.0.3.104-256f9653",
  "ServerDescription_Persistent": {
    "PersistentServerId": "00000000000000000000000000000000",
    "InviteCode": "00000000",
    "IsPasswordProtected": false,
    "Password": "",
    "ServerName": "",
    "WorldIslandId": "5C2B626F6A8C4D5D1F9757B4FB6D3C6F",
    "MaxPlayerCount": 8,
    "UserSelectedRegion": "",
    "P2pProxyAddress": "127.0.0.1",
    "UseDirectConnection": false,
    "DirectConnectionServerAddress": "",
    "DirectConnectionServerPort": -1,
    "DirectConnectionProxyAddress": "0.0.0.0"
  }
}
```

Field notes (based on runtime logs and behavior):
- `InviteCode` maps to the join-code flow displayed after successful registration.
- `UseDirectConnection` + `DirectConnection*` fields are the obvious knobs for direct-IP style behavior.
- `WorldIslandId` is populated after island creation/selection.
- `PersistentServerId` appears stable and identifies the persisted server profile.

Container relevance:
- treat this file as persistent state; do not lose it across container restarts unless intentionally resetting server identity/world metadata.
- avoid committing real invite codes/password values into git history.

### 5.6.2 `WorldDescription.json` (observed baseline)

Observed file (under world save path):
- `R5/Saved/SaveProfiles/Default/RocksDB/<version>/Worlds/<islandId>/WorldDescription.json`

Observed structure:
```json
{
  "Version": 1,
  "WorldDescription": {
    "islandId": "5C2B626F6A8C4D5D1F9757B4FB6D3C6F",
    "WorldName": "",
    "CreationTime": 6.3912296965830003e+17,
    "WorldPresetType": "Medium",
    "WorldSettings": {
      "BoolParameters": {
        "{\"TagName\": \"WDS.Parameter.Coop.SharedQuests\"}": true,
        "{\"TagName\": \"WDS.Parameter.EasyExplore\"}": false
      },
      "FloatParameters": {
        "{\"TagName\": \"WDS.Parameter.MobHealthMultiplier\"}": 1,
        "{\"TagName\": \"WDS.Parameter.MobDamageMultiplier\"}": 1,
        "{\"TagName\": \"WDS.Parameter.ShipsHealthMultiplier\"}": 1,
        "{\"TagName\": \"WDS.Parameter.ShipsDamageMultiplier\"}": 1,
        "{\"TagName\": \"WDS.Parameter.BoardingDifficultyMultiplier\"}": 1,
        "{\"TagName\": \"WDS.Parameter.Coop.StatsCorrectionModifier\"}": 1,
        "{\"TagName\": \"WDS.Parameter.Coop.ShipStatsCorrectionModifier\"}": 0
      },
      "TagParameters": {
        "{\"TagName\": \"WDS.Parameter.CombatDifficulty\"}": {
          "TagName": "WDS.Parameter.CombatDifficulty.Normal"
        }
      }
    }
  }
}
```

Field notes:
- `islandId` matches the world/island identifiers seen in startup logs and server description.
- `WorldPresetType` currently `Medium`, aligned with startup log lines that apply medium preset settings.
- world tuning values (combat difficulty, multipliers, shared quests, exploration flags) are persisted here.

Container relevance:
- this file is part of the gameplay/world identity and difficulty state; it must persist across container restarts and upgrades.
- if a container run regenerates or resets this file unexpectedly, world behavior may diverge from the Windows baseline even if process startup succeeds.

### 5.7 Warning lines seen in healthy run (likely non-fatal)

These appeared while startup still completed successfully:
- missing package/string table warnings in UI/font/loading-hint assets
- `No Audio Capture implementations found`
- DLSS/Streamline unsupported on remote/basic display adapter
- replication graph warnings during map transition in lobby teardown

Interpretation:
- these warning classes alone do not indicate startup failure for dedicated server mode.
- in Linux-container triage, prioritize first fatal error and state-transition breakpoints over these non-fatal warnings.

---

## 6) Proposed Linux container test matrix (next pass)

When revisiting `windrose/`, run controlled experiments and record output in a table:

- Runtime:
  - Proton GE (current)
  - Proton official
  - WineHQ stable
  - WineHQ staging

- Prefix strategy:
  - bind-mounted persistent prefix
  - in-container temp prefix then copied to persistent storage

- Entry behavior:
  - clean prefix bootstrap
  - incremental restart with existing prefix

- Metrics captured every run:
  - exit code
  - first fatal log line
  - time-to-fail or time-to-listening-port
  - whether server process remains alive for N minutes

Success criteria:
- process stays running
- expected UDP/TCP ports listen
- local client can connect
- restart remains healthy with persisted data

---

## 7) Recommended immediate next actions

1. Keep `windroseVM-Win25` as gold baseline until Linux container path is proven.
2. Add a new snapshot after Windrose server configuration is finalized (for quick rollback).
3. Capture a one-page runtime inventory from the VM (ports, paths, launch args, prerequisites, and observed latency/load-time behavior).
4. Re-run container POC using the matrix in section 6 and compare against the VM baseline.

---

## 8) Useful commands used in this setup

Start VM:
```bash
sudo virsh start windroseVM-Win25
```

Check VM state:
```bash
sudo virsh list --all
```

Create snapshot (while VM shut off):
```bash
sudo virsh snapshot-create-as windroseVM-Win25 "snapshot-name" "notes" --disk-only --atomic
```

List snapshots:
```bash
sudo virsh snapshot-list windroseVM-Win25
```
