# Package Layout

`linux-thorch` packages Thorch's ROCKNIX-derived SM8550 kernel artifacts for
AYN Thor. The source-build path starts from ROCKNIX's public Linux recipe,
applies the ROCKNIX SM8550 patch stack and Thor DTS overlays, then applies
Thorch's required BinderFS/Waydroid config fragment. The package installs the
resulting `/KERNEL` ABL boot payload, matching modules, a module-tree `Image`
anchor for mkinitcpio, the required config fragment for build guards, and a
mkinitcpio preset. It does not install raw `/boot/Image`; `/boot/KERNEL` is the
ABL boot payload. When building `/boot/KERNEL`, Thorch preserves the imported
ROCKNIX Android boot-image layout but uses Thorch's source-built kernel payload
and exact ROCKNIX handheld DTB manifest while replacing the initramfs and root
command line. The DTBs retain overlay symbols, the payload contains exactly one
Thor DTB, and generic AIM300 DTBs are excluded.
The DTS patch set also restores Android's characterized 124.8 MHz lowest A740
operating point. This is a normal running DCVS level; the GMU supplies its
separate zero/off table entry.

`thorch-bsp` owns the ABL boot contract, including
`thorch-rebuild-abl-kernel`, `thorch-check-boot`, the mkinitcpio firmware hook,
USB debug gadget, boot diagnostics, Thor joystick RGB control, Rust power/input
daemons, ROCKNIX-derived SM8550 PWM fan profiles, dual-panel
backlight helpers, gamepad/input udev rules, Plasma Mobile action-drawer
overrides, quick settings for USB/SSH/RGB toggles, and ALSA UCM snippets. The
boot hardware-default service adapts ROCKNIX's SM8550 GMU workaround by
disabling CPU0 cpuidle state1, with a documented config override for controlled
testing. The action-drawer override is stateful: package install/upgrade runs a
sync helper
so SteamOS mode can keep its patched Plasma Mobile drawer enabled while normal
desktop/mobile sessions restore the stock QML.

The boot checker parses the compressed kernel and appended DTBs instead of
searching arbitrary image bytes. It enforces the image root UUID, framebuffer
rotation, ROCKNIX's `allow_mismatched_32bit_el0` CPU compatibility argument,
BinderFS support, and the Thor DTB invariants. The firmware hook copies only
non-GPU Thor and shared SM8550 early-boot firmware into initramfs. Adreno SQE,
GMU, and ZAP firmware remain on the real root filesystem, matching ROCKNIX and
keeping those blobs unavailable during initramfs execution. The full firmware
tree remains installed in the root filesystem.

`thorch-firmware-rocknix` packages the synced public ROCKNIX firmware tree into
`/usr/lib/firmware`. It also installs the matching ROCKNIX `/SYSTEM`
Turnip/Freedreno runtime imported with the kernel image: the native aarch64 host
driver and its matching `libdisplay-info.so.2` compatibility library under
`/usr/lib/thorch/freedreno`, the ROCKNIX FEX-side Freedreno helper, and a
uniquely named host Vulkan ICD. The private driver has an `$ORIGIN` runpath, so
neither compatibility library overwrites Arch's system `libdisplay-info`. The
package declares the stock `linux-firmware*` packages it provides, conflicts
with, and replaces, so a normal pacman transaction can transfer ownership
without `-Rdd` or `--overwrite`.

`thorch-kde-defaults` installs the Plasma Desktop dependencies, SDDM defaults,
KWin display and touch seeds, virtual keyboard settings, audio user units,
touch calibration service, the F24 desktop escape helper, OLED Plasma theme and
color scheme, desktop/mobile session switchers, Bluetooth support, Firefox, and
the core KDE desktop applications. Plasma Mobile is installed for testing and
SteamOS-mode handoff, but the image builder selects Plasma Desktop by default unless
`THORCH_DEFAULT_SESSION` is changed. Session changes go through
`thorch-sessionctl`, which writes generated autologin state to the
higher-priority, non-package-owned `/etc/sddm.conf.d/90-thorch-local.conf` and
prefers a clean reboot over restarting SDDM from inside a live Plasma session.
The package-owned `10-thorch.conf` contains only static theme/input policy. Its
upgrade script migrates autologin values written by older releases before that
static file is replaced.

