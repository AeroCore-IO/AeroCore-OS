# Allow build scripts to be referenced without being copied into the final image
ARG BASE_IMAGE="ghcr.io/ublue-os/bazzite-deck:stable"

FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG IMAGE_NAME="aerocore-os"
ARG IMAGE_VENDOR="AeroCore-IO"
ARG IMAGE_BRANCH="stable"
ARG VERSION_TAG="latest"
ARG VERSION_PRETTY="latest"
ARG OSTREE_IMAGE_REF=""
## Other possible base images include:
# ghcr.io/ublue-os/bazzite-deck:testing
# ghcr.io/ublue-os/bazzite-deck:stable-43.20260420

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

ARG FLATPAK_REMOTE_URL=""
ARG HOMEBREW_BOTTLE_DOMAIN=""
ARG HOMEBREW_API_DOMAIN=""
ARG INSTRUMENTS_ENABLED="true"
ARG INSTRUMENTS_RELEASE_REPOSITORY="AeroCore-IO/booster-installer"
ARG INSTRUMENTS_VERSION="latest"
ARG INSTRUMENTS_RELEASE_API_BASE="https://api.github.com"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh && \
    /ctx/image-info && \
    /ctx/build-initramfs

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
