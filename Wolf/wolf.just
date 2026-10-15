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

setup-user:
    #!/usr/bin/env bash
    just create-sys-user wolf -g render -g input -g video -d -q
    just prepare-user-dir wolf


# Wolf-specific recipe using the generic helper
setup-firewall:
    just create-firewall-service wolf \
        desc="Moonlight game and desktop streaming server" \
        -t 47984 -t 47989 -t 48010 \
        -u 47999 -u 48100 -u 48200

sign-container tag sign_priv_path=sign_priv:
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Sign local container image using key file or tpm engine
    {{ auth }} podman image sign \
        --sign-by-sigstore-private-key "{{ sign_priv_path }}" \
        "containers-storage:{{ tag }}"
# Build local Wolf container with host NVIDIA driver injection
build-containers tag="wolf-nvidia:latest" version="" base_image="ghcr.io/games-on-whales/gstreamer:1.26.7": && build-wolf
    #!/usr/bin/env bash
    cd {{ module_directory() }}
    NV_VER="{{ version }}"
    DEST_ROOT="{{ container-store }}/wolf"
    
    # Detect NVIDIA driver version on host
    if [ -z "$NV_VER" ]; then
        NV_VER=$(cat /proc/driver/nvidia/version 2>/dev/null | head -n1 | grep -oP 'Kernel Module\s+\K[0-9.]+' \
      || nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
      || cat /sys/module/nvidia/version 2>/dev/null)
    fi

    {{ auth }} podman image trust set -t accept {{ base_image }}
    echo "Detected host NVIDIA driver version: $NV_VER"

    just build-and-sign \
        gow/nvidia-driver:latest \
        -f "nvidia-driver.Dockerfile" \
        -o "$DEST_ROOT" \
        -b "NV_VERSION=$NV_VER" \

# Build + sign the minimal Wolf image from the fork. Wolf's heavy translation
# units take ~3.5G each in cc1plus and buildah can't cap memory rootless, so
# ninja's parallelism is capped instead (unbounded it OOMs a 32G host).
build-wolf tag=wolf_tag repo=wolf_repo ref=wolf_ref jobs="3":
    #!/usr/bin/env bash
    set -euo pipefail
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
    set -euo pipefail
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
    set -euo pipefail
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
    set -euo pipefail
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
    set -euo pipefail
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
    #!/usr/bin/env bash
    set -euo pipefail
    CONFIG=/etc/wolf/cfg/config.toml
    NAME="{{ image }}"
    NAME="${NAME##*/}"
    [[ "$NAME" == *:* ]] || NAME="$NAME:latest"
    MIRROR="localhost/gow/$NAME"
    {{ auth }} sed -i -E "s#([\"'])({{ image }}|$MIRROR)\\1#\\1localhost/{{ tag }}\\1#" "$CONFIG"
    {{ auth }} grep -q "localhost/{{ tag }}" "$CONFIG" \
        || { echo "{{ image }} not found in $CONFIG; set the app's image to localhost/{{ tag }} by hand" >&2; exit 1; }
    echo "Wolf config now uses localhost/{{ tag }}"

# Point Wolf's config at the locally built Wolf-UI. The config only exists
# once Wolf has started, and Wolf rewrites it from memory, so wait for it,
# then edit it with Wolf stopped and start Wolf again if it was running.
use-wolf-ui tag=ui_tag image=ui_upstream_image:
    #!/usr/bin/env bash
    set -euo pipefail
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
    set -euo pipefail
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

# Install Wolf's udev rules: /dev/uinput + /dev/uhid for group input (wolf is
# a member), virtual controllers kept off the host seat.
setup-udev repo=wolf_repo ref=wolf_ref:
    #!/usr/bin/env bash
    set -euo pipefail
    RAW=$(echo "{{ repo }}" | sed -E 's|^https://github.com/|https://raw.githubusercontent.com/|; s|\.git$||')
    curl -fsSL "$RAW/{{ ref }}/85-wolf.rules" | {{ auth }} tee /etc/udev/rules.d/85-wolf.rules > /dev/null
    # uhid (DualSense emulation) isn't loaded by default; load it now and at boot
    echo uhid | {{ auth }} tee /etc/modules-load.d/uhid.conf > /dev/null
    {{ auth }} systemctl restart systemd-modules-load.service
    # SELinux on secureblue won't let a run0 session exec udevadm (udev_exec_t
    # entrypoint denied), so replay the devices' uevents instead; udevd reloads
    # changed rules on its own before handling the next event.
    for dev in uinput uhid; do
        echo change | {{ auth }} tee "/sys/class/misc/$dev/uevent" > /dev/null
    done
