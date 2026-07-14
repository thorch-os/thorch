ARG THORCH_DOCKER_BASE_IMAGE=archlinux:base-devel
FROM ${THORCH_DOCKER_BASE_IMAGE}

SHELL ["/bin/bash", "-c"]

# Install a cross compiler only on x86_64. Arch Linux ARM builds the aarch64
# kernel and root filesystem natively and does not need qemu-user there.
RUN packages=( \
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
