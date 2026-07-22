# Digest resolved by Builder Image run 29105361823. Renovate this deliberately;
# do not silently consume a different base under the same moving tag.
ARG THORCH_DOCKER_BASE_IMAGE=archlinux:base-devel@sha256:b21289eb1954872de0dc9f88976627e38611b1817be75e50946c83ab7b9c474d
FROM ${THORCH_DOCKER_BASE_IMAGE}

SHELL ["/bin/bash", "-c"]

# Install a cross compiler only on x86_64. Arch Linux ARM builds the aarch64
# kernel and root filesystem natively and does not need qemu-user there.

# pacman's DownloadUser seccomp sandbox cannot initialize under some
# linux/amd64-on-arm64 container emulators. This builder is already an isolated
# disposable container, so disable that nested sandbox before synchronizing.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
    && packages=( \
      android-tools \
      arch-install-scripts \
      base-devel \
      bc \
      binutils \
      bison \
      btrfs-progs \
      cpio \
      curl \
      desktop-file-utils \
      dosfstools \
      dtc \
      e2fsprogs \
      fakechroot \
      file \
      flex \
      git \
      gnupg \
      jq \
      kmod \
      libarchive \
      libelf \
      mtools \
      openssl \
      pacman-contrib \
      pahole \
      python \
      rsync \
      rust \
      squashfs-tools \
      sudo \
      systemd \
      tar \
      util-linux \
      xz \
      zstd \
    ) \
    && if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then \
         packages+=(aarch64-linux-gnu-gcc qemu-user-static qemu-user-static-binfmt); \
       fi \
    && pacman --disable-sandbox -Syu --noconfirm --needed "${packages[@]}" \
    && pacman -Scc --noconfirm

WORKDIR /work
CMD ["/usr/bin/bash"]
