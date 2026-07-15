# Digest resolved by Builder Image run 29105361823. Renovate this deliberately;
# do not silently consume a different base under the same moving tag.
FROM archlinux:base-devel@sha256:b21289eb1954872de0dc9f88976627e38611b1817be75e50946c83ab7b9c474d

# pacman's DownloadUser seccomp sandbox cannot initialize under some
# linux/amd64-on-arm64 container emulators. This builder is already an isolated
# disposable container, so disable that nested sandbox before synchronizing.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
    && pacman -Syu --noconfirm --needed \
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
