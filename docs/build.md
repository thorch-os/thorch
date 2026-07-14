# Build Notes

Thorch uses ROCKNIX's public SM8550/Thor kernel recipe as the downstream
baseline. We do not build directly from AYN's kernel branch in the normal image
path; ROCKNIX carries the Thor integration, patch stack, DTS overlays, firmware
layout, and runtime assumptions that Thorch needs to stay aligned with.

The requested source and kernel refs live in `config/thorch.conf`. The generated
source, kernel, and runtime provenance files record the exact resolved inputs
used for a build. Update the config and imported ROCKNIX image provenance
together when moving the hardware baseline.

Thorch supplies the Arch Linux ARM root filesystem, KDE defaults, firmware
package, initramfs, userspace installers, and a small BinderFS config fragment
applied on top of the ROCKNIX kernel recipe.

Before building packages or images, sync the public ROCKNIX SM8550 firmware and
metadata:

```bash
make sync
```

This populates `vendor/rocknix-sm8550` with inputplumber overlays and firmware.
The `SOURCE_PROVENANCE` and `firmware/THORCH_FIRMWARE_PROVENANCE` files record
the requested and resolved ROCKNIX refs. The default comes from
`config/thorch.conf`; use `make sync ROCKNIX_REF=<full-commit-sha>` for a
deliberate baseline update.

The ROCKNIX kernel sync requires `curl`, `jq`, `losetup`, `mount`,
`sha256sum`, `unsquashfs`, and `python3` on the build host. On Arch-like hosts,
`unsquashfs` is provided by `squashfs-tools`.

Then sync the ROCKNIX image-derived runtime inputs and build the Thorch kernel.
This is a required clean-build input; `make sync` only downloads public source
overlays and firmware, not the ABL boot-image template or FEX runtime. By
default, the kernel sync downloads the latest official ROCKNIX SM8550 nightly,
verifies its `.sha256`, extracts `/KERNEL` and `/SYSTEM`, normalizes the result
into `vendor/rocknix-kernel` and `vendor/rocknix-runtime`, then source-builds a
Thorch Thor kernel from ROCKNIX's Linux recipe with BinderFS enabled:

```bash
make kernel
```

You can also import from a mounted or extracted ROCKNIX image. The importer
expects `KERNEL`, `Image`, and matching `usr/lib/modules/<kernel-release>/`;
the `make import-kernel` target then rebuilds the Thorch BinderFS kernel against
that imported boot template/runtime unless `THORCH_KERNEL_SOURCE_BUILD=0` is set
for diagnostics:

```bash
make import-kernel BOOT_DIR=/mnt/rocknix-boot ROOT_DIR=/mnt/rocknix-root KERNEL_REF=<rocknix-build-label>
```

Package and image builders reject smoke-test or local `makepkg` kernel
provenance. Re-import the boot template/runtime from a real ROCKNIX image and
let `scripts/build-thorch-kernel.sh` replace the kernel/modules before preparing
release artifacts. They also compare the provenance release and module-tree
directory with `THORCH_KERNEL_REF`, rejecting stale or mismatched kernel
artifacts before packaging.

SM8550 fan control has a userspace half in `thorch-bsp` and a DT/kernel half in
ROCKNIX. To pick up ROCKNIX's May 2026 fan-control DT changes, sync a ROCKNIX
ref that includes ROCKNIX PR #2653 before rebuilding the Thorch kernel.

For clean-room testing, do not import from previous Thorch output directories,
copied `vendor/rocknix-kernel` trees, or locally built package payloads. Use a
freshly mounted or freshly extracted ROCKNIX image and keep the `KERNEL_REF`
label tied to that input.

`make build` and `make packages` run `scripts/sync-rocknix-kernel.sh`
automatically when `vendor/rocknix-kernel/boot/KERNEL`,
`vendor/rocknix-kernel/boot/Image`, or the imported FEX runtime is missing.
`scripts/sync-rocknix-kernel.sh` imports the ROCKNIX image payload first, then
runs `scripts/build-thorch-kernel.sh` unless `THORCH_KERNEL_SOURCE_BUILD=0` or
`--skip-thorch-kernel-build` is used for local diagnostics. To pin a specific
upstream image, set one of:

```bash
ROCKNIX_KERNEL_SOURCE=stable ROCKNIX_KERNEL_RELEASE=latest make kernel
ROCKNIX_KERNEL_RELEASE=<release-tag> make kernel
ROCKNIX_KERNEL_IMAGE_URL=https://.../ROCKNIX-SM8550.aarch64-YYYYMMDD.img.gz make kernel
```

