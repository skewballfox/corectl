import? '../common.just'

# Wolf source for the minimal rootless image (docker/wolf.Dockerfile, target runner-minimal)
wolf_repo := "https://github.com/skewballfox/wolf.git"
wolf_ref := "docker/layered-minimal-image"
wolf_tag := "gow/wolf:minimal"

# Wolf-UI source: upstream plus the optional rootless mode and the
# XDG_RUNTIME_DIR fix (fork branch `patches`)
ui_repo := "https://github.com/skewballfox/wolf-ui.git"
ui_ref := "patches"
ui_tag := "gow/wolf-ui:patches"
# The image Wolf's default config runs for the Wolf UI app
ui_upstream_image := "ghcr.io/games-on-whales/wolf-ui:main"

# GOW images (base, base-app, pulseaudio, apps) from the fork branch `patches`:
# upstream plus startup/script fixes and PulseAudio running as its own user
gow_repo := "https://github.com/skewballfox/gow.git"
gow_ref := "patches"
gow_base_tag := "gow/base:patches"
gow_base_app_tag := "gow/base-app:patches"
gow_base_emu_tag := "gow/base-emu:patches"
pulse_tag := "gow/pulseaudio:patches"

wolf_home := "/var/home/wolf"
wolf_quadlet_dir := wolf_home + "/.config/containers/systemd"
wolf_ctl := auth + " systemctl --user -M wolf@"
wolf_config := "/etc/wolf/cfg/config.toml"
autostart_dropin_dir := wolf_quadlet_dir + "/wolf.container.d"

# Owns /dev/uinput, /dev/uhid and the virtual controllers (see setup-udev and
# moonshine's), so wolf never needs `input`, which can read every physical
# keyboard and mouse (gos-plan.md 8.2). Shared with moonshine.just.
input_group := "wolf-input"

# Host NVIDIA driver version, from the loaded module, then nvidia-smi, then sysfs
nvidia_version_cmd := 'head -n1 /proc/driver/nvidia/version 2>/dev/null | grep -oP "Kernel Module\s+\K[0-9.]+" \
    || nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
    || cat /sys/module/nvidia/version 2>/dev/null'

# Name and tag of an image reference, defaulting the tag to latest
# (ghcr.io/games-on-whales/wolf-ui:main -> wolf-ui:main)
app_name(image) := file_name(image) + if file_name(image) =~ ':' { "" } else { ":latest" }

# https://github.com/<owner>/<repo>.git -> https://raw.githubusercontent.com/<owner>/<repo>
github_raw(repo) := replace_regex(replace_regex(repo, '^https://github\.com/', 'https://raw.githubusercontent.com/'), '\.git$', '')

# Create the system group for the virtual input devices
setup-input-group:
    getent group {{ input_group }} > /dev/null || {{ auth_shell }} groupadd -r {{ input_group }}

# wolf needs only the render node (it never opens card*), so no `video`, and
# input devices come through input_group, not `input`. create-sys-user only
# appends groups, so the list is set outright afterwards, which also takes
# back what older setups granted.
# Create the wolf system user with only render + input_group
setup-user: setup-input-group && (prepare-user-dir "wolf")
    just create-sys-user wolf -g render -g {{ input_group }} -d -q
    {{ auth_shell }} usermod -G render,{{ input_group }} wolf


# Wolf-specific recipe using the generic helper
setup-firewall:
    just create-firewall-service wolf \
        "Moonlight game and desktop streaming server" \
        -t 47984 -t 47989 -t 48010 \
        -u 47999 -u 48100 -u 48200

# Sign local container image using key file or tpm engine
sign-container tag sign_priv_path=sign_priv:
    {{ auth }} podman image sign \
        --sign-by-sigstore-private-key "{{ sign_priv_path }}" \
        "containers-storage:{{ tag }}"

# Build local Wolf container with host NVIDIA driver injection
build-containers tag="wolf-nvidia:latest" version=shell(nvidia_version_cmd) base_image="ghcr.io/games-on-whales/gstreamer:1.26.7": (build-nvidia-driver version) && build-wolf
    {{ auth }} podman image trust set -t accept {{ base_image }}

