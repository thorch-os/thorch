FROM archlinux:base-devel

RUN pacman -Syu --noconfirm --needed \
      aarch64-linux-gnu-gcc \
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
      qemu-user-static \
      qemu-user-static-binfmt \
      rsync \
      rust \
      squashfs-tools \
      sudo \
      systemd \
      tar \
      util-linux \
      xz \
      zstd \
    && pacman -Scc --noconfirm

WORKDIR /work
CMD ["/usr/bin/bash"]
