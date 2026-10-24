#!/bin/bash
# Moonshine app launcher for Steam, installed as /etc/moonshine/launch-steam.
#
# Moonshine starts an app as a transient unit in the service user's systemd
# manager, but first resolves the program with `which` inside its own
# container. /etc/moonshine is mounted at the same path in both, so this one
# file passes that check and is what the host's systemd runs.
#
# Runs on the host as the service user; arguments go to Steam.
#
# Without a stream (just moonshine update-steam), moonshine passes no display,
# and Steam would stop after its client update. It gets Xvfb's instead
# (moonshine-xvfb.container), and logs in and works through its downloads
# until a stream starts and replaces it.
set -euo pipefail

# Moonshine's environment carries its own runtime dir (/run/moonshine, where
# the Steam image already points); podman needs the service user's
XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_RUNTIME_DIR
# ... and systemctl --user the host's bus there, not the proxy's path inside
# moonshine's container, if moonshine's environment carries it
unset DBUS_SESSION_BUS_ADDRESS

# moonshine sets one of these for each session
if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
    session=true
    # A Steam from between streams: let it shut down and save, which
    # --replace's 10 s may not. Then its X server isn't needed.
    podman stop --ignore --time 30 moonshine-steam > /dev/null
    systemctl --user stop moonshine-xvfb.service 2> /dev/null || true
else
    session=false
    # Running already, for a stream or from an earlier run: that one stays
    if [ -n "$(podman ps -q --filter name=^moonshine-steam\$)" ]; then
        echo "Steam is already running (a stream, or between streams): leaving it" >&2
        exit 0
    fi
    systemctl --user start moonshine-xvfb.service
    # Started means the container is up, not that Xvfb's socket is there yet
    socket=$(podman volume inspect --format '{{.Mountpoint}}' moonshine-xvfb-vol)/X99
    for _ in $(seq 50); do
        [ -S "$socket" ] && break
        sleep 0.2
    done
    [ -S "$socket" ] || { echo "Xvfb's socket didn't appear: systemctl --user status moonshine-xvfb" >&2; exit 1; }
    # No window to show: started minimized, not in Big Picture (the image's default)
    [ $# -gt 0 ] || set -- -silent
fi

ARGS=(--rm --replace --name moonshine-steam)
# Moonshine tells games apart (focus, Steam's controller routing) by walking
# /proc from each window's PID, so Steam must be in its PID namespace, as it
# would be under gamescope. Not needed between streams, so moonshine needn't
# be running then.
! "$session" || ARGS+=(--pid=container:moonshine)
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
    -v moonshine-steam-home-vol:/home/retro)
# Xwayland's socket in a stream, Xvfb's (display :99) between them
if "$session"; then
    ARGS+=(-v moonshine-x11-vol:/tmp/.X11-unix)
else
    ARGS+=(-v moonshine-xvfb-vol:/tmp/.X11-unix -e DISPLAY=:99)
fi
# The games disks, each mounted at /var/mnt/games/<name> (podman binds
# recursively). An unmounted disk shows as its empty, root-owned mountpoint:
# Steam marks that library unavailable rather than installing into /var.
ARGS+=(-v /var/mnt/games:/mnt/games)
# Moonshine creates a client's pads when it connects, after Steam has started,
# so the directory is bound rather than single nodes: new ones show up live.
# Rootless podman has no device cgroup, so access is by file mode: of the
# host's input nodes, only moonshine's pads are wolf-input (85-moonshine.rules).
# No hidraw: those nodes sit directly in /dev, one per device.
ARGS+=(-v /dev/input:/dev/input:ro)
# udev can't announce them here: its netlink events stay in the host's network
# namespace (pasta gives Steam its own), and there's no /run/udev database to
# say a node is a joystick. SDL, which Steam and most games use for pads,
# watches /dev/input with inotify instead and reads each node's capabilities.
ARGS+=(-e SDL_JOYSTICK_DISABLE_UDEV=1)

# moonshine's per-session variables, from the unit environment
# (-e NAME forwards NAME only when it's set)
for name in PULSE_SERVER PULSE_RUNTIME_PATH DISPLAY WAYLAND_DISPLAY \
    ENABLE_FERRISCOPE_WSI DISABLE_GAMESCOPE_WSI DXVK_HDR PROTON_USE_PIPEWIRE \
    XDG_CURRENT_DESKTOP GAMESCOPE_WAYLAND_DISPLAY STEAM_GAME_DISPLAY_0 \
    STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER STEAM_GAMESCOPE_HDR_SUPPORTED \
    MOONSHINE_CLIENT_WIDTH MOONSHINE_CLIENT_HEIGHT MOONSHINE_CLIENT_FRAMERATE; do
    ARGS+=(-e "$name")
done

# podman forwards SIGTERM from the unit stop to Steam (steam-entrypoint)
exec podman run "${ARGS[@]}" localhost/moonshine/steam:latest "$@"
