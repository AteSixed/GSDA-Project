# Setup and status (as of 2026-05-26)

This document records what has been configured in **ServerAutomation**, what was tried for **Windrose** locally, how **Valheim** is deployed and updated in Azure, and the **Bazzite (`<hypervisorHost>`)** KVM hypervisor baseline. Paths are relative to the repo root unless stated otherwise.

---

## 1. Repository layout (relevant pieces)

| Area | Path | Role |
|------|------|------|
| Windrose current container | `windrosev2/` | Current Docker image for the Windows dedicated server under Wine + Xvfb; used for local LAN testing and experimental ACI deploys |
| Windrose historical POC | local-only `windrose/`, `windrose.bak/` | Earlier experiments retained for reference but not part of the published repo path |
| Valheim local | `valheim/` | Docker image + compose for local dedicated server |
| Azure ACI deploy | `azure/deploy-valheim-aci.ps1`, `azure/azure-config.json` | Build/push game image to ACR, create ACI container group, mount Azure Files, expose one protocol per public port |
| Azure docs | `azure/README.md` | First-time deploy, parameters, Key Vault, Windrose ACI notes |
| Windrose smoke test | `docs/WINDROSE-CONTAINER-SMOKE-TEST.md` | Local Docker smoke-test checklist and pass result |

---

### Current snapshot (2026-05-26)

- **Local Windrose (`windrosev2/`)**: smoke-tested and working over LAN with **direct IP + password** on port **3000**.
- **ACI Windrose**: deploys successfully and reaches real game logging, but the best public-network configuration is still being determined.
- **ACI protocol limitation**: Azure Container Instances cannot expose **TCP 3000 and UDP 3000 together** on one public IP; tests have been run with **TCP-only** and **UDP-only**.
- **TCP-only ACI result**: client reached a long load and logs showed **`Unexpected BL disconnect`** / no `PlayerController`.
- **UDP-only ACI result**: client returned to menu faster and did not show the same disconnect in the retained log buffer.
- **ACI runtime defaults for Windrose**: `STEAM_UPDATE_ON_START=0`, `STEAMCMD_FORCE_PLATFORM_WINDOWS=0`, `WINEPREFIX_USE_CONTAINER_TMP=1`, `WINEDEBUG=-all`, `WINDROSE_ENSURE_DIRECT_CONFIG=0`.
- **Startup behavior**: ACI is much slower than the Windows VM baseline; logs show repeated slow `loadDB` / `makebak` tasks, and current evidence points more toward container / Wine / Azure Files overhead than sustained CPU saturation.
- **Current recommendation**: use `windrosev2/` locally for LAN testing, keep the Windows VM as the reliable public-hosting reference, and treat Windrose on ACI as experimental.

---

## 2. Windrose historical container investigation notes

### Goal

Run the Windrose dedicated server (Steam app **4129620**, Windows binary) in Linux Docker for experimentation.

### Image stack (Dockerfile)

- **Base:** Ubuntu 22.04 (jammy)
- **Wine:** **WineHQ** repository — default meta-package **`winehq-stable`** (build arg `WINEHQ_PACKAGE`; alternatives `winehq-staging`, `winehq-devel`)
- **PATH:** `/opt/wine-stable/bin` (and staging/devel) prepended so the unified WoW64 **`wine`** from WineHQ is preferred over `/usr/bin/wine` alone
- **Extras:** `libegl1`, `libegl1:i386`, `libgbm1`, `mesa-vulkan-drivers`, SteamCMD, GE-Proton tarball at build time (`ARG PROTON_VERSION`, default **GE-Proton10-34** — matches GitHub `releases/latest` at time of work)
- **Compose:** `docker-compose.yml` passes `build.args` for `PROTON_VERSION` and `WINEHQ_PACKAGE`

### Entrypoint behavior (`windrose/entrypoint.sh`)

