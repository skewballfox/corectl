import? '../common.just'

# Moonshine + a Steam app container (configs in moonshine/), run by the
# existing `wolf` service account (create it first with `just wolf setup-user`).
# The archived Wolf stack (wolf.just, wolf/) uses the same ports, so `start`
# stops it first.

# Moonshine source: the fork branch `patches`, upstream plus the kcmp(2)
# fallback, so the container needs no seccomp change for DMA-BUF imports.
# The quadlet's Image= names moonshine_tag: change both together.
moonshine_repo := "https://github.com/skewballfox/moonshine.git"
moonshine_ref := "patches"
moonshine_tag := "moonshine/moonshine:" + moonshine_ref
steam_tag := "moonshine/steam:latest"

svc_home := "/var/home/wolf"
quadlet_dir := svc_home + "/.config/containers/systemd"
ctl := auth + " systemctl --user -M wolf@"

# `ref` is resolved to its commit here (the last line is a tag's peeled
# commit), which pins the clone and makes a moved branch rebuild instead of
# reusing the cached clone layer.
# Build + sign the moonshine image (moonshine + the WSI Vulkan layer) at `ref`
[working-directory('moonshine')]
build-moonshine ref=moonshine_ref repo=moonshine_repo:
    just build-and-sign "moonshine/moonshine:{{ ref }}" \
        -f moonshine.Dockerfile \
        -o "{{ container-store }}/wolf" \
        -b "MOONSHINE_REPO={{ repo }}" -b "MOONSHINE_REF={{ ref }}" \
        -b "MOONSHINE_COMMIT=$(git ls-remote "{{ repo }}" "{{ ref }}" | tail -n1 | cut -f1)"

# Takes the WSI layer from the moonshine image, so build-moonshine runs first.
# Build + sign the Steam image
[working-directory('moonshine')]
build-steam ref=moonshine_ref:
    just build-and-sign "{{ steam_tag }}" \
        -f steam.Dockerfile \
        -o "{{ container-store }}/wolf" \
        -b "MOONSHINE_IMAGE=localhost/moonshine/moonshine:{{ ref }}"

# NVIDIA driver volume image, moonshine, then Steam
build-containers:
    just wolf::build-nvidia-driver
    just moonshine::build-moonshine
    just moonshine::build-steam

# Copy the signed images into the wolf user's storage (see wolf::load-image)
load-images:
    just wolf::load-image gow/nvidia-driver:latest
    just wolf::load-image {{ moonshine_tag }}
    just wolf::load-image {{ steam_tag }}

# Moonshine's video/control/audio ports differ from Wolf's (47998-48000 udp)
setup-firewall:
    just create-firewall-service moonshine \
        "Moonshine game streaming server (Moonlight)" \
        -t 47984 -t 47989 -t 48010 \
        -u 47998 -u 47999 -u 48000

# Upstream's 60-moonshine.rules tags moonshine's virtual pads uaccess, which
# hands them to whoever sits at seat0; these keep them off the desktop seat.
# Matching moonshine's device names isn't enough: whoever holds /dev/uinput or
# /dev/uhid picks the name, so a compromised moonshine could type into the
# desktop session. Every uinput and uhid device goes to seat9 instead, which
# also takes other virtual devices (input remappers, Bluetooth LE HID, which
# bluez creates through uhid) off the desktop seat.
# Only /dev/uinput and /dev/uhid go to wolf::input_group (wolf-input).
# The input and hidraw nodes keep the default root:input: moonshine writes
# through the uinput/uhid handles and never opens them, and wolf-input on
# them would let wolf read remapper output and Bluetooth LE keyboards.
# run0 can't exec udevadm on secureblue (see wolf::setup-udev), so the uevents
# are replayed instead; udevd picks up the new rules on its own.
# udev rules: /dev/uinput + /dev/uhid for wolf-input, all virtual input devices on seat9
setup-udev:
    just wolf::setup-input-group
    {{ auth }} install -m 0644 moonshine/udev/85-moonshine.rules /etc/udev/rules.d/85-moonshine.rules
    printf 'uinput\nuhid\n' | {{ auth }} tee /etc/modules-load.d/moonshine.conf > /dev/null
    {{ auth }} systemctl restart systemd-modules-load.service
    echo change | {{ auth }} tee /sys/class/misc/uinput/uevent /sys/class/misc/uhid/uevent > /dev/null

