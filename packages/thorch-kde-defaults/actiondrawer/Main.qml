// SPDX-FileCopyrightText: 2026 Thorch contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import QtQuick
import QtQuick.Window
import org.kde.layershell 1.0 as LayerShell
import org.kde.notificationmanager as NotificationManager
import org.kde.plasma.private.mobileshell as MobileShell

Item {
    id: root

    readonly property var controlScreen: thorchControlScreen

    // Plasma Mobile opens its drawer by dragging its top status panel. Plasma
    // Desktop has no such surface, so provide only that narrow gesture target.
    Window {
        id: edgeSurface

        title: "Thorch Action Drawer Edge"
        screen: root.controlScreen
        width: root.controlScreen ? root.controlScreen.geometry.width : 0
        height: 24
        color: "transparent"
        flags: Qt.FramelessWindowHint | Qt.Tool | Qt.WindowDoesNotAcceptFocus
        visible: root.controlScreen !== null

        LayerShell.Window.screen: root.controlScreen
        LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorLeft | LayerShell.Window.AnchorRight
        LayerShell.Window.layer: LayerShell.Window.LayerOverlay
        LayerShell.Window.exclusionZone: -1
        LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityNone
        LayerShell.Window.scope: "thorch-desktop-action-drawer-edge"

        MobileShell.ActionDrawerOpenSurface {
            anchors.fill: parent
            actionDrawer: drawer
        }
    }

    // This is Plasma Mobile's ActionDrawer itself. The only Desktop-specific
    // code here is the output-bound layer-shell window that hosts it.
    Window {
        id: drawerSurface

        property alias actionDrawer: drawer
        property alias state: drawer.state

        title: "Thorch Action Drawer"
        screen: root.controlScreen
        width: root.controlScreen ? root.controlScreen.geometry.width : 0
        height: root.controlScreen ? root.controlScreen.geometry.height : 0
        color: "transparent"
        visible: root.controlScreen !== null && drawer.intendedToBeVisible

        LayerShell.Window.screen: root.controlScreen
        LayerShell.Window.anchors: LayerShell.Window.AnchorTop | LayerShell.Window.AnchorBottom | LayerShell.Window.AnchorLeft | LayerShell.Window.AnchorRight
        LayerShell.Window.layer: LayerShell.Window.LayerOverlay
        LayerShell.Window.exclusionZone: -1
        LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityNone
        LayerShell.Window.scope: "thorch-desktop-action-drawer"

        onStateChanged: MobileShell.ShellUtil.setInputTransparent(drawerSurface, state === "close")

        onVisibleChanged: {
            if (visible) {
                raise();
            }
        }

        onActiveChanged: {
            if (!active) {
                drawer.close();
            }
        }

        MobileShell.ActionDrawer {
            id: drawer
            anchors.fill: parent

            notificationSettings: NotificationManager.Settings {}
            notificationModel: NotificationManager.Notifications {
                showExpired: true
                showDismissed: true
                showJobs: drawer.notificationSettings.jobsInNotifications
                sortMode: NotificationManager.Notifications.SortByTypeAndUrgency
                groupMode: NotificationManager.Notifications.GroupApplicationsFlat
                groupLimit: 2
                expandUnread: true
                blacklistedDesktopEntries: drawer.notificationSettings.historyBlacklistedApplications
                blacklistedNotifyRcNames: drawer.notificationSettings.historyBlacklistedServices
                urgencies: {
                    let values = NotificationManager.Notifications.CriticalUrgency | NotificationManager.Notifications.NormalUrgency;
                    if (drawer.notificationSettings.lowPriorityHistory) {
                        values |= NotificationManager.Notifications.LowUrgency;
                    }
                    return values;
                }
            }
        }
    }
}