- **`RUNTIME_MODE=proton`:** Proton `run` + persistent prefix under `./data/<SERVER_DATA_SUBDIR>/protonprefix/`, logs in `proton-logs/last-run.log`
- **`RUNTIME_MODE=wine`:** Plain Wine; prefix under `./data/<SERVER_DATA_SUBDIR>/wineprefix/` (or **`WINEPREFIX_USE_CONTAINER_TMP=1`** → `/tmp/windrose-wine-<subdir>` inside the container)
- **Wine debugger:** `WINEDLLOVERRIDES` includes `winedbg.exe=d` so crashes do not hang on `winedbg` in headless Docker
- **`wineboot`:** quieter `WINEDEBUG=-all` during prefix init; tee to logs; optional repair if `kernel32.dll` missing under prefix
- **Loader selection:** prefers `/opt/wine-stable/bin/wine` (etc.) because WineHQ stable often has **no separate `wine64` file**
- **Docs:** `windrose/README.md` — runtime modes, DXVK/lavapipe notes, kernel32 / bind-mount notes

### Local `.env` (current intent)

File: `windrose/.env` (not committed if gitignored — verify locally)

- `RUNTIME_MODE=proton` — back on Proton after Wine `kernel32` failures even on `/tmp` prefix
- `WINEPREFIX_USE_CONTAINER_TMP=0`
- `SERVER_DATA_SUBDIR=windrose-local-1`, `WINEDEBUG=+err`, etc.

### Outcomes observed

| Mode | Observation |
|------|----------------|
| **Proton** | Install OK; process exits **code 5** shortly after start; `last-run.log` often minimal (ProtonFixes “unit test” warnings, `wineserver` line) |
| **Wine (stable)** | With correct loader, **`wineboot`** still failed: **`wine: could not load kernel32.dll, status c0000135`** even with **`WINEPREFIX_USE_CONTAINER_TMP=1`** (rules out bind-mount-only) |
| **Earlier Wine** | Page fault / exit 5; disabling `winedbg` made failures **fast** instead of hung |

### Planned follow-up

- **Windrose official docs** were expected to update **2026-04-20** — revisit after release to align SteamCMD/runtime guidance.

### 2.1 Windrose dedicated server binary probes (Windows VM, 2026-04-21)

This is separate from the Docker POC above. These checks were run against the installed dedicated server files under:

`%ProgramFiles(x86)%\Steam\steamapps\common\Windrose Dedicated Server`

#### Binary and launch artifacts

- Root launcher: `WindroseServer.exe`
- Actual server binary: `R5\Binaries\Win64\WindroseServer-Win64-Shipping.exe`
- Provided foreground launcher script: `StartServerForeground.bat` starts:
  - `R5\Binaries\Win64\WindroseServer-Win64-Shipping.exe -log`
- Runtime log file path: `R5\Saved\Logs\R5.log` (plus rotating backups)

#### Option/help probing

- Short probes with `-help`, `-?`, and `/?` did **not** print a switch/help menu.
- All three probes started normal server initialization and kept running until manually stopped.
- Current conclusion: there is no obvious built-in "list all flags" output exposed by this shipping build.

#### CPU A/B check (`-log` vs no args)

A controlled A/B run sampled process CPU over equal windows (artifacts in `perf testing/exe-probe/`):

- `summary_nolog.txt`:
  - Average server CPU (machine-normalized): **50.97%**
  - Range: **46.11% - 55.11%**
- `summary_withlog.txt`:
  - Average server CPU (machine-normalized): **50.56%**
  - Range: **41.55% - 53.26%**

Observed delta was small and in favor of `-log` by ~0.41 percentage points, which is within normal run-to-run noise.

#### Recommendation (best performance/log ratio)

- Keep `-log` enabled for now because:
  - Measured CPU difference was not meaningful in this A/B run.
  - Operational visibility is much better with active console logging during stability work.
- Focus performance work on server/runtime settings and world simulation tuning first; `-log` is unlikely to be the main driver of ~50% idle CPU.
- Re-test `-log` only after a larger baseline optimization (or with longer captures and repeated trials).

### 2.2 Windrose container retry (`windrosev2`, 2026-04-22)

This was a clean container retry under `windrosev2/` with a new Dockerfile/compose/entrypoint path.

#### VC++ runtime bootstrap

- Added `winetricks` to the image (`windrosev2/Dockerfile`).
- Added runtime toggles:
  - `INSTALL_VCRUN` (default `0`)
  - `WINETRICKS_VERBS` (default `vcrun2019`)