# Build + sign the NVIDIA userspace image backing nvidia-driver.volume, for the
# host's driver version (detected unless given). Shared with moonshine.just.
build-nvidia-driver version=shell(nvidia_version_cmd):
    @echo "NVIDIA driver version: {{ version }}"
    just build-and-sign \
        gow/nvidia-driver:latest \
        -f nvidia-driver.Dockerfile \
        -o "{{ container-store }}/wolf" \
        -b "NV_VERSION={{ version }}"

# Build + sign the minimal Wolf image from the fork. Wolf's heavy translation
# units take ~3.5G each in cc1plus and buildah can't cap memory rootless, so
# ninja's parallelism is capped instead (unbounded it OOMs a 32G host).
build-wolf tag=wolf_tag repo=wolf_repo ref=wolf_ref jobs="3":
    #!/usr/bin/env bash
    set -euxo pipefail
    cd {{ module_directory() }}
    SRC=$(mktemp -d)
    trap 'rm -rf "$SRC"' EXIT
    git clone --depth 1 --branch "{{ ref }}" "{{ repo }}" "$SRC"
    sed -i 's/ninja -C /ninja -j{{ jobs }} -C /g' "$SRC/docker/wolf.Dockerfile"

    just build-and-sign \
        "{{ tag }}" \
        -f docker/wolf.Dockerfile \
        -c "$SRC" \
        -o "{{ container-store }}/wolf" \
        -- "--target runner-minimal"

# Build + sign Wolf-UI from the fork, on the base-app from build-gow. Wolf only
# pulls an app image when it's missing, so once it's loaded and the config
# points at it (use-wolf-ui), the unsigned upstream image is never needed.
build-wolf-ui tag=ui_tag repo=ui_repo ref=ui_ref base_app=gow_base_app_tag:
    #!/usr/bin/env bash
    set -euxo pipefail
    cd {{ module_directory() }}
    SRC=$(mktemp -d)
    trap 'rm -rf "$SRC"' EXIT
    git clone --depth 1 --branch "{{ ref }}" "{{ repo }}" "$SRC"

    just build-and-sign \
        "{{ tag }}" \
        -c "$SRC" \
        -o "{{ container-store }}/wolf" \
        -b "BASE_APP_IMAGE=localhost/{{ base_app }}"

# Build + sign the GOW base, base-app and pulseaudio images from the fork
# (Ubuntu variant, like upstream's :edge/:master). Each one builds FROM the
# previous one in secure-build's local storage, so only the Ubuntu base image
# is pulled. Run before build-wolf-ui and build-gow-app, which build on it.
build-gow repo=gow_repo ref=gow_ref:
    #!/usr/bin/env bash
    set -euxo pipefail
    cd {{ module_directory() }}
    SRC=$(mktemp -d)
    trap 'rm -rf "$SRC"' EXIT
    git clone --depth 1 --branch "{{ ref }}" "{{ repo }}" "$SRC"
    OUT="{{ container-store }}/wolf"

    just build-and-sign "{{ gow_base_tag }}" -c "$SRC/images/base/build" -o "$OUT" \
        -b "IMAGE_SOURCE={{ repo }}"
    just build-and-sign "{{ gow_base_app_tag }}" -c "$SRC/images/base-app/build" -o "$OUT" \
        -b "BASE_IMAGE=localhost/{{ gow_base_tag }}"
    just build-and-sign "{{ pulse_tag }}" -c "$SRC/images/pulseaudio/build" -o "$OUT" \
        -b "BASE_IMAGE=localhost/{{ gow_base_tag }}" -b "IMAGE_SOURCE={{ repo }}"

