#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="${SERVER_ROOT:-/home/steam/windrose}"
SERVER_DATA_SUBDIR="${SERVER_DATA_SUBDIR:-windrose-main}"
INSTANCE_ROOT="${SERVER_ROOT}/${SERVER_DATA_SUBDIR}"
INSTALL_DIR="${INSTANCE_ROOT}/serverfiles"
LOG_DIR="${INSTANCE_ROOT}/logs"
RUN_LOG="${LOG_DIR}/last-run.log"
STEAMCMD="/home/steam/steamcmd.sh"
APP_ID="${STEAMAPPID:-4129620}"

mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"
: > "${RUN_LOG}"

steamcmd_update_app() {
  echo "Installing/updating app ${APP_ID} via SteamCMD..."
  if [ "${STEAMCMD_FORCE_PLATFORM_WINDOWS:-1}" = "1" ]; then
    "${STEAMCMD}" +@sSteamCmdForcePlatformType windows +force_install_dir "${INSTALL_DIR}" +login anonymous +app_update "${APP_ID}" validate +quit
  else
    "${STEAMCMD}" +force_install_dir "${INSTALL_DIR}" +login anonymous +app_update "${APP_ID}" validate +quit
  fi
}

find_server_exe() {
  if [ -n "${SERVER_EXE_OVERRIDE:-}" ] && [ -f "${SERVER_EXE_OVERRIDE}" ]; then
    echo "${SERVER_EXE_OVERRIDE}"
    return 0
  fi

  local shipping_exe="${INSTALL_DIR}/R5/Binaries/Win64/WindroseServer-Win64-Shipping.exe"
  local root_exe="${INSTALL_DIR}/WindroseServer.exe"

  if [ -f "${shipping_exe}" ]; then
    echo "${shipping_exe}"
    return 0
  fi
  if [ -f "${root_exe}" ]; then
    echo "${root_exe}"
    return 0
  fi
  find "${INSTALL_DIR}" -maxdepth 8 -type f \( -name 'WindroseServer-Win64-Shipping.exe' -o -name 'WindroseServer.exe' \) 2>/dev/null | head -n 1
}

dump_debug_artifacts() {
  echo "--- debug: tail ${RUN_LOG} ---"
  tail -n 200 "${RUN_LOG}" 2>/dev/null || true
  if [ -f /tmp/xvfb.log ]; then
    echo "--- debug: tail /tmp/xvfb.log ---"
    tail -n 80 /tmp/xvfb.log 2>/dev/null || true
  fi
}

SERVER_EXE="$(find_server_exe || true)"
if [ -z "${SERVER_EXE}" ] || [ "${STEAM_UPDATE_ON_START:-1}" = "1" ]; then
  steamcmd_update_app
  SERVER_EXE="$(find_server_exe || true)"
fi

if [ -z "${SERVER_EXE}" ]; then
  echo "ERROR: Could not find Windrose executable under ${INSTALL_DIR}"
  exit 1
fi

ensure_server_description() {
  local sd_dir="${INSTALL_DIR}/R5"
  local sd_file="${sd_dir}/ServerDescription.json"
  local direct_port="${WINDROSE_DIRECT_PORT:-3000}"
  local display_name="${SERVER_NAME:-Windrose Server}"
  local password="${WINDROSE_SERVER_PASSWORD:-}"
  local protected="false"

  mkdir -p "${sd_dir}"

  if [ -n "${password}" ]; then
    protected="true"
  fi
  local password_escaped
  password_escaped="$(printf '%s' "${password}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  local name_escaped
  name_escaped="$(printf '%s' "${display_name}" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  if [ -f "${sd_file}" ] && [ "${WINDROSE_ENSURE_DIRECT_CONFIG:-0}" != "1" ]; then
    echo "ServerDescription.json present; leaving unchanged (set WINDROSE_ENSURE_DIRECT_CONFIG=1 to re-apply direct settings)."
    return 0
  fi

  echo "Writing ServerDescription.json (direct connection port ${direct_port}, password protected: ${protected})"
  cat >"${sd_file}" <<EOF
{
	"Version": 1,
	"DeploymentId": "0.0.0.0",
	"ServerDescription_Persistent": {
		"PersistentServerId": "",
		"InviteCode": "",
		"IsPasswordProtected": ${protected},
		"Password": "${password_escaped}",
		"ServerName": "${name_escaped}",
		"WorldIslandId": "",
		"MaxPlayerCount": 8,
		"UserSelectedRegion": "",
		"P2pProxyAddress": "127.0.0.1",
		"UseDirectConnection": true,
		"DirectConnectionServerAddress": "127.0.0.1",
		"DirectConnectionServerPort": ${direct_port},
		"DirectConnectionProxyAddress": "0.0.0.0",
		"AutoLoadLatestBackupIfHasBroken": true,
		"CanLaunchMultipleServerInstances": false
	}
}
EOF
}

ensure_server_description

GAME_ROOT="${GAME_ROOT_OVERRIDE:-${INSTALL_DIR}}"
export WINEPREFIX="${WINEPREFIX:-${INSTANCE_ROOT}/wineprefix}"
export WINEARCH="${WINEARCH:-win64}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=;winedbg.exe=d}"
XVFB_RUN_SCREEN="${XVFB_RUN_SCREEN:--screen 0 1024x768x24}"

echo "Executable: ${SERVER_EXE}"
echo "Instance root: ${INSTANCE_ROOT}"
echo "Game root: ${GAME_ROOT}"
echo "WINEPREFIX: ${WINEPREFIX}"

mkdir -p "${WINEPREFIX}" /tmp/runtime-steam
chmod 700 /tmp/runtime-steam
export XDG_RUNTIME_DIR=/tmp/runtime-steam

if [ ! -f "${WINEPREFIX}/system.reg" ]; then
  echo "Initializing wine prefix: ${WINEPREFIX}"
  WINEDEBUG=-all wineboot -i 2>&1 | tee -a "${RUN_LOG}" || true
fi

set +e
if command -v xvfb-run >/dev/null 2>&1; then
  ( cd "${GAME_ROOT}" && xvfb-run -a -s "${XVFB_RUN_SCREEN}" wine "${SERVER_EXE}" -log ) 2>&1 | tee -a "${RUN_LOG}"
else
  Xvfb "${XVFB_DISPLAY:-:99}" -screen 0 1024x768x24 -ac +extension RANDR -noreset -nolisten tcp >/tmp/xvfb.log 2>&1 &
  XVFB_PID=$!
  trap 'kill "${XVFB_PID}" >/dev/null 2>&1 || true' EXIT
  export DISPLAY="${XVFB_DISPLAY:-:99}"
  ( cd "${GAME_ROOT}" && wine "${SERVER_EXE}" -log ) 2>&1 | tee -a "${RUN_LOG}"
fi
exit_code=${PIPESTATUS[0]}
set -e

if [ "${exit_code}" -ne 0 ]; then
  dump_debug_artifacts
fi
exit "${exit_code}"