- Entrypoint now supports one-time runtime bootstrap with a marker file:
  - Proton prefix marker: `protonprefix/pfx/.winetricks_done_<verbs>`
  - Wine prefix marker: `wineprefix/.winetricks_done_<verbs>`
- Added a headless-safe override during bootstrap:
  - `WINEDLLOVERRIDES=mscoree,mshtml=;winedbg.exe=d`
  - This avoids mono/gecko installer prompts that can stall in containerized headless mode.

#### Compose/env wiring

- `windrosev2/docker-compose.yml` now passes:
  - `INSTALL_VCRUN=${INSTALL_VCRUN:-0}`
  - `WINETRICKS_VERBS=${WINETRICKS_VERBS:-vcrun2019}`

#### Observed results after `vcrun2019`

- **Proton mode:** VC bootstrap completed and marker file was created, but server still exited quickly with **code 5**.
- **Wine mode:** still fails with `wine: could not load kernel32.dll, status c0000135` (exit **53**), even after VC runtime bootstrap.
- Conclusion so far: missing VC++ redistributables were likely *part* of requirements, but they are **not** the primary blocker behind current Proton `code 5` / Wine `kernel32` failures in this container.

#### Follow-up: broader runtime set (`vcrun2015 vcrun2019`)

- Retest used:
  - `INSTALL_VCRUN=1`
  - `WINETRICKS_VERBS="vcrun2015 vcrun2019"`
- Prefix marker confirmed:
  - `protonprefix/pfx/.winetricks_done_vcrun2015_vcrun2019`
- Result:
  - Proton still exited with **code 5** after startup (`ProtonFixes` warning + `fsync: up and running` then exit).
- Current conclusion:
  - Matching Windows VM behavior (both VC++ generations, x86+x64 equivalent runtime coverage) was still not enough to clear the Linux container blocker.

#### Follow-up: forced prefix rebuild after runtime changes

- Performed a clean prefix reset (deleted only):
  - `data/windrose-local-v2/protonprefix`
  - `data/windrose-local-v2/wineprefix`
- Re-ran with:
  - `RUNTIME_MODE=proton`
  - `INSTALL_VCRUN=1`
  - `WINETRICKS_VERBS="vcrun2015 vcrun2019"`
- Confirmed from logs:
  - Proton created a fresh prefix (`Creating WINEPREFIX ...`)
  - Prefix upgraded (`Proton: Upgrading prefix from None to GE-Proton10-34`)
  - Winetricks marker recreated (`.winetricks_done_vcrun2015_vcrun2019`)
- Result:
  - Startup still ended in Proton **exit code 5**.

#### Follow-up: Proton runtime A/B

- Attempted to add Valve Proton binary tarball from GitHub releases for side-by-side A/B.
- Result: Valve Proton direct binary URL path returned **404** during image build (Valve GitHub publishes source releases, not always a ready compatibility-tool tarball at that path).
- Performed practical A/B with two known-good GE binaries in one image:
  - `GE-Proton10-34` (default)
  - `GE-Proton10-33` (selected via `PROTON_PATH`)
- Used isolated data roots so each run had a fresh install/prefix path:
  - `windrose-ge1034`
  - `windrose-ge1033`
- Both runs completed full SteamCMD install/update and VC runtime bootstrap, then still ended with:
  - **`windrose exited with code 5`**
- Current conclusion:
  - No meaningful behavior change between GE 10-34 and GE 10-33 in this container scenario.

#### Follow-up: GE-Proton10-4 parity test

- User-reported local Linux reference runtime: Proton `10-04`.
- Added `GE-Proton10-4` to the image as an alternate compatibility tool and ran with:
  - `PROTON_PATH=/home/steam/.local/share/Steam/compatibilitytools.d/GE-Proton10-4/proton`
  - Fresh isolated data root: `SERVER_DATA_SUBDIR=windrose-ge1004`
  - VC bootstrap enabled: `vcrun2015 vcrun2019`
- Observed:
  - Fresh prefix created and upgraded (`Proton: Upgrading prefix from None to GE-Proton10-4`)
  - `fsync: up and running` reached
  - Process still exited with **code 5**
