#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
windowctl="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-windowctl"
drawer_qml="${root}/packages/thorch-kde-defaults/actiondrawer/Main.qml"
drawer_main="${root}/packages/thorch-kde-defaults/actiondrawer/main.cpp"
drawer_cmake="${root}/packages/thorch-kde-defaults/actiondrawer/CMakeLists.txt"
pkgbuild="${root}/packages/thorch-kde-defaults/PKGBUILD"
autostart_entry="${root}/packages/thorch-kde-defaults/payload/etc/xdg/autostart/org.thorch.DesktopActionDrawer.desktop"
defaults="${root}/packages/thorch-kde-defaults/payload/etc/xdg/plasmamobilerc"
install_script="${root}/packages/thorch-kde-defaults/thorch-kde-defaults.install"
sessionctl="${root}/packages/thorch-kde-defaults/payload/usr/bin/thorch-sessionctl"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash -n "${windowctl}" || fail "thorch-windowctl has invalid shell syntax"
bash -n "${sessionctl}" || fail "thorch-sessionctl has invalid shell syntax"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
install -d "${tmp}/runtime"

for action in move-active-top move-active-bottom swap-active; do
  script_path="$(
    THORCH_WINDOWCTL_GENERATE_ONLY=1 \
      XDG_RUNTIME_DIR="${tmp}/runtime" \
      "${windowctl}" "${action}"
  )"
  grep -Fq "const commandName = \"${action}\";" "${script_path}" ||
    fail "generated KWin action does not preserve ${action}"
  if command -v node >/dev/null 2>&1; then
    node --check "${script_path}" >/dev/null ||
      fail "generated KWin script is invalid JavaScript for ${action}"
  fi
done

grep -q 'window.output' "${tmp}/runtime/thorch-windowctl-action.js" ||
  fail "Swap Screens does not inspect the active window output"
grep -q 'workspace.sendClientToScreen(window, destination)' \
  "${tmp}/runtime/thorch-windowctl-action.js" ||
  fail "window action does not use the verified KWin output API"

grep -Fq 'MobileShell.ActionDrawerOpenSurface' "${drawer_qml}" ||
  fail "Desktop integration does not reuse Plasma Mobile's swipe surface"
grep -Fq 'MobileShell.ActionDrawer {' "${drawer_qml}" ||
  fail "Desktop integration does not host Plasma Mobile's ActionDrawer"
grep -Fq 'notificationModel: NotificationManager.Notifications' "${drawer_qml}" ||
  fail "Desktop action drawer does not provide the notification model used by Mobile"
grep -Fq 'readonly property var controlScreen: thorchControlScreen' "${drawer_qml}" ||
  fail "Desktop action drawer does not use the native control screen"
grep -Fq 'screen->name() == QStringLiteral("DSI-1")' "${drawer_main}" ||
  fail "Desktop action drawer does not select the control display"
grep -Fq 'setContextProperty(QStringLiteral("thorchControlScreen"), controlScreen())' "${drawer_main}" ||
  fail "Desktop action drawer does not expose a QScreen to QML"
if grep -Fq 'Qt.application.screens' "${drawer_qml}"; then
  fail "Desktop action drawer passes QQuickScreenInfo where QScreen is required"
fi
grep -Fq 'height: 24' "${drawer_qml}" ||
  fail "Desktop action drawer has no narrow top-edge gesture target"
[[ "$(grep -Fc 'root.controlScreen.geometry.width' "${drawer_qml}")" -eq 2 ]] ||
  fail "Desktop action drawer does not size both windows from QScreen geometry"
grep -Fq 'root.controlScreen.geometry.height' "${drawer_qml}" ||
  fail "Desktop action drawer does not size its overlay from QScreen geometry"
grep -Fq 'visible: root.controlScreen !== null && drawer.intendedToBeVisible' "${drawer_qml}" ||
  fail "Desktop drawer surface is not hidden while closed"
grep -Fq 'LayerShell.Window.layer: LayerShell.Window.LayerOverlay' "${drawer_qml}" ||
  fail "Desktop drawer is not a Wayland overlay"
grep -Fq ".split(QLatin1Char(':'), Qt::SkipEmptyParts)" "${drawer_main}" ||
  fail "Desktop drawer host does not parse session environment values as colon-separated tokens"