`ROCKNIX_KERNEL_SOURCE` defaults to `nightly`; use `stable` when importing from
the latest stable ROCKNIX release stream. If an upstream image has no matching
`.sha256` asset, the sync refuses the import unless you provide
`ROCKNIX_KERNEL_SHA256_URL` or explicitly set `ROCKNIX_KERNEL_ALLOW_UNVERIFIED=1`
for a local experiment.

Package builds happen in an Arch Linux ARM aarch64 rootfs through
`THORCH_ROOTFS_RUNNER` and `qemu-aarch64-static`. The runner defaults to plain
`chroot`; set `THORCH_ROOTFS_RUNNER=systemd-nspawn` only if you need the old
backend. Plain chroot commands mount `/proc` in a private mount namespace so an
interrupted build cannot leave the rootfs mounted. The builder copies Thorch
package inputs into the rootfs instead of bind-mounting the repository:

```bash
make packages
```

## Docker Builder

Thorch also has a ROCKNIX-style Docker build path. The project Dockerfile
defines the Arch builder environment, and the `docker-*` Make targets wrap the
normal Make targets inside that builder:

```bash
make docker-image-pull || make docker-image-build
make docker-build
```

`make docker-<target>` runs `make <target>` in the builder container, so
`make docker-packages`, `make docker-fast`, and `make docker-nightly` use the
same scripts as the host build. `make docker-shell` opens an interactive shell
in the builder.

The Docker wrapper mounts the repository at `/work`, runs the container
privileged for loop-device/image operations, disables SELinux relabeling on the
bind mount, and returns generated artifacts to the host user when the command
exits. It preserves root ownership inside `build/image-rootfs` and
`build/pkg-root`, because those chroot permissions become image metadata and
are required for reliable rootfs reuse.

On an `arm64` or `aarch64` host, `make docker-image-build` selects the native
`menci/archlinuxarm:base-devel` base and builds kernels and Arch Linux ARM
packages without CPU emulation. On x86_64 it keeps the official
`archlinux:base-devel` base and installs the aarch64 cross compiler and QEMU
rootfs runner. Override `THORCH_DOCKER_BASE_IMAGE` to use a pinned or mirrored
builder base.

During userspace iteration, skip rebuilding/repackaging the kernel:

```bash
make packages-userspace
```

The full image build downloads the Arch Linux ARM aarch64 rootfs, prunes stock
kernel/firmware packages from the chroot, installs the selected local Thorch
packages, creates a GPT raw image, and generates the ABL `/KERNEL` boot image:

```bash
make build
```

The generated `/KERNEL` is repacked from the imported ROCKNIX boot image
template. `scripts/build-thorch-kernel.sh` replaces the template's kernel
payload with Thorch's ROCKNIX-derived BinderFS kernel and the exact SM8550
handheld DTB manifest listed by the synced ROCKNIX overlays. DTBs are compiled
with symbol tables (`DTC_FLAGS=-@`), and stale generic DTBs such as AIM300 are
not carried into the payload. `thorch-rebuild-abl-kernel` preserves that kernel
payload and replaces only the ramdisk plus root UUID command line for the
generated image. It also preserves ROCKNIX's
`allow_mismatched_32bit_el0` argument, which the asymmetric Thor CPU layout
needs to avoid an early CPU feature panic. An imported ROCKNIX `/KERNEL` is
still required because it supplies the ABL boot image layout.

Thorch adds the Android-characterized 124.8 MHz A740 OPP to the clean SM8550
kernel source. It is the lowest running DCVS level; the GMU constructs a
separate zero-frequency/off level. At boot, `thorch-hw-defaults` also mirrors
ROCKNIX's SM8550 GMU workaround by disabling CPU0 cpuidle state1. Set
`THORCH_DISABLE_CPU0_IDLE_STATE1=0` in `/etc/thorch/hardware.conf` only for a
controlled power/stability comparison.

The image builder assembles standalone FAT plus ext4 or Btrfs filesystem images
and writes them into a sparse raw GPT image. It does not mount the final GPT
partitions or bind-mount host API filesystems. Ext4 remains the conservative
default; use
`THORCH_ROOT_FSTYPE=btrfs make build` to build a btrfs root image. Btrfs roots
use `THORCH_BTRFS_MOUNT_OPTIONS`, defaulting to
`rw,relatime,compress=zstd:1`. The builder populates the filesystem through a
loop-mounted standalone filesystem because affected btrfs-progs offline
`--rootdir` compression paths can emit unreadable zstd extents for some
already-compressed files. It then uses `btrfs inspect-internal min-dev-size` to
shrink the filesystem, adds the configured headroom, and force-reads every file
before image assembly.

The boot partition defaults to 512 MiB. The raw image defaults to
`THORCH_IMAGE_SIZE=auto`, which removes build-time package caches and sizes the
image around the populated rootfs plus `THORCH_IMAGE_AUTO_HEADROOM`, default
`1G`. Set an explicit size such as `THORCH_IMAGE_SIZE=16G` when you want
preallocated room for first-boot Waydroid images and app data.

