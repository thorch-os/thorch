# Internal Install Notes

Thorch treats SD as staging and recovery media. The intended performance path is
internal UFS storage.

The safest in-image installer flow uses explicit target partitions:

```bash
sudo thorch-install-internal --boot-device /dev/<boot-partition> --root-device /dev/<root-partition>
```

The default target mountpoint is `/mnt/thorch-internal`. A custom `--target` is
accepted only under `/mnt/thorch-internal` or `/run/thorch-installer`.

With no device arguments, the installer may auto-detect exactly one existing
internal ROCKNIX/Thorch Linux target and ask for confirmation before formatting
that target. It will not create new partitions or shrink Android userdata in the
default flow.

The first-boot internal install flow runs the installer in explicit
create-if-needed mode after the user accepts the internal-storage warning. In
that mode, the installer handles three internal-storage states:

- **Untouched Android layout:** Android `userdata` is the final large partition.
  Thorch shrinks/wipes `userdata` once, then creates ROCKNIX boot and Thorch
  root partitions after it.
- **Existing ROCKNIX/Thorch layout:** a ROCKNIX boot partition and a
  THORCH_ROOT/armbi_root/STORAGE root partition are detected and reused.
  Blank-but-labelled ROCKNIX boot partitions are accepted because the installer
  formats the selected boot partition anyway.
- **Already-resized but incomplete layout:** if `userdata` is already smaller
  and there is enough post-userdata space, Thorch recreates that post-userdata
  Linux area without shrinking `userdata` again. This covers interrupted or
  manually nuked ROCKNIX/Thorch installs.

Creating a target by shrinking Android `userdata` is an explicit advanced flow:

```bash
sudo thorch-install-internal --create-from-userdata
```

That mode wipes Android userdata, recreates it smaller, creates a 2 GiB
ROCKNIX-compatible boot partition, creates a Thorch root partition in the
remaining space, and requires typed confirmations before repartitioning. The
flow first asks for `SHRINK USERDATA`, then asks how much space Android userdata
should keep, then requires `CREATE THORCH` before changing the partition table.
For scripted recovery flows, `--userdata-keep-gib N|auto --yes` can be combined
with `--create-from-userdata`; `auto` keeps up to 32 GiB for Android userdata,
or less on small devices so at least 8 GiB remains for Thorch.

Safety behavior:

- Refuses to run unless the current root filesystem appears to be on removable
  media or matches the expected Thorch SD layout. Thor can report the SD slot as
  non-removable, so the fallback checks for root on `mmcblk*`, root label
  `THORCH_ROOT`, and `/boot` label `ROCKNIX` on the same card.
- Requires explicit boot/root block devices, one auto-detected existing
  ROCKNIX/Thorch target, or the explicit `--create-from-userdata` mode.
- Refuses common Android partition labels such as `abl`, `boot_a`, `boot_b`,
  `vendor`, `system`, `super`, `metadata`, `userdata`, `dtbo`, `vbmeta`,
  `persist`, `modem`, `bluetooth`, `dsp`, `xbl`, `tz`, `hyp`, `keymaster`, and
  `recovery`.
- Requires the typed confirmation `INSTALL THORCH`.
- Backs up readable existing boot files under `/var/lib/thorch-installer`.
- Formats the selected boot partition as FAT32 label `ROCKNIX`.
- Formats the selected root partition as ext4 or Btrfs label `THORCH_ROOT`.
  By default it follows the running SD root filesystem type; set
  `THORCH_ROOT_FSTYPE=ext4` or `THORCH_ROOT_FSTYPE=btrfs` to override it.
  Btrfs uses `THORCH_BTRFS_MOUNT_OPTIONS`, defaulting to
  `rw,relatime,compress=zstd:1`.
- Copies the running SD system without crossing into mounted runtime
  filesystems, preserves Thorch cache tmpfs entries and root mount options in
  `fstab`, regenerates initramfs with the selected root filesystem support,
  rebuilds `/boot/KERNEL`, and validates the boot directory.

The installer never flashes ABL. The device must already have a Linux-capable ABL
path.

## SD Recovery After Internal Install

The internal Linux boot filesystem is formatted with the ROCKNIX-compatible
label `ROCKNIX`. Newly allocated boot partitions also match the imported
qcom-abl metadata: Microsoft Basic Data, partition name `system`, and the GPT
legacy-boot attribute. The top-level `/KERNEL` remains the Android boot image
that ABL loads.

On some devices ABL may still load the internal `/KERNEL` before the SD card's
`/KERNEL`. Thorch handles that in the initramfs: when `thorch-sd-prefer` finds
the expected two-partition Thorch SD layout, it switches the root filesystem to
the SD card before fsck and mount. The layout check requires a `ROCKNIX` FAT
boot partition and a `THORCH_ROOT` ext4 or Btrfs root partition on the same
`mmcblk` card. Pass `thorch.sdprefer=0` on the kernel command line to disable
the preference, or `thorch.sdwait=<seconds>` to change the short detection
wait.

If the screen says `no match found for DTB!`, the SD or internal FAT partition
has been selected but its top-level `/KERNEL` is wrong for this Thor boot path.
Validate the card or image with:

```bash
make check IMAGE=/dev/sdX
```

The check strictly parses the Android boot image, gzip kernel stream, and
appended DTBs. It must pass the root UUID, framebuffer rotation,
`allow_mismatched_32bit_el0`, BinderFS, exactly one symbol-bearing Thor DTB, and
no generic AIM300 DTB tests for `/KERNEL`.