grep -Fq 'return tokens.contains(expectedToken, Qt::CaseInsensitive);' "${drawer_main}" ||
  fail "Desktop drawer host does not match session environment tokens case-insensitively"
grep -Fq 'environmentContainsToken("XDG_SESSION_DESKTOP", QStringLiteral("plasma-mobile"))' \
  "${drawer_main}" ||
  fail "Desktop drawer host does not defer to the Plasma Mobile session desktop"
grep -Fq 'environmentContainsToken("PLASMA_PLATFORM", QStringLiteral("phone"))' \
  "${drawer_main}" ||
  fail "Desktop drawer host does not defer to the phone Plasma platform token"
grep -Fq 'environmentContainsToken("PLASMA_PLATFORM", QStringLiteral("mobile"))' \
  "${drawer_main}" ||
  fail "Desktop drawer host does not defer to the mobile Plasma platform token"
grep -Fq 'RUNTIME DESTINATION ${KDE_INSTALL_LIBDIR}' "${drawer_cmake}" ||
  fail "Desktop drawer binary is not installed at the autostart path"
grep -Fxq 'Exec=/usr/lib/thorch-desktop-action-drawer' "${autostart_entry}" ||
  fail "Desktop drawer autostart does not launch the installed binary"
grep -Eq '^depends=.*(^|[ (])layer-shell-qt([ )]|$)' "${pkgbuild}" ||
  fail "Desktop drawer does not declare its layer-shell runtime dependency"

if find "${root}/packages/thorch-kde-defaults" -path '*/org.thorch.CompanionPanel.desktop' -o -path '*/companion/Main.qml' | grep -q .; then
  fail "retired persistent companion surface is still packaged"
fi

for wanted in \
  org.thorch.quicksetting.moveActiveTop \
  org.thorch.quicksetting.swapActive \
  org.thorch.quicksetting.moveActiveBottom; do
  grep -q "${wanted}" "${defaults}" ||
    fail "default action drawer is missing ${wanted}"
done

for retired in \
  org.kde.plasma.quicksetting.hotspot \
  org.kde.plasma.quicksetting.autohidepanels \
  org.thorch.quicksetting.usbGadget \
  org.thorch.quicksetting.moveWindowsBottom \
  org.thorch.quicksetting.moveSteamTop \
  org.thorch.quicksetting.openSteam \
  org.thorch.quicksetting.closeSteam; do
  grep -q "disabledQuickSettings=.*${retired}" "${defaults}" ||
    fail "default quick settings do not retire ${retired}"
done

user_config="${tmp}/home/test/.config/plasmamobilerc"
install -d "$(dirname "${user_config}")"
cat >"${user_config}" <<'EOF'
[QuickSettings]
enabledQuickSettings=org.kde.plasma.quicksetting.wifi,org.kde.plasma.quicksetting.hotspot,org.thorch.quicksetting.moveSteamTop,org.example.keep
disabledQuickSettings=org.example.alreadyDisabled
EOF

THORCH_INSTALL_ROOT="${tmp}" THORCH_HOME_ROOT="${tmp}/home" \
  bash -c 'source "$1"; remove_retired_quick_settings' _ "${install_script}"

grep -q '^enabledQuickSettings=org.kde.plasma.quicksetting.wifi,org.example.keep$' "${user_config}" ||
  fail "quick-settings migration did not preserve user choices while removing retired entries"
grep -q 'disabledQuickSettings=.*org.example.alreadyDisabled' "${user_config}" ||
  fail "quick-settings migration discarded an existing disabled entry"
grep -q 'disabledQuickSettings=.*org.kde.plasma.quicksetting.hotspot' "${user_config}" ||
  fail "quick-settings migration did not disable hotspot"
grep -q 'disabledQuickSettings=.*org.thorch.quicksetting.moveSteamTop' "${user_config}" ||
  fail "quick-settings migration did not disable the Steam movement action"

drawer_mode_function="$(
  awk '
    /^mode_uses_custom_action_drawer\(\)/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "${sessionctl}"
)"
for mode in desktop mobile steamos steamos-mobile steamos-desktop; do
  bash -c "${drawer_mode_function}"$'\n''mode_uses_custom_action_drawer "$1"' _ "${mode}" ||
    fail "${mode} sessions do not retain the customized action drawer"
done

printf 'thorch Desktop action drawer checks passed\n'