# Deploy Quadlets to /var/home/wolf systemd directory
install:
    #!/usr/bin/env bash
    WOLF_HOME="/var/home/wolf"
    QUADLET_DIR="$WOLF_HOME/.config/containers/systemd"

    echo "Creating Quadlet and configuration directories..."
    {{ auth }} mkdir -p "$QUADLET_DIR"
    {{ auth }} mkdir -p /etc/wolf

    echo "Copying Quadlet definitions..."

    {{ auth }} cp {{ module_directory() }}/pulseaudio.container "$QUADLET_DIR/"
    {{ auth }} cp {{ module_directory() }}/nvidia-driver.volume "$QUADLET_DIR/"
    {{ auth }} cp {{ module_directory() }}/wolf-runtime.volume "$QUADLET_DIR/"
    # Superseded by the image-backed nvidia-driver.volume
    {{ auth }} rm -f "$QUADLET_DIR/nvidia-driver-populate.container"
    {{ auth }} cp {{ module_directory() }}/wolf.container "$QUADLET_DIR/"

    {{ auth }} cp {{ module_directory() }}/container_conf.toml "$WOLF_HOME/{{ user_storage }}"

    echo "Setting proper ownership for $WOLF_HOME/.config and /etc/wolf..."
    # Only what was just installed: a recursive chown of $WOLF_HOME would
    # flatten the subuid ownership inside the rootless image store.
    {{ auth }} chown -R wolf:wolf "$WOLF_HOME/.config"
    # Wolf runs as the wolf user (rootless, keep-id) and writes its config,
    # certs and app state here
    {{ auth }} chown -R wolf:wolf /etc/wolf
    {{ auth }} chmod 0750 /etc/wolf

    echo "Reloading systemd user daemon for wolf..."
    {{ auth }} systemctl --user -M wolf@ daemon-reload

    # Quadlet creates volumes with --ignore, so existing ones would be kept;
    # drop them so the next start recreates them from the current units:
    # nvidia-driver-vol may be pinned to a previous driver image, and an older
    # wolf-runtime-vol may have been created by a container (locked-out top
    # dir, see wolf-runtime.volume). pulse-socket-vol is no longer used.
    # Stop the oneshot volume units too, or they stay "active" and won't
    # recreate their volumes.
    {{ auth }} systemctl --user -M wolf@ stop nvidia-driver-volume.service wolf-runtime-volume.service
    for vol in nvidia-driver-vol wolf-runtime-vol pulse-socket-vol; do
        CMD=$(printf '%q ' env XDG_RUNTIME_DIR="/run/user/$(id -u wolf)" \
            podman volume rm "$vol")
        {{ shell_as("wolf") }} "$CMD" 2>/dev/null \
            || echo "$vol not removed (absent, or in use: stop Wolf and rerun install)"
    done


# Master recipe to build image, configure firewall, user, quadlets, and start services
setup: setup-user setup-firewall setup-udev build-containers build-gow build-wolf-ui install load-images && use-wolf-ui
    #!/usr/bin/env bash
    echo "Starting PulseAudio and Wolf services under user wolf..."
    {{ auth }} systemctl --user -M wolf@ start pulseaudio.service wolf.service
    echo "Wolf stack successfully deployed!"

wolf_quadlet_dir := "/var/home/wolf/.config/containers/systemd"
wolf_ctl := auth + " systemctl --user -M wolf@"

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
    #!/usr/bin/env bash
    set -euo pipefail
    DROPIN_DIR="{{ wolf_quadlet_dir }}/wolf.container.d"
    case "{{ state }}" in
        on)
            {{ auth }} mkdir -p "$DROPIN_DIR"
            printf '[Install]\nWantedBy=default.target\n' \
                | {{ auth }} tee "$DROPIN_DIR/autostart.conf" > /dev/null
            {{ auth }} chown -R wolf:wolf "$DROPIN_DIR"
            ;;
        off) {{ auth }} rm -f "$DROPIN_DIR/autostart.conf" ;;
        *) echo "usage: just wolf autostart [on|off]" >&2; exit 1 ;;
    esac
    {{ wolf_ctl }} daemon-reload
    echo "Wolf autostart: {{ state }}"
