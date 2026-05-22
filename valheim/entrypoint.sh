#!/bin/bash
set -e

SERVER_ROOT="${SERVER_DIR:-/home/steam/valheim}"
STEAMCMD="/home/steam/steamcmd.sh"
SERVER_DATA_SUBDIR="${SERVER_DATA_SUBDIR:-default}"
INSTANCE_ROOT="${SERVER_ROOT}/${SERVER_DATA_SUBDIR}"
GAME_INSTALL_DIR="${INSTANCE_ROOT}/serverfiles"
SAVEDIR="${INSTANCE_ROOT}/saves"

mkdir -p "$GAME_INSTALL_DIR" "$SAVEDIR"

# Install or update Valheim server when AUTO_UPDATE=1 or server binary missing
if [ "${AUTO_UPDATE:-1}" = "1" ] || [ ! -f "${GAME_INSTALL_DIR}/valheim_server.x86_64" ]; then
  echo "Installing/updating Valheim dedicated server (App ID 896660)..."
  $STEAMCMD +force_install_dir "$GAME_INSTALL_DIR" +login anonymous +app_update 896660 validate +quit
  echo "Valheim server install/update complete."
fi

if [ -z "${SERVER_PASS}" ] || [ "${#SERVER_PASS}" -lt 5 ]; then
  echo "ERROR: SERVER_PASS must be set and at least 5 characters."
  exit 1
fi

cd "$GAME_INSTALL_DIR"
# Run the server binary directly so we control args. Do NOT use -crossplay:
# Crossplay/PlayFab does not support localhost or local IP (causes "Connection failed").
export LD_LIBRARY_PATH=./linux64:${LD_LIBRARY_PATH:-}
export SteamAppId=892970
echo "Starting Valheim server (Steam backend): ${SERVER_NAME:-Valheim Server} (world: ${WORLD_NAME:-Dedicated})"
# Use -savedir so worlds and autobackups go to a per-instance path.

# Build optional world modifier arguments from environment variables so they can be
# configured per server (or via a future UI).
EXTRA_ARGS=()

if [ -n "${COMBAT_MODIFIER:-}" ]; then
  EXTRA_ARGS+=(-modifier combat "$COMBAT_MODIFIER")
fi

if [ -n "${DEATHPENALTY_MODIFIER:-}" ]; then
  EXTRA_ARGS+=(-modifier deathpenalty "$DEATHPENALTY_MODIFIER")
fi

if [ -n "${RESOURCES_MODIFIER:-}" ]; then
  EXTRA_ARGS+=(-modifier resources "$RESOURCES_MODIFIER")
fi

if [ -n "${RAIDS_MODIFIER:-}" ]; then
  EXTRA_ARGS+=(-modifier raids "$RAIDS_MODIFIER")
fi

if [ -n "${PORTALS_MODIFIER:-}" ]; then
  EXTRA_ARGS+=(-modifier portals "$PORTALS_MODIFIER")
fi

if [ -n "${WORLDSEED:-}" ]; then
  EXTRA_ARGS+=(-worldseed "$WORLDSEED")
fi

exec ./valheim_server.x86_64 \
  -name "${SERVER_NAME:-Valheim Server}" \
  -port "${PORT:-2456}" \
  -world "${WORLD_NAME:-Dedicated}" \
  -password "${SERVER_PASS}" \
  -public "${PUBLIC:-1}" \
  -savedir "$SAVEDIR" \
  "${EXTRA_ARGS[@]}"
