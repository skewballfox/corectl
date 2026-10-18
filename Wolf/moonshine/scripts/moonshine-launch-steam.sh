#!/bin/bash
# Moonshine app launcher for Steam, installed as /etc/moonshine/launch-steam.
#
# Moonshine starts an app as a transient unit in the service user's systemd
# manager, but first resolves the program with `which` inside its own
# container. /etc/moonshine is mounted at the same path in both, so this one
# file passes that check and is what the host's systemd runs.
#
# Runs on the host as the service user; arguments go to Steam.
set -euo pipefail

ARGS=(--rm --replace --name moonshine-steam)
# Moonshine tells games apart (focus, Steam's controller routing) by walking
# /proc from each window's PID, so Steam must be in its PID namespace, as it
# would be under gamescope
ARGS+=(--pid=container:moonshine)
# retro (1000) = the service user: moonshine's sockets are only usable by it
ARGS+=("--userns=keep-id:uid=1000,gid=1000" --group-add=keep-groups)
# pressure-vessel needs bwrap: no caps, but the SELinux type and unmasked
# /proc from gos-plan.md 7.5 (T5). gow_sandbox (selinux/apps/gow_sandbox.cil)
# is the GPU container type plus bwrap's mounts.
ARGS+=(--cap-drop=ALL --security-opt=no-new-privileges
    --security-opt=label=type:gow_sandbox.process --security-opt=unmask=/proc/*)
ARGS+=(--network=pasta)
# steamwebhelper (Chromium) keeps its shared memory in /dev/shm; podman's 64m
# default leaves it under Chromium's 64MB minimum
ARGS+=(--shm-size=1g)
ARGS+=(--device=/dev/dri --device=/dev/nvidia0 --device=/dev/nvidiactl
    --device=/dev/nvidia-modeset --device=/dev/nvidia-uvm)
ARGS+=(-v nvidia-driver-vol:/usr/nvidia:ro
    -v moonshine-runtime-vol:/run/moonshine
    -v moonshine-x11-vol:/tmp/.X11-unix
    -v moonshine-steam-home-vol:/home/retro)

# moonshine's per-session variables, from the unit environment
# (-e NAME forwards NAME only when it's set)
for name in PULSE_SERVER PULSE_RUNTIME_PATH DISPLAY WAYLAND_DISPLAY MOONSHINE_WAYLAND_DISPLAY \
    ENABLE_MOONSHINE_WSI MOONSHINE_HDR DXVK_HDR PROTON_USE_PIPEWIRE \
    XDG_CURRENT_DESKTOP GAMESCOPE_WAYLAND_DISPLAY STEAM_GAME_DISPLAY_0 \
    STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER STEAM_GAMESCOPE_FANCY_SCALING_SUPPORT \
    STEAM_GAMESCOPE_NIS_SUPPORTED STEAM_GAMESCOPE_VRR_SUPPORTED STEAM_GAMESCOPE_HDR_SUPPORTED \
    MOONSHINE_CLIENT_WIDTH MOONSHINE_CLIENT_HEIGHT MOONSHINE_CLIENT_FRAMERATE; do
    ARGS+=(-e "$name")
done

# podman forwards SIGTERM from the unit stop to Steam (steam-entrypoint)
exec podman run "${ARGS[@]}" localhost/moonshine/steam:latest "$@"