# selinux/moonshine: the bus proxy's domain (moonshine.te, built with
# selinux-policy-devel's Makefile; install needs its .fc for /etc/moonshine's
# label) and moonshine's container type. selinux/apps: the app container
# types. The .cil types build on container-selinux's udica templates, loaded
# in the same transaction since the types inherit from them.
# semodule (like restorecon and journalctl below) goes through auth_shell:
# plain run0 execs it straight from unconfined_t, which may not enter
# semanage_exec_t, so it fails with exit 203.
# The types grant the GPU nodes themselves, so no boolean is needed;
# container_use_xserver_devices (NVIDIA for every container_t) and
# container_use_devices (every device) are best left off.
# SELinux modules: the bus proxy's domain and the moonshine and app container types
setup-selinux:
    #!/usr/bin/env bash
    set -euxo pipefail
    build=$(mktemp -d)
    trap 'rm -rf "$build"' EXIT
    cp {{ module_directory() }}/moonshine/selinux/moonshine/* {{ module_directory() }}/moonshine/selinux/apps/*.cil \
        /usr/share/udica/templates/base_container.cil /usr/share/udica/templates/net_container.cil "$build/"
    make -s -C "$build" -f /usr/share/selinux/devel/Makefile moonshine.pp
    {{ auth_shell }} semodule -i "$build/moonshine.pp" "$build"/*.cil

# Only what was just installed is chowned: a recursive chown of the home would
# flatten the subuid ownership inside the rootless image store. The bus proxy
# is root's, outside anything the service user or a container can write.
# Config and launcher are root's too: systemd runs launch-steam on the host,
# so neither the wolf user nor the container may change it. Moonshine (wolf,
# keep-id) writes its cert, key and paired clients in state/; keys from before
# they moved there are moved over (keeps paired clients paired).
# /etc/moonshine gets container_file_t from selinux/moonshine/moonshine.fc (setup-selinux).
# nvidia-driver-vol pins the image it was created from, so it's dropped for the
# next start to use the current driver image. Keeps the Steam home.
# Deploy the quadlets, the bus proxy, the moonshine config and the Steam launcher
install:
    {{ auth }} mkdir -p "{{ quadlet_dir }}" "{{ svc_home }}/.config/systemd/user"
    {{ auth }} cp moonshine/quadlets/moonshine.container moonshine/quadlets/moonshine-runtime.volume \
        moonshine/quadlets/moonshine-x11.volume moonshine/quadlets/moonshine-steam-home.volume \
        moonshine/quadlets/moonshine-bus.volume nvidia-driver.volume "{{ quadlet_dir }}/"
    {{ auth }} cp moonshine/quadlets/moonshine-bus-proxy.service "{{ svc_home }}/.config/systemd/user/"
    {{ auth }} cp container_conf.toml "{{ svc_home }}/{{ user_storage }}"
    {{ auth }} chown -R wolf:wolf "{{ svc_home }}/.config"
    {{ auth }} install -D -m 0755 moonshine/scripts/moonshine-bus-proxy.py /usr/local/libexec/moonshine-bus-proxy
    {{ auth }} install -d -o root -g wolf -m 0750 /etc/moonshine
    {{ auth }} install -d -o wolf -g wolf -m 0750 /etc/moonshine/state
    {{ auth }} install -o root -g wolf -m 0640 moonshine/config/moonshine-config.toml /etc/moonshine/config.toml
    {{ auth }} install -o root -g wolf -m 0750 moonshine/scripts/moonshine-launch-steam.sh /etc/moonshine/launch-steam
    {{ auth }} find /etc/moonshine -maxdepth 1 \( -name cert.pem -o -name key.pem \) -exec mv -n -t /etc/moonshine/state {} +
    {{ auth_shell }} restorecon -RF /etc/moonshine
    {{ ctl }} daemon-reload
    -{{ ctl }} stop nvidia-driver-volume.service
    just wolf::rm-volume nvidia-driver-vol

# Build, deploy and start everything (needs the wolf account: just wolf setup-user)
setup: setup-udev setup-firewall setup-selinux build-containers install load-images start

# Start moonshine; stops the Wolf stack first, which uses the same ports
start:
    -{{ ctl }} stop wolf.service pulseaudio.service
    -{{ ctl }} reset-failed moonshine.service moonshine-bus-proxy.service nvidia-driver-volume.service moonshine-runtime-volume.service moonshine-x11-volume.service moonshine-steam-home-volume.service moonshine-bus-volume.service
    {{ ctl }} start moonshine.service

# Stop moonshine, its running app (the transient unit it started) and the bus proxy
stop:
    -{{ ctl }} stop moonshine-session.service
    {{ ctl }} stop moonshine.service moonshine-bus-proxy.service

status:
    -{{ ctl }} status --no-pager moonshine.service moonshine-bus-proxy.service moonshine-session.service

# Needs no root: the journal is readable unprivileged here. USER_UNIT adds the
# user manager's own lines (start, exit status, restart limit). AVC records
# carry no uid, so they're matched by the types from setup-selinux instead.
# Hostname, pids, moonshine's and podman's own timestamps and podman's image
# labels are stripped. Prints the last 100 entries and returns; other `args`
# go to journalctl instead (`logs --since -1h`, `logs -f` to follow).
# `--crash`: the last run of whichever unit failed most recently, from its
# job's "Starting" line (MESSAGE_ID 7d4958e8…) to its "Failed with result"
# (d9b373ed…, UNIT_RESULT set).
# Moonshine's, the bus proxy's (refused calls), the running app's logs and their AVC denials
[positional-arguments]
logs *args:
    #!/usr/bin/env bash
    set -euo pipefail
    uid=$(id -u wolf)
    units=(moonshine.service moonshine-bus-proxy.service moonshine-session.service)
    matches=()
    for unit in "${units[@]}"; do
        matches+=(_UID="$uid" _SYSTEMD_USER_UNIT="$unit" + _UID="$uid" USER_UNIT="$unit" +)
    done
    # Last entry matching the given fields among the units' manager lines, as
    # "<epoch seconds> <unit>"
    last() {
        local m=()
        for unit in "${units[@]}"; do m+=(_UID="$uid" USER_UNIT="$unit" "$@" +); done
        journalctl --no-pager -q -o json -n 1 "${m[@]:0:${#m[@]}-1}" \
            | jq -r '"\(.__REALTIME_TIMESTAMP | tonumber / 1e6 | floor) \(.USER_UNIT)"'
    }
    if [ "${1:-}" = --crash ]; then
        shift
        read -r failed_at unit < <(last MESSAGE_ID=d9b373ed55a64feb8242e02dbe79a49c) \
            || { echo "no failed run of ${units[*]} in the journal" >&2; exit 0; }
        started_at=$(journalctl --no-pager -q -o json -n 1 --until "@$((failed_at + 1))" \
            _UID="$uid" USER_UNIT="$unit" MESSAGE_ID=7d4958e842da4a758f6c1cdc7b36dcc5 \
            | jq -r '.__REALTIME_TIMESTAMP | tonumber / 1e6 | floor')
        echo "$unit failed at $(date -d "@$failed_at" '+%b %d %T')" >&2
        set -- --since "@$started_at" --until "@$((failed_at + 2))" "$@"
    fi
    [ $# -gt 0 ] || set -- -n 100
    journalctl --no-pager --no-hostname -o short-precise "$@" "${matches[@]}" _AUDIT_TYPE=1400 | awk '
        /: AVC avc: +denied/ && !/(moonshine_container|gow_sandbox|gpu_container)\.|moonshine_bus_t/ { next }
        {
            sub(/\[[0-9]+\]: /, ": ")
            sub(/: [0-9-]+T[0-9:.]+Z +/, ": ")
            sub(/: [0-9-]+ [0-9:.]+ [+-][0-9]+ [A-Z]+ m=[+][0-9.]+ /, ": ")
            sub(/ [(]image=.*[)]$/, "")
            print
            fflush()
        }'
