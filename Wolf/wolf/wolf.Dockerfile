ARG BASE_IMAGE=ghcr.io/games-on-whales/gstreamer:1.26.7
# from here down, is adapted from 
# https://github.com/games-on-whales/wolf/blob/stable/docker/wolf.Dockerfile

########################################################
# Stage 1: system deps — changes rarely (only on Dockerfile edits)
FROM $BASE_IMAGE AS deps-base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    curl ca-certificates ninja-build cmake pkg-config ccache git clang build-essential \
    libboost-thread-dev libboost-locale-dev libboost-filesystem-dev libboost-log-dev libboost-stacktrace-dev libboost-container-dev libboost-json-dev \
    libwayland-dev libwayland-server0 libinput-dev libxkbcommon-dev libgbm-dev \
    libcurl4-openssl-dev libssl-dev libevdev-dev libpulse-dev libunwind-dev libudev-dev libdrm-dev libpci-dev \
    libglib2.0-dev libegl-dev libgles-dev libopengl-dev \
    && rm -rf /var/lib/apt/lists/*

########################################################
# Stage 2: Rust toolchain — changes only on RUST_VERSION bump
ARG RUST_VERSION=1.96.0
FROM deps-base AS rust-toolchain
ENV PATH="/root/.cargo/bin:${PATH}"\
    CARGO_HOME="/root/.cargo"\
    RUSTUP_HOME="/root/.cargo"


RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path


ENV RUST_VERSION=$RUST_VERSION
RUN rustup install $RUST_VERSION && rustup default $RUST_VERSION

########################################################
# Stage 3: gst-wayland-display — changes only when pinned commit bumps
FROM rust-toolchain AS gst-wayland-display
WORKDIR /tmp/
RUN <<_GST_WAYLAND_DISPLAY
    #!/bin/bash
    set -e
    git clone https://github.com/games-on-whales/gst-wayland-display
    cd gst-wayland-display
    git checkout b15285a
    cargo install cargo-c@0.10.23 --locked
    cargo cinstall --features="cuda" --prefix=/usr/local/lib/x86_64-linux-gnu/ --libdir=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0
_GST_WAYLAND_DISPLAY

########################################################
# Stage 4: Wolf source build — changes on every commit, kept last
FROM gst-wayland-display AS wolf-builder
RUN git clone --recursive https://github.com/games-on-whales/wolf.git /wolf
COPY . /wolf
WORKDIR /wolf
ENV CCACHE_DIR=/cache/ccache
ENV CMAKE_BUILD_DIR=/cache/cmake-build
RUN --mount=type=cache,target=/cache/ccache \
    cmake -B$CMAKE_BUILD_DIR \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_EXTENSIONS=OFF \
    -DCMAKE_CXX_FLAGS="-Wno-missing-template-arg-list-after-template-kw" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBUILD_FAKE_UDEV_CLI=ON \
    -DBUILD_TESTING=OFF \
    -G Ninja && \
    ninja -C $CMAKE_BUILD_DIR wolf && \
    ninja -C $CMAKE_BUILD_DIR fake-udev && \
    cp $CMAKE_BUILD_DIR/src/moonlight-server/wolf /wolf/wolf && \
    cp $CMAKE_BUILD_DIR/src/fake-udev/fake-udev /wolf/fake-udev

########################################################
# Stage 5: runtime image — PulseAudio removed; it now runs as its own
# Quadlet-managed container (pulseaudio.container), reached over the
# shared pulse-socket-vol volume via PULSE_SERVER.
FROM $BASE_IMAGE AS runner
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    ca-certificates libssl3 libicu76 libevdev2 libudev1 libcurl4 libdrm2 libpci3 libunwind8 \
    libwayland-server0 libinput10 libxkbcommon0 libgbm1 libglvnd0 libgl1 libglx0 libegl1 libgles2 xwayland hwdata \
    libpulse0 \
    && rm -rf /var/lib/apt/lists/*

ENV GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0/
COPY --from=wolf-builder /usr/local/lib/x86_64-linux-gnu/gstreamer-1.0/* $GST_PLUGIN_PATH
#COPY --from=wolf-builder /usr/local/lib/liblibgstwaylanddisplay* /usr/local/lib/


WORKDIR /wolf

ENV WOLF_CFG_FOLDER=/etc/wolf/cfg

COPY --from=wolf-builder /wolf/wolf /wolf/wolf
COPY --from=wolf-builder /wolf/fake-udev /wolf/fake-udev

ENV GST_GL_API=gles2 \
    GST_GL_PLATFORM=egl \
    GST_GL_WINDOW=surfaceless \
    WOLF_USE_ZERO_COPY=TRUE \
    WOLF_LOG_LEVEL=INFO \
    WOLF_CFG_FILE=$WOLF_CFG_FOLDER/config.toml \
    WOLF_PRIVATE_KEY_FILE=$WOLF_CFG_FOLDER/key.pem \
    WOLF_PRIVATE_CERT_FILE=$WOLF_CFG_FOLDER/cert.pem \
    WOLF_RENDER_NODE=/dev/dri/renderD128 \
    WOLF_STOP_CONTAINER_ON_EXIT=TRUE \
    WOLF_WAYLAND_SOCKET_WAIT_TIMEOUT_MS=5000 \
    WOLF_DOCKER_SOCKET=/var/run/docker.sock \
    WOLF_DEFAULT_RUN_UID=1000 \
    WOLF_DEFAULT_RUN_GID=1000 \
    RUST_BACKTRACE=full \
    RUST_LOG=WARN \
    HOST_APPS_STATE_FOLDER=/etc/wolf \
    GST_DEBUG=2 \
    PUID=0 \
    PGID=0 \
    UNAME="root" \
    PULSE_SERVER=unix:/tmp/pulse/pulse-socket

VOLUME /run/user/wolf/
ENV XDG_RUNTIME_DIR=/run/user/wolf

EXPOSE 47984/tcp
EXPOSE 47989/tcp
EXPOSE 47999/udp
EXPOSE 48010/tcp
EXPOSE 48100/udp
EXPOSE 48200/udp

LABEL org.opencontainers.image.source="https://github.com/games-on-whales/wolf/"
LABEL org.opencontainers.image.description="Wolf: stream virtual desktops and games in Docker"

ENTRYPOINT ["/wolf/wolf"]