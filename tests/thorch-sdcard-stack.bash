#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${root}/packages/thorch-gaming-installers/payload/usr/lib/hwsupport/thorch-sdcard-mount"
rules="${root}/packages/thorch-gaming-installers/payload/usr/lib/udev/rules.d/99-thorch-sdcard-automount.rules"
unit="${root}/packages/thorch-gaming-installers/payload/usr/lib/systemd/system/thorch-sdcard@.service"
pkgbuild="${root}/packages/thorch-gaming-installers/PKGBUILD"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash -n "${helper}"
grep -Fq 'KERNEL=="mmcblk[0-9]p[0-9]"' "${rules}" ||
  fail "automount rules are not limited to microSD partitions"
grep -q 'ENV{ID_FS_TYPE}=="ext4"' "${rules}" ||
  fail "automount add rule is not limited to Steam-supported ext4"
grep -q 'ENV{UDISKS_AUTO}="0"' "${rules}" ||
  fail "automount rule does not prevent a competing KDE/UDisks automount"
grep -q 'ENV{SYSTEMD_WANTS}+="thorch-sdcard@%k.service"' "${rules}" ||
  fail "automount rule does not start the device-bound mount service"
grep -Fq 'BindsTo=dev-%i.device' "${unit}" ||
  fail "microSD service lifetime is not bound to the partition device"
grep -Fq 'ConditionPathExists=/dev/%I' "${unit}" ||
  fail "microSD service does not skip stale add events after device removal"
grep -Fq 'ExecStart=/usr/lib/hwsupport/thorch-sdcard-mount add %I' "${unit}" &&
  grep -Fq 'ExecStopPost=-/usr/lib/hwsupport/thorch-sdcard-mount remove %I' "${unit}" ||
    fail "microSD service does not guarantee cleanup after interrupted insertion"
grep -Fq 'Restart=on-failure' "${unit}" ||
  fail "microSD service does not retry a contended or transiently failed insertion"

grep -q 'findmnt -rn -o MAJ:MIN /' "${helper}" ||
  fail "helper does not protect the root microSD partition"
grep -q 'X-mount.idmap=' "${helper}" ||
  fail "helper does not preserve SteamOS uid/gid portability"
grep -q 'rw,nosuid,nodev,exec,noatime' "${helper}" ||
  fail "helper does not preserve executable games while disabling suid and device nodes"
grep -q 'flock -w 60' "${helper}" ||
  fail "helper does not serialize overlapping hotplug operations"
if grep -q 'flock -n' "${helper}"; then
  fail "helper can still discard an overlapping hotplug operation"
fi
grep -q 'flock -u 9' "${helper}" ||
  fail "helper does not release the mount lock before notifying Steam"
if grep -q -- '--wait' "${helper}"; then
  fail "helper still waits synchronously for Steam while handling hotplug"
fi
grep -q 'notify_steam addlibraryfolder' "${helper}" &&
  grep -q 'steam://${url_action}' "${helper}" ||
    fail "helper does not register hotplugged cards with Steam"
grep -q 'udisks2' "${pkgbuild}" ||
  fail "gaming package does not depend on UDisks2"
grep -q 'util-linux' "${pkgbuild}" ||
  fail "gaming package does not declare its mount/idmap tools"

fakebin="${work}/bin"
install -d "${fakebin}" "${work}/dev" "${work}/media" "${work}/home"
: >"${work}/dev/mmcblk0p1"

cat >"${fakebin}/getent" <<EOF
#!/usr/bin/env bash
printf 'gamer:x:1002:1003::${work}/home:/bin/bash\n'
EOF
cat >"${fakebin}/findmnt" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -S "*)
    [[ -z "${THORCH_TEST_MOUNTED_AT:-}" ]] || printf '%s\n' "${THORCH_TEST_MOUNTED_AT}"
    ;;
  *" -o MAJ:MIN / "*)
    printf '8:2\n'
    ;;
  *" -M "*)
    exit 1
    ;;
esac
EOF
cat >"${fakebin}/lsblk" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" MAJ:MIN "*) printf '%s\n' "${THORCH_TEST_CARD_DEVNO:-179:1}" ;;
  *" FSTYPE "*) printf 'ext4\n' ;;
  *" LABEL "*) printf 'SteamLibrary\n' ;;
  *) exit 1 ;;
esac
EOF
cat >"${fakebin}/mount" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${THORCH_TEST_MOUNT_LOG}"
EOF
cat >"${fakebin}/umount" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${THORCH_TEST_UMOUNT_LOG}"
EOF
cat >"${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${fakebin}/systemd-run" <<'EOF'
#!/usr/bin/env bash
/usr/bin/flock -n "${THORCH_SDCARD_LOCK_FILE}" /usr/bin/true ||
  { echo "mount lock held during Steam notification" >&2; exit 1; }
if [[ "${THORCH_TEST_EXPECT_UNMOUNTED:-0}" = 1 && ! -s "${THORCH_TEST_UMOUNT_LOG}" ]]; then
  echo "Steam removal notification ran before unmount" >&2
  exit 1
