# Build Notes

Thorch v1 uses ROCKNIX's public SM8550/Thor kernel recipe as the downstream
baseline. We do not build directly from AYN's kernel branch in the normal image
path; ROCKNIX carries the Thor integration, patch stack, DTS overlays, firmware
layout, and runtime assumptions that Thorch needs to stay aligned with.

Thorch supplies the Arch Linux ARM root filesystem, KDE defaults, firmware
package, initramfs, userspace installers, and a small BinderFS config fragment
applied on top of the ROCKNIX kernel recipe.

Before building packages or images, sync the public ROCKNIX SM8550 firmware and
metadata:

```bash
make sync ROCKNIX_REF=<rocknix-commit>
```

This populates `vendor/rocknix-sm8550` with inputplumber overlays and firmware.
The `SOURCE_PROVENANCE` and `firmware/THORCH_FIRMWARE_PROVENANCE` files record
the requested and resolved ROCKNIX refs.

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
release artifacts.

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
ROCKNIX_KERNEL_RELEASE=nightly-20260430 make kernel
ROCKNIX_KERNEL_RELEASE=nightly-20260428 make kernel
ROCKNIX_KERNEL_IMAGE_URL=https://.../ROCKNIX-SM8550.aarch64-YYYYMMDD.img.gz make kernel
```

`ROCKNIX_KERNEL_SOURCE` defaults to `nightly`; use `stable` when importing from
the latest stable ROCKNIX release stream. If an upstream image has no matching
`.sha256` asset, the sync refuses the import unless you provide
`ROCKNIX_KERNEL_SHA256_URL` or explicitly set `ROCKNIX_KERNEL_ALLOW_UNVERIFIED=1`
for a local experiment.

Package builds happen in an Arch Linux ARM aarch64 rootfs through
`systemd-nspawn` and `qemu-aarch64-static`. The builder copies Thorch package
inputs into the rootfs instead of bind-mounting the repository:

```bash
make packages
```

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
payload with Thorch's ROCKNIX-derived BinderFS kernel plus the Thor DTB.
`thorch-rebuild-abl-kernel` preserves that Thorch kernel payload and replaces
only the ramdisk plus root UUID command line for the generated image. An
imported ROCKNIX `/KERNEL` is still required because it supplies the ABL boot
image layout.

The image builder assembles FAT and ext4 filesystem images directly and writes
them into a raw GPT image. It does not mount image partitions or bind-mount host
API filesystems.

The boot partition defaults to 512 MiB. The raw image defaults to
`THORCH_IMAGE_SIZE=auto`, which removes build-time package caches and sizes the
image around the populated rootfs plus `THORCH_IMAGE_AUTO_HEADROOM`, default
`1G`. Set an explicit size such as `THORCH_IMAGE_SIZE=16G` when you want
preallocated room for first-boot Waydroid images and app data.

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
IMAGE=/dev/sdX`; the `/KERNEL` check must report that it embeds the Thor DTB.

## Important Environment

- `ROCKNIX_REF`: ROCKNIX branch, tag, or commit to sync.
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
- `THORCH_BOOT_SIZE`: FAT boot partition size, default `512M`.
- `THORCH_DEFAULT_SESSION`: `plasma-desktop` by default; use `plasma-mobile` to test the mobile shell.
- `THORCH_IMAGE_PACKAGES`: local packages installed into the image.
- `THORCH_BUILD_DIR`: build work directory, default `build`.
- `THORCH_OUTPUT_DIR`: image/package output directory, default `output`.
- `THORCH_LOCAL_REPO_DIR`: local package repository path, default `output/repo`.
- `THORCH_ROCKNIX_DIR`: synced ROCKNIX source/overlay directory.
- `THORCH_FIRMWARE_DIR`: synced ROCKNIX firmware directory.
- `THORCH_ROCKNIX_KERNEL_DIR`: ROCKNIX-derived kernel artifact directory.
- `THORCH_ROCKNIX_RUNTIME_DIR`: imported ROCKNIX runtime/FEX artifact directory.
- `THORCH_KERNEL_SOURCE_BUILD`: set to `0` only to keep the imported ROCKNIX kernel payload for diagnostics; Waydroid BinderFS support is not guaranteed.
- `THORCH_KERNEL_REF`: Linux kernel tag/ref used by the ROCKNIX SM8550 recipe, default `v7.0.11`.
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
