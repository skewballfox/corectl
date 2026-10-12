FROM ubuntu:22.04 AS nvidia-installer

ARG NV_VERSION
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends curl ca-certificates kmod pkg-config libglvnd-dev vulkan-tools && \
    curl -fLO --retry 5 --retry-all-errors --retry-delay 5 -C - https://download.nvidia.com/XFree86/Linux-x86_64/$NV_VERSION/NVIDIA-Linux-x86_64-$NV_VERSION.run && \
    chmod +x NVIDIA-Linux-x86_64-$NV_VERSION.run && mkdir -p /usr/nvidia && \
    ./NVIDIA-Linux-x86_64-$NV_VERSION.run --silent -z --skip-depmod --skip-module-unload --no-nvidia-modprobe --no-kernel-modules --no-kernel-module-source --opengl-prefix=/usr/nvidia --wine-prefix=/usr/nvidia --utility-prefix=/usr/nvidia --utility-libdir=lib --compat32-prefix=/usr/nvidia --compat32-libdir=lib32 --egl-external-platform-config-path=/usr/nvidia/share/egl/egl_external_platform.d --glvnd-egl-config-path=/usr/nvidia/share/glvnd/egl_vendor.d --no-distro-scripts && \
    rm ./NVIDIA-Linux-x86_64-$NV_VERSION.run

# shellcheck disable=SC3037
RUN echo -e "/usr/nvidia/lib\n/usr/nvidia/lib32" > /etc/ld.so.conf.d/nvidia.conf && ldconfig

################
# Data-only image backing nvidia-driver.volume (Driver=image). An image volume
# exposes the whole image root, so the driver tree sits at / and lands at
# /usr/nvidia wherever the volume is mounted. Never run: no shell or libc.
FROM scratch AS nvidia-driver

# Checked against the loaded kernel module before Wolf starts (wolf.container)
ARG NV_VERSION
LABEL nvidia_driver_version=$NV_VERSION

COPY --from=nvidia-installer /usr/nvidia/ /
COPY --from=nvidia-installer /etc/vulkan/icd.d/nvidia_icd.json /share/vulkan/icd.d/