The default user's `~/.cache` is mounted as tmpfs by default
(`THORCH_USER_CACHE_TMPFS_SIZE=512M`) to reduce small Firefox/KDE writes on SD
cards. Set `THORCH_USER_CACHE_TMPFS_SIZE=0` to keep caches on the root
filesystem. Firstboot retargets this entry to the selected user's home and
numeric UID/GID when the account changes.

The generated initramfs includes Thor and shared SM8550 firmware needed during
early boot rather than copying the entire firmware tree. Adreno SQE, GMU, and
ZAP firmware remain on the real root filesystem, matching ROCKNIX and keeping
those blobs unavailable during initramfs execution. This keeps `/KERNEL` small
enough for the 512 MiB FAT partition without changing the complete firmware
package installed in the root filesystem.

If the build host cannot show interactive `sudo` prompts, invoke the scripts
through PolicyKit so the desktop authentication agent can prompt visibly:

```bash
pkexec ./scripts/build-image.sh
pkexec ./scripts/sync-rocknix-kernel.sh
```

For userspace package/default/service changes, use the fast rebuild path:

```bash
make fast
```

This wrapper rebuilds only missing or stale local Thorch packages, refreshes
`build/image-rootfs` when it exists, regenerates initramfs and `/boot/KERNEL`,
and reassembles `output/thorch-arch-aarch64.img`. If `build/image-rootfs` does
not exist yet, it is created from the local package repo after the package
refresh. If ROCKNIX-derived kernel artifacts changed, run
`scripts/build-image-fast.sh --with-kernel`.

Nightly GitHub Actions image builds are defined in
`.github/workflows/nightly.yml` and documented in
[`docs/nightly-actions.md`](nightly-actions.md). They run on GitHub-hosted
Ubuntu, pull or build the Thorch Docker builder image, and invoke
`make docker-nightly` with `THORCH_ROOTFS_RUNNER=chroot`.

The default image package set is:

```bash
linux-thorch thorch-bsp thorch-firmware-rocknix thorch-kde-defaults thorch-firstboot thorch-installer thorch-fex-bin thorch-gamescope thorch-gaming-installers thorch-waydroid-installer thorch-inputplumber thorch-rocknix-quirks thorch-mangohud thorch-gamepadcalibration
```

`thorch-kde-defaults` installs Firefox and the core KDE desktop applications:
Ark, Dolphin, Gwenview, Kate, KCalc, Konsole, Okular, and Spectacle.
`thorch-firstboot` adds the QML onboarding flow that runs on first login.

Override `THORCH_IMAGE_PACKAGES` with the complete local package set when you
want a custom image, for example:

```bash
THORCH_IMAGE_PACKAGES='linux-thorch thorch-bsp thorch-firmware-rocknix thorch-kde-defaults thorch-installer' make build
```

To write an image to SD, use the removable-device writer. It refuses mounted,
read-only, non-removable, or partition targets and does not mount or unmount
anything. The `make write` target runs `make check` first so a stale or
incorrect `/KERNEL` is caught before the card is overwritten:

```bash
make write DEVICE=/dev/sdX
```

With PolicyKit instead of `sudo`:

```bash
pkexec ./scripts/write-image.sh output/thorch-arch-aarch64.img /dev/sdX
```

To validate a card after writing, pass the whole SD block device:

```bash
make check IMAGE=/dev/sdX
```

If Thor shows `no match found for DTB!`, the bootloader has selected the FAT
boot partition but rejected `/KERNEL`. Check the SD with `make check
IMAGE=/dev/sdX`. The checker strictly parses the gzip kernel stream and appended
DTBs. It requires the image root UUID, framebuffer rotation,
`allow_mismatched_32bit_el0`, BinderFS support, exactly one symbol-bearing Thor
DTB, and no generic AIM300 DTB.

## Important Environment

`config/thorch.conf` is authoritative for configurable defaults; this list
describes their purpose without duplicating mutable source or kernel refs.

