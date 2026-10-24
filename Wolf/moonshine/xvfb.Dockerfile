ARG FEDORA_VERSION=44
# Fedora doesn't sign its base images, so pin the index digest; bump it
# together with FEDORA_VERSION (skopeo inspect --raw docker://... | sha256sum)
ARG FEDORA_DIGEST=sha256:6f263feab9835fa01d3f8a944827da527aadbf1fee5ead10ad9b892b60d14608
ARG BASE_IMAGE=registry.fedoraproject.org/fedora-minimal:${FEDORA_VERSION}@${FEDORA_DIGEST}

########################################################
# A headless X server for Steam between streams (quadlets/moonshine-xvfb.container):
# with no moonshine session there is no display, and Steam stops after its
# client update instead of logging in and downloading. Its own image, so the
# Steam image, where games run, gets no X server.
# mesa-dri-drivers: Xvfb's GLX (software rendering), which Steam's UI may ask for.
FROM $BASE_IMAGE
RUN dnf -y install --setopt=install_weak_deps=False xorg-x11-server-Xvfb mesa-dri-drivers \
    && dnf clean all

ENTRYPOINT ["/usr/bin/Xvfb"]
