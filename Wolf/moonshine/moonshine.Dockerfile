ARG FEDORA_VERSION=44
# Fedora doesn't sign its base images, so pin the index digest; bump it
# together with FEDORA_VERSION (skopeo inspect --raw docker://... | sha256sum)
ARG FEDORA_DIGEST=sha256:6f263feab9835fa01d3f8a944827da527aadbf1fee5ead10ad9b892b60d14608
ARG BASE_IMAGE=registry.fedoraproject.org/fedora-minimal:${FEDORA_VERSION}@${FEDORA_DIGEST}
# Built from the fork's `patches` branch by default (see moonshine.just)
ARG MOONSHINE_REPO=https://github.com/skewballfox/moonshine.git
ARG MOONSHINE_REF=patches
# Moonshine (https://github.com/hgaiser/moonshine): Moonlight server with its
# own headless compositor, Vulkan Video encoder and built-in PulseAudio server.
# UBI 10 lacks libevdev, Xwayland and every -devel package moonshine needs
# (EPEL doesn't fill them, it builds against full RHEL), so this is Fedora.

########################################################
# Stage 1: build moonshine and the moonshine-wsi Vulkan layer
FROM $BASE_IMAGE AS builder
# Build deps follow upstream CI (.github/actions/install-dependencies) and
# nix/package.nix: inputtino-sys links libc++ and runs bindgen (libclang),
# aws-lc-sys and inputtino-sys build C/C++ through cmake.
RUN dnf -y install --setopt=install_weak_deps=False \
        git gcc gcc-c++ clang clang-devel cmake make rust cargo pkgconf-pkg-config \
        libcxx-devel libcxxabi-devel libdrm-devel libevdev-devel mesa-libgbm-devel \
        opus-devel wayland-devel libxkbcommon-devel pulseaudio-libs-devel vulkan-loader-devel \
    && dnf clean all

ARG MOONSHINE_REPO
ARG MOONSHINE_REF
# The commit MOONSHINE_REF pointed at when build-moonshine resolved it: a
# changed value reruns the clone, and the check fails if the ref moved since
ARG MOONSHINE_COMMIT
RUN test -n "$MOONSHINE_COMMIT" \
    && git clone --depth 1 --branch "$MOONSHINE_REF" "$MOONSHINE_REPO" /src \
    && test "$(git -C /src rev-parse HEAD)" = "$MOONSHINE_COMMIT"
WORKDIR /src
# --workspace also builds libmoonshine_wsi.so (a bare build skips it)
RUN cargo build --release --locked --workspace \
    && install -Dm755 target/release/moonshine /out/usr/bin/moonshine \
    && install -Dm755 target/release/libmoonshine_wsi.so /out/usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so \
    && install -Dm644 dist/VkLayer_moonshine_wsi.json /out/usr/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json

########################################################
# Stage 2: runtime
FROM $BASE_IMAGE AS runner
# Runtime deps follow the upstream rpm (nfpm.yaml) plus what fedora-minimal
# leaves out: Vulkan loader, EGL/glvnd for smithay's GLES renderer. (libc++
# is build-only: the binary links libstdc++.) GPU userspace for NVIDIA comes
# from nvidia-driver-vol at /usr/nvidia.
RUN dnf -y install --setopt=install_weak_deps=False \
        opus libevdev libxkbcommon mesa-libgbm mesa-libEGL libglvnd-egl \
        libwayland-client libwayland-server vulkan-loader xorg-x11-server-Xwayland \
        pulseaudio-libs shadow-utils \
    && dnf clean all \
    && useradd --uid 1000 --user-group --no-create-home --home-dir /etc/moonshine moonshine

COPY --from=builder /out/ /

# Moonshine puts its Wayland socket and PulseAudio socket here, and the app
# container mounts the same volume at the same path (moonshine.container).
# Paired clients go in XDG_DATA_HOME/moonshine, next to the config and keys.
ENV XDG_RUNTIME_DIR=/run/moonshine \
    XDG_DATA_HOME=/etc/moonshine/state \
    MOONSHINE_LOG=moonshine=info

USER moonshine
EXPOSE 47984/tcp 47989/tcp 48010/tcp 47998/udp 47999/udp 48000/udp

ARG MOONSHINE_REPO
ARG MOONSHINE_COMMIT
LABEL org.opencontainers.image.source="$MOONSHINE_REPO"
LABEL org.opencontainers.image.revision="$MOONSHINE_COMMIT"
LABEL org.opencontainers.image.description="Moonshine: Moonlight streaming server with an isolated headless compositor"

ENTRYPOINT ["/usr/bin/moonshine"]
CMD ["/etc/moonshine/config.toml"]