- `ROCKNIX_REF`: pinned ROCKNIX branch, tag, or commit to sync.
- `ROCKNIX_REPO`: ROCKNIX distribution repository URL.
- `ROCKNIX_KERNEL_SOURCE`: ROCKNIX image release stream, `nightly` by default; can be `stable`.
- `ROCKNIX_KERNEL_RELEASE`: release tag/date to import, default `latest`.
- `ROCKNIX_KERNEL_PLATFORM`: ROCKNIX platform name, default `SM8550`.
- `ROCKNIX_KERNEL_IMAGE_URL`: explicit ROCKNIX `.img` or `.img.gz` URL.
- `ROCKNIX_KERNEL_SHA256_URL`: explicit checksum URL for the ROCKNIX image.
- `ROCKNIX_KERNEL_CACHE_DIR`: download/decompression cache, default `build/cache/rocknix`.
- `THORCH_USER`: default image user, default `thorch`.
- `THORCH_PASSWORD`: password/PIN for the default user and root, default `1234`.
- `THORCH_IMAGE_SIZE`: raw image size, default `auto`; set a fixed size such as `16G` when preallocated free space is needed.
- `THORCH_IMAGE_AUTO_HEADROOM`: extra rootfs space when `THORCH_IMAGE_SIZE=auto`, default `1G`.
- `THORCH_ROOT_FSTYPE`: root filesystem type, default `ext4`; set to `btrfs` for a compressed btrfs root image.
- `THORCH_BTRFS_MOUNT_OPTIONS`: btrfs root mount options, default `rw,relatime,compress=zstd:1`.
- `THORCH_USER_CACHE_TMPFS_SIZE`: default user's `~/.cache` tmpfs size, default `512M`; set `0`, `off`, `none`, or `disabled` to turn it off.
- `THORCH_BOOT_SIZE`: FAT boot partition size, default `512M`.
- `THORCH_DEFAULT_SESSION`: `plasma-desktop` by default; use `plasma-mobile` to test the mobile shell.
- `THORCH_IMAGE_PACKAGES`: local packages installed into the image.
- `THORCH_BUILD_DIR`: build work directory, default `build`.
- `THORCH_ROOTFS_RUNNER`: rootfs command runner, default `chroot`; can be set to `systemd-nspawn` for the old backend.
- `THORCH_OUTPUT_DIR`: image/package output directory, default `output`.
- `THORCH_LOCAL_REPO_DIR`: local package repository path, default `output/repo`.
- `THORCH_DOCKER_IMAGE`: Docker builder image used by `make docker-*`, default `ghcr.io/thorch-os/thorch-build:latest`.
- `THORCH_DOCKER_CMD`: container runtime used by `make docker-*`, defaults to `docker` and falls back to `podman`.
- `THORCH_ROCKNIX_DIR`: synced ROCKNIX source/overlay directory.
- `THORCH_FIRMWARE_DIR`: synced ROCKNIX firmware directory.
- `THORCH_ROCKNIX_KERNEL_DIR`: ROCKNIX-derived kernel artifact directory.
- `THORCH_ROCKNIX_RUNTIME_DIR`: imported ROCKNIX runtime/FEX artifact directory.
- `THORCH_KERNEL_SOURCE_BUILD`: set to `0` only to keep the imported ROCKNIX kernel payload for diagnostics; Waydroid BinderFS support is not guaranteed.
- `THORCH_KERNEL_REF`: Linux kernel tag/ref used by the ROCKNIX SM8550 recipe.
- `THORCH_KERNEL_TARBALL_URL`: kernel source tarball URL; set empty to use the git repo/ref path.
- `THORCH_KERNEL_CONFIG`: ROCKNIX base kernel config, default `vendor/rocknix-sm8550/linux/linux.aarch64.conf`.
- `THORCH_KERNEL_CONFIG_FRAGMENT`: Thorch required config fragment, default `packages/linux-thorch/waydroid-kernel.config`.
- `THORCH_KERNEL_PATCH_DIRS`: ROCKNIX patch directories applied to the kernel source.
- `THORCH_KERNEL_DTS_DIR`: ROCKNIX DTS overlay directory, default `vendor/rocknix-sm8550/linux/dts`.
- `THORCH_WAYDROID_KERNEL_REQUIRED`: set to `0` only for local experiments that intentionally build without BinderFS/Waydroid kernel support.
- `ALARM_ROOTFS_URL`: Arch Linux ARM aarch64 rootfs URL.
- `ALARM_ROOTFS_SIG_URL`: detached signature URL for the Arch Linux ARM rootfs.
- `ALARM_ROOTFS_SIGNING_KEYS`: pinned trusted rootfs signing fingerprints.
- `ALARM_ROOTFS_KEYRING_URL`: Arch Linux ARM keyring package URL used to import missing pinned signing keys.
- `ALARM_ROOTFS_KEYSERVER`: optional fallback keyserver used to fetch missing pinned signing keys.
- `ALARM_ROOTFS_KEY_FETCH_TIMEOUT`: timeout for rootfs signing-key fetches.
- `ALARM_ROOTFS_SHA256`: pinned Arch Linux ARM rootfs hash, used instead of signature verification when set.
- `ALARM_MIRRORS`: space-separated Arch Linux ARM pacman mirror bases written into the image.
- `ALARM_MIRROR`: Arch Linux ARM pacman mirror base.
- `ROCKNIX_KERNEL_ALLOW_UNVERIFIED`: set to `1` only for local experiments that intentionally import an unverified ROCKNIX image.