`thorch-firstboot` installs the fullscreen QML onboarding app, root helper,
Polkit rule, autostart entry, and optional Wayland session entry. The helper
scans/connects Wi-Fi through NetworkManager, creates or updates the selected
user, applies password policy, writes the chosen KDE theme, stages the selected
Thorch session through `thorch-sessionctl`, retargets the configured cache tmpfs
to that user's home and numeric UID/GID, and records completion under
`/var/lib/thorch/firstboot`. The QML flow exposes a Skip action from every page,
runs automatic SD expansion and create-if-needed internal-install actions
in-window, and can call the gaming stack installer command when Steam mode is
selected.

`thorch-installer` provides `thorch-install-internal` and
`thorch-expand-root` for firstboot and CLI recovery flows. The root expander
grows only the currently mounted ext4 or Btrfs `/` partition and requires a
removable device or the expected two-partition Thorch SD layout unless
`--force` is used. Internal install defaults to the running root filesystem
type, supports explicit ext4/Btrfs selection, and preserves the cache tmpfs
configuration.

`thorch-fex-bin` repackages the matching ROCKNIX `/SYSTEM` FEX runtime. It
installs FEX, Vulkan/OpenGL, audio, DRM, and Wayland thunks, binfmt
registrations, a `libfmt.so.11` compatibility library for the imported binaries,
and a Steam-compatible FEX tool under `/usr/share/steam/fex`. The package
provides and replaces the old `thorch-fex` name for upgrades.

`thorch-gamescope` builds Valve's gamescope from source with the ROCKNIX
handheld gamescope patch set consumed from the synced `vendor/rocknix-sm8550`
tree. It keeps only the Arch-specific wlroots workaround locally. It provides
and conflicts with `gamescope`, so installers and launchers can continue
invoking the standard `gamescope` command.

`thorch-rocknix-quirks` packages ROCKNIX-derived SM8550 handheld quirk metadata
for Thorch. It exports Arch-safe profile hints for touchscreen, audio path,
thermal, CPU/GPU frequency paths, modifier buttons, and MangoHud support while
preserving the original ROCKNIX quirk scripts from the synced
`vendor/rocknix-sm8550` tree under `/usr/share/thorch/rocknix-quirks/SM8550`
for provenance. It does not execute ROCKNIX's `/storage` autostart scripts
directly; hardware-affecting behavior is reviewed and adapted into Thorch
services rather than running that directory wholesale.

`thorch-mangohud` builds MangoHud with ROCKNIX's SM8550 GPU fdinfo patch and
installs the ROCKNIX MangoHud configuration as `/etc/MangoHud.conf`, both from
the synced `vendor/rocknix-sm8550` tree.

`thorch-gaming-installers` provides the opt-in Steam ARM64, FEX setup, gaming
stack installer command, and SteamOS-mode launchers. It does not redistribute
Steam client payloads. It keeps ROCKNIX-style Steam metadata in
`/usr/share/steam` for the ARM64 Proton compatibility-tool stub, and links the
packaged FEX tool from `/usr/share/steam/fex` into the user's Steam
compatibility tools during setup/launch. The Steam launcher keeps the user Steam
symlinks fresh, seeds
per-app FEX configs with DRM, Vulkan, GL, asound, and Wayland host libraries,
and leaves global FEX binfmt registrations enabled so Steam Runtime and
pressure-vessel x86_64 helper binaries are handed to FEX normally. The packaged
FEX thunk database also covers pressure-vessel's library override aliases so CS2
can use the DRM, Vulkan, GL, asound, and Wayland host-library forwarding paths
from inside Steam Linux Runtime containers. The FEX Arch rootfs remains an
x86_64 guest rootfs; when the ROCKNIX FEX-side `libvulkan_freedreno.so` is
available, the installer copies that x86_64 guest driver into the rootfs just
like ROCKNIX. It still refuses to copy the aarch64 host driver over the guest
library. Vulkan acceleration is provided by FEX's Vulkan thunk, which forwards
guest Vulkan calls to the patched native aarch64 host driver.

`thorch-waydroid-installer` provides the opt-in first-boot Waydroid setup
command and app-menu installer entry. It does not redistribute Waydroid or
Android images in the base image; the helper installs Arch Linux ARM's
`waydroid` and `python-pyclip` packages, verifies BinderFS, and initializes
vanilla Waydroid. The installed Waydroid package provides the runtime launcher.