# Build + sign a GOW app (apps/<name>) from the fork on the base-app from
# build-gow, load it for wolf and point Wolf's config at it in place of
# `image` (default: the upstream ghcr.io/games-on-whales/<name>:edge).
# es-de and pegasus build on base-emu, as upstream does; it's built here
# first if it's missing. Restart Wolf after.
build-gow-app name image="" repo=gow_repo ref=gow_ref:
    #!/usr/bin/env bash
    set -euxo pipefail
    cd {{ module_directory() }}
    IMAGE="{{ image }}"
    [ -n "$IMAGE" ] || IMAGE="ghcr.io/games-on-whales/{{ name }}:edge"
    TAG="gow/{{ name }}:patches"
    OUT="{{ container-store }}/wolf"
    SRC=$(mktemp -d)
    trap 'rm -rf "$SRC"' EXIT
    git clone --depth 1 --branch "{{ ref }}" "{{ repo }}" "$SRC"
    [ -d "$SRC/apps/{{ name }}/build" ] || { echo "no app '{{ name }}' in {{ repo }}@{{ ref }}" >&2; exit 1; }

    BASE="{{ gow_base_app_tag }}"
    case "{{ name }}" in
        es-de|pegasus)
            BASE="{{ gow_base_emu_tag }}"
            if ! just build_cmd -- podman image exists "localhost/$BASE"; then
                just build-and-sign "$BASE" -c "$SRC/images/base-emu/build" -o "$OUT" \
                    -b "BASE_APP_IMAGE=localhost/{{ gow_base_app_tag }}" -b "IMAGE_SOURCE={{ repo }}"
            fi
            ;;
    esac

    just build-and-sign "$TAG" -c "$SRC/apps/{{ name }}/build" -o "$OUT" \
        -b "BASE_APP_IMAGE=localhost/$BASE" -b "IMAGE_SOURCE={{ repo }}"
    just wolf::load-image "$TAG"
    just wolf::use-app-image "$IMAGE" "$TAG"
    echo "Restart Wolf to pick it up"

# Copy a signed image from the builder's output into the wolf user's storage.
# The source is checked against the secure-build key (dir: is rejected by the
# system policy, so a scoped policy does the verification), and the signature
# is carried over so podman's containers-storage signedBy rule accepts it.
load-image tag=wolf_tag:
    #!/usr/bin/env bash
    set -euxo pipefail
    FULL_TAG="localhost/$(echo "{{ tag }}" | sed -E 's|^localhost/||')"
    SRC_DIR="{{ container-store }}/wolf/$(echo "{{ tag }}" | tr '/:' '_')"
    POLICY=$(mktemp)
    trap 'rm -f "$POLICY"' EXIT
    cat > "$POLICY" <<EOF
    {"default": [{"type": "reject"}],
     "transports": {"dir": {"": [{"type": "signedBy", "keyType": "GPGKeys",
       "keyPath": "{{ gpg_pub_link_path }}",
       "signedIdentity": {"type": "exactReference", "dockerReference": "$FULL_TAG"}}]}}}
    EOF
    chmod 644 "$POLICY"
    # secureblue denies user_namespace create from unconfined_t, which is where
    # both skopeo and a podman exec'd straight from run0 end up; launched via
    # the login shell, podman unshare can create it and skopeo runs inside.
    CMD=$(printf '%q ' env XDG_RUNTIME_DIR="/run/user/$(id -u wolf)" \
        podman unshare skopeo copy --policy "$POLICY" "dir:$SRC_DIR" "containers-storage:$FULL_TAG")
    {{ shell_as("wolf") }} "$CMD"

load-images: (load-image "gow/nvidia-driver:latest") (load-image wolf_tag) (load-image ui_tag) (load-image pulse_tag)

# Point the apps in Wolf's config that run `image` at the local signed `tag`.
# Also matches mirror-app's copy of `image` (localhost/gow/<name>:<tag>), so a
# mirrored app can be switched to a fork build later.
# Wolf writes TOML strings single-quoted; accept either quote style.
[private]
use-app-image image tag:
    {{ auth }} sed -i -E "s#([\"'])({{ image }}|localhost/gow/{{ app_name(image) }})\\1#\\1localhost/{{ tag }}\\1#" "{{ wolf_config }}"
    {{ auth }} grep -q "localhost/{{ tag }}" "{{ wolf_config }}" \
        || { echo "{{ image }} not found in {{ wolf_config }}; set the app's image to localhost/{{ tag }} by hand" >&2; exit 1; }
    @echo "Wolf config now uses localhost/{{ tag }}"

