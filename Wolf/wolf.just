import '../common.just'

setup-user:
    #!/usr/bin/env bash
    just ensure-groups render input video
    just create-sys-user wolf -g render -g input -g video -d -q


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
build-containers tag="wolf-nvidia:latest" version="" base_image="ghcr.io/games-on-whales/gstreamer:1.26.7":
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

    just build-and-sign \
        {{ tag }} \
        -b BASE_IMAGE="{{ base_image }}"\
        -o "$DEST_ROOT"
    

    
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
    {{ auth }} cp {{ module_directory() }}/nvidia-driver-populate.container "$QUADLET_DIR/"
    {{ auth }} cp {{ module_directory() }}/nvidia-driver.volume "$QUADLET_DIR/"
    {{ auth }} cp {{ module_directory() }}/wolf.container "$QUADLET_DIR/"

    {{ auth }} cp {{ module_directory() }}/container_conf.toml "$WOLF_HOME/{{ user_storage }}"

    echo "Setting proper ownership for $WOLF_HOME and /etc/wolf..."
    {{ auth }} chown -R wolf:wolf "$WOLF_HOME"
    {{ auth }} chown -R root:wolf /etc/wolf
    {{ auth }} chmod 0750 /etc/wolf

    echo "Reloading systemd user daemon for wolf..."
    {{ auth }} systemctl --user -M wolf@ daemon-reload


# Master recipe to build image, configure firewall, user, quadlets, and start services
setup: setup-user setup-firewall build-containers install
    #!/usr/bin/env bash
    echo "Starting PulseAudio and Wolf services under user wolf..."
    {{ auth }} systemctl --user -M wolf@ start pulseaudio.service wolf.service
    echo "Wolf stack successfully deployed!"