# Provenance

Thorch is meant to be public and standalone. Hardware enablement is synchronized
from public upstreams and recorded with provenance files.

## ROCKNIX

The public ROCKNIX distribution repository provides the SM8550 kernel recipe,
patch stack, AYN Thor DTS overlays, input mappings, and firmware used by
Thorch. ROCKNIX image artifacts provide the ABL boot-image template plus runtime
payloads that Thorch repacks around its source-built kernel:

https://github.com/ROCKNIX/distribution

The requested source and kernel refs are defined in `config/thorch.conf`.
Generated `SOURCE_PROVENANCE`, kernel `PROVENANCE`, and runtime `PROVENANCE`
files record the exact resolved inputs. Thorch builds from the configured
kernel source, applies the synced ROCKNIX patch/config/DTS inputs, then applies
the local BinderFS/Waydroid config fragment. Release builds should change these
inputs only as one reviewed baseline update.

Use a pinned commit or labelled ROCKNIX image build for release builds:

```bash
./scripts/sync-rocknix-sources.sh --ref <commit-sha> --with-firmware
make import-kernel BOOT_DIR=/mnt/rocknix-boot ROOT_DIR=/mnt/rocknix-root KERNEL_REF=<rocknix-build-label>
```

The sync and import scripts write provenance files into `vendor/rocknix-sm8550`,
`vendor/rocknix-kernel`, and `vendor/rocknix-runtime` so generated builds can be
traced back to the exact upstream source and image artifact.

Image and package builds refuse kernel provenance that points back at local
`makepkg` output or smoke-test imports. Re-import the ROCKNIX boot
template/runtime from a mounted or extracted ROCKNIX image and rebuild the
Thorch BinderFS kernel before preparing release artifacts. The builders also
require the recorded kernel release and module tree to match
`THORCH_KERNEL_REF`.

## AYN Linux

AYN also publishes kernel work that underpins the SM8550 handheld ports:

https://github.com/AYNTechnologies/linux

AYN's branch and tag history is source-level review material when updating
kernel, DTS, firmware paths, ALSA card aliases, gamepad handling, or RGB
support. Those references are not build pins: Thorch follows the configured
ROCKNIX recipe and the exact inputs recorded in generated provenance files.

## Firmware

Thor firmware is sourced from the public ROCKNIX SM8550 firmware tree and
packaged as `thorch-firmware-rocknix`. Thorch preserves upstream provenance, but
does not claim new licensing rights over those blobs.

Some Adreno firmware and the x86_64 FEX guest driver are imported from the
ROCKNIX image `/SYSTEM` payload. Those image-derived files are recorded in
kernel or FEX runtime provenance rather than in the public source overlay
provenance. The native aarch64 Mesa/Turnip driver is built separately by
`thorch-mesa` from Mesa's upstream release tarball.

## FEX Runtime

The FEX runtime packaged as `thorch-fex-bin` is imported from the matching
ROCKNIX `/SYSTEM` payload. Runtime provenance is written to
`vendor/rocknix-runtime/PROVENANCE` and installed into package license metadata
with the imported binaries.

The pinned ROCKNIX nightly already carries FEX-2607. Thorch therefore reuses
that matched runtime and thunk set instead of carrying Pocknix's separate x86
sysroot build. For comparison, `shuuri-labs/pocknix-os` builds FEX-2607 from
source with patches 0001, 0002, 0005, and 0006. It drops ROCKNIX's 0004 Nix
wrapper patch by using a pinned Arch x86 sysroot, and drops the old 0003 sysroot
include patch because FEX-2607 now filters the standard include path upstream.

## Mesa

`thorch-mesa` builds the upstream Mesa 26.1.5 release tarball and records its
upstream SHA-256 in the PKGBUILD. Its SM8550-focused package structure and
driver selection are adapted from `shuuri-labs/pocknix-os`.

## Arch Linux ARM

The base root filesystem and distro packages come from Arch Linux ARM aarch64
repositories. Thorch packages are layered on top as a local pacman repository
during image creation.

## Local Thorch Code

Thorch-specific scripts, package recipes, installer guardrails, KDE defaults, and
boot validation live in this repository.

Nightly release notes include the Thorch commit, requested ROCKNIX source/image
refs, selected root filesystem, and generated kernel provenance. Published image
assets are accompanied by a SHA-256 file.