# Point Wolf's config at the locally built Wolf-UI. The config only exists
# once Wolf has started, and Wolf rewrites it from memory, so wait for it,
# then edit it with Wolf stopped and start Wolf again if it was running.
use-wolf-ui tag=ui_tag image=ui_upstream_image:
    #!/usr/bin/env bash
    set -euxo pipefail
    CONFIG=/etc/wolf/cfg/config.toml
    for _ in $(seq 120); do
        {{ auth }} test -f "$CONFIG" && break
        sleep 1
    done
    {{ auth }} test -f "$CONFIG" || { echo "$CONFIG missing: start Wolf once, then rerun" >&2; exit 1; }
    if {{ auth }} grep -q "localhost/{{ tag }}" "$CONFIG"; then
        echo "Wolf config already uses localhost/{{ tag }}"
        exit 0
    fi
    WAS_ACTIVE=false
    if {{ wolf_ctl }} is-active --quiet wolf.service; then
        WAS_ACTIVE=true
        {{ wolf_ctl }} stop wolf.service
    fi
    just wolf::use-app-image "{{ image }}" "{{ tag }}"
    if [ "$WAS_ACTIVE" = true ]; then
        {{ wolf_ctl }} start wolf.service
    fi

# Wolf runs each app from its own image, but the host policy only runs images
# signed by secure-build, so an upstream pull is rejected. Rebuild the image as
# a signed local copy (localhost/gow/<name>), load it for wolf and point Wolf's
# config at it; Wolf only pulls when the image is missing. Restart Wolf after.
mirror-app image="ghcr.io/games-on-whales/wolf-ui:main":
    #!/usr/bin/env bash
    set -euxo pipefail
    cd {{ module_directory() }}
    NAME="{{ image }}"
    NAME="${NAME##*/}"
    [[ "$NAME" == *:* ]] || NAME="$NAME:latest"
    TAG="gow/$NAME"
    CTX=$(mktemp -d)
    trap 'rm -rf "$CTX"' EXIT
    echo "FROM {{ image }}" > "$CTX/Dockerfile"
    just build-and-sign "$TAG" -c "$CTX" -o "{{ container-store }}/wolf"
    just wolf::load-image "$TAG"
    just wolf::use-app-image "{{ image }}" "$TAG"
    echo "Restart Wolf to pick it up"

# uhid (DualSense emulation) isn't loaded by default; it's loaded now and at boot.
# SELinux on secureblue won't let a run0 session exec udevadm (udev_exec_t
# entrypoint denied), so the devices' uevents are replayed instead; udevd
# reloads changed rules on its own before handling the next event.
# Upstream's rules give /dev/uinput, /dev/uhid and the virtual controllers to
# `input`; they're rewritten to input_group, and the install fails if upstream
# stops matching that pattern.
# Install Wolf's udev rules: /dev/uinput + /dev/uhid for input_group (wolf is
# a member), virtual controllers kept off the host seat.
setup-udev repo=wolf_repo ref=wolf_ref: setup-input-group
    curl -fsSL "{{ github_raw(repo) }}/{{ ref }}/85-wolf.rules" | sed 's/GROUP="input"/GROUP="{{ input_group }}"/g' | {{ auth }} tee /etc/udev/rules.d/85-wolf.rules > /dev/null
    {{ auth }} grep -q 'GROUP="{{ input_group }}"' /etc/udev/rules.d/85-wolf.rules && ! {{ auth }} grep -q '"input"' /etc/udev/rules.d/85-wolf.rules \
        || { echo "85-wolf.rules no longer assigns GROUP=\"input\"; update setup-udev" >&2; exit 1; }
    echo uhid | {{ auth }} tee /etc/modules-load.d/uhid.conf > /dev/null
    {{ auth }} systemctl restart systemd-modules-load.service
    echo change | {{ auth }} tee /sys/class/misc/uinput/uevent /sys/class/misc/uhid/uevent > /dev/null

