#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sessionctl="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-sessionctl"
install_script="${root}/packages/thorch-kde-defaults/thorch-kde-defaults.install"
packaged_default="${root}/packages/thorch-kde-defaults/payload/etc/sddm.conf.d/10-thorch.conf"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_root="${fixture}/root"
mkdir -p "${test_root}/etc/sddm.conf.d" \
  "${test_root}/usr/share/wayland-sessions"
cp "${packaged_default}" "${test_root}/etc/sddm.conf.d/10-thorch.conf"
printf 'alice:x:1000:1000:Alice:/home/alice:/bin/bash\n' > "${test_root}/etc/passwd"
printf '[Desktop Entry]\nName=Plasma\n' > \
  "${test_root}/usr/share/wayland-sessions/plasma.desktop"

default_before="$(sha256sum "${test_root}/etc/sddm.conf.d/10-thorch.conf" | awk '{print $1}')"
THORCH_SESSIONCTL_ROOT="${test_root}" \
  "${sessionctl}" set desktop --user alice --no-restart >/dev/null
default_after="$(sha256sum "${test_root}/etc/sddm.conf.d/10-thorch.conf" | awk '{print $1}')"
[[ "${default_before}" == "${default_after}" ]] || \
  fail "thorch-sessionctl modified package-owned 10-thorch.conf"

local_conf="${test_root}/etc/sddm.conf.d/90-thorch-local.conf"
grep -qx 'User=alice' "${local_conf}" || fail "local SDDM drop-in has the wrong user"
grep -qx 'Session=plasma.desktop' "${local_conf}" || \
  fail "local SDDM drop-in has the wrong session"
! grep -q '^\[Theme\]' "${local_conf}" || \
  fail "generated local drop-in copied package-owned static policy"
! grep -q '^\[Autologin\]' "${packaged_default}" || \
  fail "package-owned SDDM policy still owns generated autologin state"

migration_root="${fixture}/migration"
mkdir -p "${migration_root}/etc/sddm.conf.d"
cat > "${migration_root}/etc/sddm.conf.d/10-thorch.conf" <<'EOF'
[Theme]
Current=breeze
[Autologin]
User=legacy-user
Session=plasma-mobile.desktop
Relogin=true
EOF
THORCH_INSTALL_ROOT="${migration_root}" bash -c 'source "$1"; pre_upgrade' \
  _ "${install_script}"
cp "${packaged_default}" "${migration_root}/etc/sddm.conf.d/10-thorch.conf"
THORCH_INSTALL_ROOT="${migration_root}" bash -c 'source "$1"; post_upgrade' \
  _ "${install_script}"
migrated_conf="${migration_root}/etc/sddm.conf.d/90-thorch-local.conf"
grep -qx 'User=legacy-user' "${migrated_conf}" || \
  fail "upgrade did not preserve the legacy autologin user"
grep -qx 'Session=plasma-mobile.desktop' "${migrated_conf}" || \
  fail "upgrade did not preserve the legacy session"

printf 'thorch SDDM ownership checks passed\n'
