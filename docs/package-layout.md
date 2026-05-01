# Package Layout

`linux-thorch` packages prebuilt ROCKNIX SM8550 kernel artifacts for AYN Thor. It
installs `/boot/Image`, the Thor DTB, matching modules, and a mkinitcpio preset.
Thorch does not replay ROCKNIX kernel patches in v1; it builds its own initramfs
against the imported kernel.

`thorch-bsp` owns the ABL boot contract, including `LinuxLoader.cfg`,
`thorch-rebuild-abl-kernel`, `thorch-check-boot`, the mkinitcpio firmware hook,
USB debug gadget, boot diagnostics, Thor joystick RGB control, gamepad udev
rules, and ALSA UCM snippets.

`thorch-firmware-rocknix` packages the synced public ROCKNIX firmware tree into
`/usr/lib/firmware`. It also installs the matching ROCKNIX `/SYSTEM`
Turnip/Freedreno runtime imported with the kernel image: the native aarch64 host
driver, `libdisplay-info.so.2` compatibility library, ROCKNIX FEX-side Freedreno
helper, and host Vulkan ICD. The image build removes Arch's stock
`linux-firmware*` packages and relies on this package for Thor firmware.

`thorch-kde-defaults` installs the Plasma Desktop dependencies, SDDM defaults,
KWin display and touch seeds, virtual keyboard settings, audio user units,
touch calibration service, the F24 desktop escape helper, Firefox, and the core
KDE desktop applications. Plasma Mobile remains optional so the desktop session
stays the default shell.

`thorch-installer` provides `thorch-install-internal` and the `Expand SD Root`
desktop launcher for growing the booted SD root partition after first boot.

`thorch-fex-bin` repackages the matching ROCKNIX `/SYSTEM` FEX runtime. It
installs FEX, Vulkan/OpenGL/
audio/drm/Wayland thunks, binfmt registrations, a `libfmt.so.11` compatibility
library for the imported binaries, and a Steam-compatible FEX tool under
`/usr/share/steam/fex`. The package provides and replaces the old `thorch-fex`
name for upgrades.

`thorch-gaming-installers` provides the opt-in Steam ARM64 and gaming setup
launcher. It does not redistribute Steam client payloads. It keeps ROCKNIX-style
Steam metadata in `/usr/share/steam` for the ARM64 Proton compatibility-tool
stub, and links the packaged FEX tool from `/usr/share/steam/fex` into the
user's Steam compatibility tools during setup/launch. The Steam launcher keeps
the user Steam symlinks fresh, seeds per-app FEX configs with DRM, Vulkan, GL,
asound, and Wayland host libraries, and leaves global FEX binfmt registrations
enabled so Steam Runtime and pressure-vessel x86_64 helper binaries are handed
to FEX normally. The packaged FEX thunk database also covers pressure-vessel's
library override aliases so CS2 can use the DRM, Vulkan, GL, asound, and Wayland
host-library forwarding paths from inside Steam Linux Runtime containers. The
FEX Arch rootfs remains an x86_64 guest rootfs; when the ROCKNIX FEX-side
`libvulkan_freedreno.so` is available, the installer copies that x86_64 guest
driver into the rootfs just like ROCKNIX. It still refuses to copy the aarch64
host driver over the guest library. Vulkan acceleration is provided by FEX's
Vulkan thunk, which forwards guest Vulkan calls to the patched native aarch64
host driver.