# nvidia-driver.volume supersedes nvidia-driver-populate.container, which is
# removed. Only what was just installed is chowned: a recursive chown of the
# home would flatten the subuid ownership inside the rootless image store.
# Wolf runs as the wolf user (rootless, keep-id) and writes its config, certs
# and app state in /etc/wolf.
# Quadlet creates volumes with --ignore, so existing ones would be kept; they
# are dropped so the next start recreates them from the current units:
# nvidia-driver-vol may be pinned to a previous driver image, and an older
# wolf-runtime-vol may have been created by a container (locked-out top dir,
# see wolf/wolf-runtime.volume). pulse-socket-vol is no longer used. The
# oneshot volume units are stopped too, or they stay "active" and won't
# recreate their volumes.
# Deploy the Wolf quadlets to the wolf user's systemd directory
install: && (rm-volume "nvidia-driver-vol") (rm-volume "wolf-runtime-vol") (rm-volume "pulse-socket-vol")
    {{ auth }} mkdir -p "{{ wolf_quadlet_dir }}" /etc/wolf
    {{ auth }} cp wolf/pulseaudio.container wolf/wolf-runtime.volume wolf/wolf.container nvidia-driver.volume "{{ wolf_quadlet_dir }}/"
    {{ auth }} rm -f "{{ wolf_quadlet_dir }}/nvidia-driver-populate.container"
    {{ auth }} cp container_conf.toml "{{ wolf_home }}/{{ user_storage }}"
    {{ auth }} chown -R wolf:wolf "{{ wolf_home }}/.config" /etc/wolf
    {{ auth }} chmod 0750 /etc/wolf
    {{ wolf_ctl }} daemon-reload
    -{{ wolf_ctl }} stop nvidia-driver-volume.service wolf-runtime-volume.service

# Remove one of the wolf user's podman volumes, if it exists and isn't in use.
# Shared with moonshine.just.
[private]
rm-volume vol:
    {{ shell_as("wolf") }} "$(printf '%q ' env XDG_RUNTIME_DIR="/run/user/$(id -u wolf)" podman volume rm {{ vol }})" 2>/dev/null \
        || echo "{{ vol }} not removed (absent, or in use: stop Wolf and moonshine, then rerun install)"

# Master recipe to build image, configure firewall, user, quadlets, and start services
setup: setup-user setup-firewall setup-udev build-containers build-gow build-wolf-ui install load-images && use-wolf-ui
    {{ wolf_ctl }} start pulseaudio.service wolf.service
    @echo "Wolf stack successfully deployed!"

# Start Wolf; pulseaudio and the NVIDIA driver volume come up with it (Requires=).
# Clears earlier failures first so a start-limit hit doesn't block it.
start:
    -{{ wolf_ctl }} reset-failed wolf.service pulseaudio.service nvidia-driver-volume.service wolf-runtime-volume.service
    {{ wolf_ctl }} start wolf.service

# Stop Wolf (it stops its app containers on exit) and its pulseaudio sidecar
stop:
    {{ wolf_ctl }} stop wolf.service pulseaudio.service

# Stop the stack if any of it is up (including restart loops), otherwise start it
toggle:
    #!/usr/bin/env bash
    STATES=$({{ wolf_ctl }} is-active wolf.service pulseaudio.service || true)
    if grep -qvE '^(inactive|failed)$' <<< "$STATES"; then
        {{ wolf_ctl }} stop wolf.service pulseaudio.service && echo "Wolf stopped"
    else
        {{ wolf_ctl }} reset-failed wolf.service pulseaudio.service nvidia-driver-volume.service wolf-runtime-volume.service || true
        {{ wolf_ctl }} start wolf.service && echo "Wolf started"
    fi

status:
    -{{ wolf_ctl }} status --no-pager wolf.service pulseaudio.service

# Start Wolf at boot (on) or only on demand (off) via a quadlet drop-in
autostart state="on":
    {{ if state == "on" { \
        auth + " install -d -o wolf -g wolf \"" + autostart_dropin_dir + "\" && " + \
        "printf '[Install]\\nWantedBy=default.target\\n' | " + auth + " install -o wolf -g wolf -m 0644 /dev/stdin \"" + autostart_dropin_dir + "/autostart.conf\"" \
    } else if state == "off" { \
        auth + " rm -f \"" + autostart_dropin_dir + "/autostart.conf\"" \
    } else { \
        error("usage: just wolf autostart [on|off]") \
    } }}
    {{ wolf_ctl }} daemon-reload
    @echo "Wolf autostart: {{ state }}"