- Current conclusion:
  - Using the older GE `10-4` line did not clear the startup failure in this container.

#### Follow-up: minimal Proton env + launcher selection

- Added entrypoint controls:
  - `PREFER_ROOT_LAUNCHER=1` (pick `WindroseServer.exe` before shipping exe)
  - `SERVER_EXE_OVERRIDE=<path>` (force explicit exe path if needed)
- Added compose passthrough for:
  - `PREFER_ROOT_LAUNCHER`, `SERVER_EXE_OVERRIDE`
  - `PROTON_USE_WINED3D`, `PROTON_NO_FSYNC`, `PROTON_NO_ESYNC`
- Minimal-runtime test profile used:
  - `PROTON_PATH=.../GE-Proton10-4/proton`
  - `PROTON_USE_WINED3D=1`
  - `PROTON_NO_FSYNC=1`
  - `PROTON_NO_ESYNC=1`
- Results:
  - **Shipping exe path** (`R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe`): still exits with code 5.
  - **Root launcher path** (`WindroseServer.exe`) against the same installed files: also exits with code 5.
- Notes:
  - A couple of fresh-root-launcher runs failed earlier at SteamCMD install (`Missing configuration`, exit 8), but reusing already-installed files isolated launcher behavior and still produced code 5.
- Current conclusion:
  - Neither minimal Proton toggles nor launcher path selection cleared the failure.

#### Follow-up: Ubuntu base upgrade (22.04 -> 24.04 LTS)

- Switched container base from `ubuntu:22.04` to `ubuntu:24.04` and updated WineHQ apt source suite:
  - `jammy` -> `noble`
- Confirmed runtime image OS:
  - `Ubuntu 24.04.4 LTS (Noble Numbat)`
- Re-ran controlled launch profiles on this newer base (including GE-Proton10-4, fresh prefixes, VC runtime bootstrap, and launcher A/B).
- Result:
  - Windrose still exits with **code 5** under Proton.
- Current conclusion:
  - Newer Ubuntu base alone does not resolve the startup failure.

---

## 3. Valheim

### Local (`valheim/`)

- **Compose:** `valheim/docker-compose.yml` — ports 2456–2458 UDP, `./data` bind mount
- **Entrypoint:** `valheim/entrypoint.sh` — if **`AUTO_UPDATE=1`** (default) **or** server binary missing → SteamCMD **`app_update 896660 validate`** on **every container start**

### Azure managed instance (ACI)

- **Script:** `azure/deploy-valheim-aci.ps1`
- **Creates:** Linux ACI container group, pulls image from ACR, mounts Azure Files share at game `mountPath`, sets env including `SERVER_DATA_SUBDIR=<InstanceName>`
- **Updates:**
  - **`-PinVersion`** → `AUTO_UPDATE=0` in container (no routine SteamCMD update on start unless binary missing)
  - **Default (no pin)** → `AUTO_UPDATE=1` → **restart/start runs SteamCMD update again** (same as local entrypoint logic)

See **`azure/README.md`** for full parameter list and examples.

---

## 4. Bazzite hypervisor host `<hypervisorHost>` (Linux KVM)

Hardware is **AMD** (CPU flags include **`svm`**, **`npt`**).

### 4.1 BIOS / kernel virtualization

- **Initial issue:** `/dev/kvm` missing; `modprobe kvm_amd` → **Operation not supported**
- **Kernel message:** `SVM disabled (by BIOS) in MSR_VM_CR`
- **Fix:** Enable **SVM** (AMD-V) in firmware; reboot
- **Verified after fix:**
  - `sudo modprobe kvm_amd` succeeds
  - `/dev/kvm` exists (`crw-rw-rw- root kvm`)
  - `lsmod` shows `kvm_amd`, `kvm`

### 4.2 Packages (rpm-ostree)

- **Issue:** `rpm-ostree install ... libvirt` failed because `libvirt` already in base image
- **Resolution:** use **`--allow-inactive`** when layering remaining packages (per earlier session); reboot after `rpm-ostree` changes
- **Tools:** `virt-install` reported **5.1.0** in session

### 4.3 libvirt daemon

- **`libvirtd`:** enabled and **active (running)**
- **Default NAT network `default`:** **active**, **autostart yes**, **persistent yes** (via `virsh -c qemu:///system`)

