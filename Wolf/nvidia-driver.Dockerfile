ARG FEDORA_VERSION=44
# Same base as moonshine.Dockerfile (bump the two together), so the installer
# sees the glvnd/Vulkan loader layout the moonshine image runs with
ARG FEDORA_DIGEST=sha256:6f263feab9835fa01d3f8a944827da527aadbf1fee5ead10ad9b892b60d14608
ARG BASE_IMAGE=registry.fedoraproject.org/fedora-minimal:${FEDORA_VERSION}@${FEDORA_DIGEST}

FROM $BASE_IMAGE AS nvidia-installer

# Version-independent steps first: a declared ARG is part of every later
# RUN's cache key, so NV_VERSION comes after them.
# tar/gzip/xz unpack the .run; libglvnd-devel makes the installer use the
# system glvnd instead of installing its own; vulkan-loader stands in for
# Ubuntu's vulkan-tools
RUN dnf -y install --setopt=install_weak_deps=False \
        curl ca-certificates kmod pkgconf-pkg-config findutils which tar gzip xz \
        libglvnd-devel vulkan-loader \
    && dnf clean all

ARG NV_VERSION
# Own layer, so changing the installer flags below doesn't re-download
RUN curl -fLO --retry 5 --retry-all-errors --retry-delay 5 -C - https://download.nvidia.com/XFree86/Linux-x86_64/$NV_VERSION/NVIDIA-Linux-x86_64-$NV_VERSION.run && \
    chmod +x NVIDIA-Linux-x86_64-$NV_VERSION.run
# --opengl-libdir=lib: on Fedora the installer would default to lib64, but the
# quadlets' LD_LIBRARY_PATH and GBM_BACKENDS_PATH point at /usr/nvidia/lib
RUN mkdir -p /usr/nvidia && \
    ./NVIDIA-Linux-x86_64-$NV_VERSION.run --silent -z --skip-depmod --skip-module-unload --no-nvidia-modprobe --no-kernel-modules --no-kernel-module-source --opengl-prefix=/usr/nvidia --opengl-libdir=lib --wine-prefix=/usr/nvidia --utility-prefix=/usr/nvidia --utility-libdir=lib --compat32-prefix=/usr/nvidia --compat32-libdir=lib32 --egl-external-platform-config-path=/usr/nvidia/share/egl/egl_external_platform.d --glvnd-egl-config-path=/usr/nvidia/share/glvnd/egl_vendor.d --no-distro-scripts && \
    rm ./NVIDIA-Linux-x86_64-$NV_VERSION.run

# Soname symlinks (libnvidia-allocator.so.1 etc., which gbm/nvidia-drm_gbm.so
# points at). The ICD goes to /etc/vulkan or /usr/share/vulkan depending on
# the distro, so it's found and moved into the tree here.
RUN printf '/usr/nvidia/lib\n/usr/nvidia/lib32\n' > /etc/ld.so.conf.d/nvidia.conf && ldconfig \
    && mkdir -p /usr/nvidia/share/vulkan/icd.d \
    && icd=$(find /etc/vulkan /usr/share/vulkan -name nvidia_icd.json -print -quit) \
    && test -n "$icd" && cp "$icd" /usr/nvidia/share/vulkan/icd.d/ \
    && test -e /usr/nvidia/lib/gbm/nvidia-drm_gbm.so \
    && test -e /usr/nvidia/lib/libEGL_nvidia.so.0

################
# Data-only image backing nvidia-driver.volume (Driver=image). An image volume
# exposes the whole image root, so the driver tree sits at / and lands at
# /usr/nvidia wherever the volume is mounted. Never run: no shell or libc.
FROM scratch AS nvidia-driver

# Checked against the loaded kernel module before Wolf starts (wolf.container)
ARG NV_VERSION
LABEL nvidia_driver_version=$NV_VERSION

COPY --from=nvidia-installer /usr/nvidia/ /