fi
printf '%s\n' "$*" >"${THORCH_TEST_STEAM_LOG}"
EOF
chmod +x "${fakebin}/getent" "${fakebin}/findmnt" "${fakebin}/lsblk" \
  "${fakebin}/mount" "${fakebin}/umount" "${fakebin}/pgrep" \
  "${fakebin}/systemd-run"

PATH="${fakebin}:${PATH}" \
THORCH_SDCARD_ALLOW_FAKE_DEVICE=1 \
THORCH_SDCARD_DEV_ROOT="${work}/dev" \
THORCH_SDCARD_LOCK_FILE="${work}/mount.lock" \
THORCH_SDCARD_MEDIA_ROOT="${work}/media" \
THORCH_SDCARD_USER=gamer \
THORCH_TEST_MOUNT_LOG="${work}/mount.log" \
  "${BASH}" "${helper}" add mmcblk0p1 >/dev/null

grep -Fq "${work}/dev/mmcblk0p1 ${work}/media/gamer/SteamLibrary" "${work}/mount.log" ||
  fail "helper did not mount the card under the configured user's media directory"
grep -Fq 'u:1000:1002:1 u:1001:1001:1 u:1002:1000:1' "${work}/mount.log" ||
  fail "helper did not swap SteamOS uid 1000 with the configured uid"
grep -Fq 'g:1000:1003:1 g:1001:1001:2 g:1003:1000:1' "${work}/mount.log" ||
  fail "helper did not swap SteamOS gid 1000 with the configured gid"
grep -Fq 'rw,nosuid,nodev,exec,noatime' "${work}/mount.log" ||
  fail "helper did not apply safe Steam-compatible removable-media flags"

install -d "${work}/media/gamer/Foreign"
rm -f "${work}/mount.log" "${work}/umount.log"
PATH="${fakebin}:${PATH}" \
THORCH_SDCARD_ALLOW_FAKE_DEVICE=1 \
THORCH_SDCARD_DEV_ROOT="${work}/dev" \
THORCH_SDCARD_LOCK_FILE="${work}/mount.lock" \
THORCH_SDCARD_MEDIA_ROOT="${work}/media" \
THORCH_SDCARD_USER=gamer \
THORCH_TEST_MOUNTED_AT="${work}/media/gamer/Foreign" \
THORCH_TEST_MOUNT_LOG="${work}/mount.log" \
THORCH_TEST_UMOUNT_LOG="${work}/umount.log" \
  "${BASH}" "${helper}" add mmcblk0p1 >/dev/null
grep -Fq -- "-- ${work}/media/gamer/Foreign" "${work}/umount.log" ||
  fail "helper did not replace a competing desktop mount"
grep -Fq 'X-mount.idmap=' "${work}/mount.log" ||
  fail "helper did not remount a competing desktop mount with SteamOS idmapping"

install -d "${work}/home/.local/share/Steam/steamrtarm64"
install -m 0755 /dev/null "${work}/home/.local/share/Steam/steamrtarm64/steam"
rm -f "${work}/steam.log" "${work}/umount.log"
PATH="${fakebin}:${PATH}" \
THORCH_SDCARD_ALLOW_FAKE_DEVICE=1 \
THORCH_SDCARD_DEV_ROOT="${work}/dev" \
THORCH_SDCARD_LOCK_FILE="${work}/mount.lock" \
THORCH_SDCARD_MEDIA_ROOT="${work}/media" \
THORCH_SDCARD_USER=gamer \
THORCH_TEST_MOUNTED_AT="${work}/media/gamer/SteamLibrary" \
THORCH_TEST_UMOUNT_LOG="${work}/umount.log" \
THORCH_TEST_STEAM_LOG="${work}/steam.log" \
THORCH_TEST_EXPECT_UNMOUNTED=1 \
  "${BASH}" "${helper}" remove mmcblk0p1 >/dev/null
grep -Fq 'steam://removelibraryfolder/' "${work}/steam.log" ||
  fail "helper did not notify Steam after safely unmounting the card"

rm -f "${work}/mount.log"
PATH="${fakebin}:${PATH}" \
THORCH_SDCARD_ALLOW_FAKE_DEVICE=1 \
THORCH_SDCARD_DEV_ROOT="${work}/dev" \
THORCH_SDCARD_LOCK_FILE="${work}/mount.lock" \
THORCH_SDCARD_MEDIA_ROOT="${work}/media" \
THORCH_SDCARD_USER=gamer \
THORCH_TEST_CARD_DEVNO=8:2 \
THORCH_TEST_MOUNT_LOG="${work}/mount.log" \
  "${BASH}" "${helper}" add mmcblk0p1 >/dev/null
[[ ! -e "${work}/mount.log" ]] ||
  fail "helper attempted to mount the root filesystem's microSD partition"

printf 'thorch SteamOS microSD automount checks passed\n'