### 4.4 User / polkit (password prompts for `virsh`)

- **`libvirt` group:** `getent group libvirt` showed GID **961** but group was **not** in local `/etc/group`, so **`gpasswd` / `usermod -aG libvirt`** could not attach user `<linuxUser>`
- **User groups:** `<linuxUser>` is in **`wheel`**
- **Fix applied:** polkit rule **`/etc/polkit-1/rules.d/50-libvirt-wheel.rules`** — allow **`org.libvirt.unix.manage`** for **`wheel`** → **`polkit.Result.YES`**
- **`sudo systemctl restart polkit`**
- **Verified:** `virsh -c qemu:///system net-list --all` runs **without** password prompt and lists **`default`**

### 4.5 Remote desktop (RDP) on `<hypervisorHost>`

- **Stack:** RDP is **KDE KRDP**, not **xrdp** or **GNOME Remote Desktop**. The listener is **`krdpserver`** (Plasma **System Settings → Sharing → Remote Desktop**).
- **Verify:** `ss -lntp | grep 3389` — expect `users:(("krdpserver",pid=...,fd=...))` when RDP is active.
- **Bazzite / SteamOS-style behavior:** Switching to **gaming mode** (Steam/Big Picture–style session) is not the same as a full **desktop** session. **KRDP may not listen** in gaming mode because the normal Plasma/desktop session (and thus **`krdpserver`**) is not running there. That can look like “RDP broke” or “libvirt broke networking”; it is usually **session mode**, not **`virbr0`**.
- For **headless** admin when the box boots into gaming mode, prefer **SSH**, or switch to **desktop mode** when you need RDP.

### 4.6 Recommended env (optional)

