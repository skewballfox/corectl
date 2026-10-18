#!/bin/bash
# Run Steam on its own session bus; on stop (moonshine stops the app's unit,
# podman forwards SIGTERM) ask Steam to shut down cleanly so it saves state.
set -euo pipefail

# Steam fails on a fresh home without it
# (https://github.com/ValveSoftware/steam-for-linux/issues/6492)
mkdir -p "$HOME/.steam/ubuntu12_32/steam-runtime"

dbus-run-session -- steam "$@" &
STEAM_PID=$!
trap 'steam -shutdown || true' TERM INT
# wait returns early when the trap fires; keep waiting for Steam to exit
while kill -0 "$STEAM_PID" 2>/dev/null; do
    wait "$STEAM_PID" || true
done
