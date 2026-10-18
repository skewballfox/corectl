ARG FEDORA_VERSION=44
# Fedora doesn't sign its base images, so pin the index digest; bump it
# together with FEDORA_VERSION (skopeo inspect --raw docker://... | sha256sum)
ARG FEDORA_DIGEST=sha256:6f263feab9835fa01d3f8a944827da527aadbf1fee5ead10ad9b892b60d14608
ARG BASE_IMAGE=registry.fedoraproject.org/fedora-minimal:${FEDORA_VERSION}@${FEDORA_DIGEST}
# The moonshine image, for its WSI Vulkan layer (build moonshine.Dockerfile first)
ARG MOONSHINE_IMAGE=localhost/moonshine/moonshine:patches

FROM $MOONSHINE_IMAGE AS moonshine

########################################################
# Steam as a moonshine app: connects to moonshine's Wayland/X11/PulseAudio
# sockets on shared volumes. RHEL/UBI 10 ship no i686 packages at all, and
# the Steam client still needs 32-bit glibc + graphics, so this is Fedora with
# RPM Fusion nonfree (which packages Steam).
FROM $BASE_IMAGE
ARG FEDORA_VERSION
RUN dnf -y install --setopt=install_weak_deps=False \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm" \
    && dnf -y install --setopt=install_weak_deps=False \
        steam dbus-daemon shadow-utils \
        vulkan-loader vulkan-loader.i686 mesa-vulkan-drivers mesa-vulkan-drivers.i686 \
        mesa-dri-drivers.i686 libwayland-client \
    && dnf clean all \
    && useradd --uid 1000 --user-group --create-home retro \
    # Steam's bootstrapper asks through zenity dialogs that nobody headless can
    # answer; the rpm requires it, so stub it out (as the GOW image does)
    && ln -sf /usr/bin/true /usr/bin/zenity

# Used by /usr/bin/steam (cmp), the runtime's setup.sh and the web helper's
# _v2-entry-point (getopt: full util-linux, not -core) and steamsysinfo
# (lspci); not in fedora-minimal. Own layer so the Steam install above stays cached.
RUN dnf -y install --setopt=install_weak_deps=False diffutils util-linux pciutils \
    && dnf clean all

# Route Vulkan presentation into moonshine's compositor (enabled by the
# ENABLE_MOONSHINE_WSI=1 that moonshine sets for its apps). x86_64 only:
# 32-bit Vulkan games fall back to Xwayland.
COPY --from=moonshine /usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so /usr/lib/moonshine/vulkan-layers/
COPY --from=moonshine /usr/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json /usr/share/vulkan/implicit_layer.d/

COPY --chmod=755 scripts/steam-entrypoint.sh /usr/local/bin/steam-entrypoint

# NVIDIA userspace from nvidia-driver-vol at /usr/nvidia (64- and 32-bit)
ENV LD_LIBRARY_PATH=/usr/nvidia/lib:/usr/nvidia/lib32 \
    __EGL_VENDOR_LIBRARY_DIRS=/usr/nvidia/share/glvnd/egl_vendor.d \
    __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS=/usr/nvidia/share/egl/egl_external_platform.d \
    GBM_BACKENDS_PATH=/usr/nvidia/lib/gbm \
    VK_DRIVER_FILES=/usr/nvidia/share/vulkan/icd.d/nvidia_icd.json \
    XDG_RUNTIME_DIR=/run/moonshine

# From the GOW Steam image's gamescope session (gow apps/steam startup.sh):
# keep games from minimizing when Steam's overlay takes focus, and have the
# Steam runtime's xdg-open hand URLs to Steam
ENV SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0 \
    SRT_URLOPEN_PREFER_STEAM=1

USER retro
WORKDIR /home/retro
ENTRYPOINT ["/usr/local/bin/steam-entrypoint"]
# moonshine's own Steam scanner uses -bigpicture (the launcher passes it too)
CMD ["-bigpicture"]