For consistent CLI targeting of system libvirt:

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
```

(Add to shell profile on `<hypervisorHost>` if desired.)

### 4.7 Current `<hypervisorHost>` status (summary)

| Item | Status |
|------|--------|
| SVM / KVM | **Enabled and working** |
| `/dev/kvm` | **Present** |
| `libvirtd` | **Running** |
| Network `default` | **Active, autostart** |
| `virsh` (system) | **Works without polkit password** for `wheel` |
| Guest VMs | **None created yet** (`virsh list --all` was empty) |

### 4.8 Next steps (not done yet)

- Build **template** guest (Windows or Linux) for game servers
- Decide automation: **SSH from dev PC** vs scripts **on `<hypervisorHost>`**
- Optional: document **clone/snapshot** workflow alongside existing `azure/deploy-valheim-aci.ps1` pattern

---

## 5. Windows dev machine context

- **OS:** Windows 11 Pro
- **Docker:** Used for local Windrose/Valheim experiments; Windrose Windows-in-Linux remains **experimental**
- **Azure:** Valheim (and future games) deployed via repo script + `azure-config.json`

---

## 6. Quick reference commands

### Windrose (local)

```powershell
cd windrosev2
docker compose build
docker compose up
```

### Valheim ACI (from Windows)

```powershell
cd azure
.\deploy-valheim-aci.ps1 -Game "valheim" -UserName "<userName>" -ServerName "<serverName>" -WorldName "<worldName>" -ServerPass "<serverPass>"
```

### `<hypervisorHost>` (libvirt sanity)

```bash
virsh -c qemu:///system net-list --all
virsh -c qemu:///system list --all
```

---

## 7. Security note

Do **not** commit real passwords or Key Vault secret values into git. Keep secrets in `.env` (gitignored), Key Vault, or your secret manager.

Focused `gitleaks` checks on committed history and the currently modified tracked files were clean as of **2026-05-26**. A raw `gitleaks dir .` scan of the whole local working tree was too noisy to use as a meaningful repo-level signal because it walked large local content outside the tracked repo surface.

---

## 8. Windrose community guide parity (Ubuntu 24.04, 2026-04-22)

### Phase 1 focus: stable container (process up under Wine/Proton)

- **In scope:** the dedicated **Windows** binary runs inside the Linux image without immediate failure (Wine/Proton, prefix, headless display, working directory). Instrument with `logs/last-run.log` and container exit code.
- **Out of scope for now:** `ServerDescription.json`, ports, NAT, invite codes, and other **network** tuning — handle after the process is stable.

- Applied the community package set to `windrosev2/Dockerfile`:
  - `wine wine32 wine64 libwine libwine:i386 fonts-wine`
  - kept `winbind` and `xvfb` installed for NTLM + headless display
- Updated runtime behavior for `RUNTIME_MODE=wine` in `windrosev2/entrypoint.sh`:
  - default force-launch to `R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe`
  - `xvfb-run` launch path (`WINE_USE_XVFB_RUN=1`) uses the same **Xvfb screen** string as common community posts: **`-screen 0 1024x768x24`** (override with **`XVFB_RUN_SCREEN`**).
  - **Wine and Proton** both **`cd` to `GAME_ROOT_OVERRIDE`** when set, else the Steam install root (`…/serverfiles`), so relative paths and config layout match a normal dedicated install.
- Added compose/env wiring:
  - `WINE_USE_XVFB_RUN` (default `1`)
  - `WINE_FORCE_SHIPPING_BINARY` (default `1`)
  - `GAME_ROOT_OVERRIDE`, `XVFB_RUN_SCREEN`
- Test notes:
  - Fresh install on Ubuntu 24.04 image succeeded (`app 4129620` fully installed).
  - Wine prefix initialized successfully (no `kernel32.dll` missing error on bootstrap).
  - Server process still exits with code `5` after launch in this container environment, including when forcing shipping EXE.
  - Strict community parity rerun (`WINE_STRICT_COMMUNITY_MODE=1`, fixed `WINEPREFIX=/home/steam/windrose/pfx`, `xvfb-run` only, shipping EXE path) still exited with code `5`.
  - New hard signal: Wine now reaches native `WindroseServer-Win64-Shipping.exe` load, then crashes with `EXCEPTION_ACCESS_VIOLATION (c0000005)` at `000000014BF499BC` (null write), which is deeper than earlier bootstrap failures.
  - Crash forensics pass (`WINEDEBUG=+seh,+module,+unwind`) confirms:
    - same faulting address (`0x14BF499BC`) and null write
    - `warn:unwind:virtual_unwind exception data not found in "WindroseServer-Win64-Shipping.exe"` (limits stack unwinding quality)
    - auto debugger launch still fails with `winedbg --auto ... (126)` in this container flow
  - Controlled VC parity pass (fresh `/home/steam/windrose/pfx`, strict mode, `INSTALL_VCRUN=1`, `WINETRICKS_VERBS=vcrun2019`) result:
    - `winetricks` starts, downloads `vc_redist.x86.exe`, reports SHA mismatch for current upstream payload, and continues in unattended mode.
    - `wine vc_redist.x86.exe /q` crashes (`Unhandled page fault on execute access at 0x0044DFFF`) and `winetricks` reports `exit status 5 - user selected 'Cancel'`.
    - Server launch still hits the same crash signature afterward: null-write AV at `0x14BF499BC`, container exits with code `5`.
  - Direct installer pass (no winetricks mediation):
    - Downloaded official installers directly: `vc_redist.x64.exe` and `vc_redist.x86.exe` (VS 2015-2022, aka.ms links).
    - Ran installs via `xvfb-run -a wine ... /quiet /norestart` in strict prefix context.
    - Both direct installs still fault in Wine during installer execution (`execute access` fault at `0x0044DFFF`), so install did not complete cleanly.
    - Post-attempt server rerun remains unchanged: null-write AV at `0x14BF499BC`, exit code `5`.
- **Native Linux server path (`RUNTIME_MODE=linux`)** in `windrosev2/entrypoint.sh`:
  - Resolves a Linux binary or wrapper under `linux64/` or `*/Binaries/Linux/` (override with `SERVER_LINUX_EXE_OVERRIDE`).
  - SteamCMD can be forced to the Linux depot with `STEAMCMD_FORCE_PLATFORM_LINUX=1` (compose / env).
  - Launch uses `GAME_ROOT_OVERRIDE` (default: server install root) as working directory and prepends the binary directory to `LD_LIBRARY_PATH` for bundled `.so` loading.
  - No Wine, Xvfb, or Proton on this path.
