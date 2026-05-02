/*
 *   SPDX-FileCopyrightText: 2022 Devin Lin <devin@kde.org>
 *
 *   SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick 2.15
import QtQuick.Window

/**
 * Thorch override: use a regular frameless Qt window on the control display.
 * The upstream layer-shell overlay is currently placed on DSI-2 by KWin.
 */
Window {
    id: window

    function thorchControlScreen() {
        const screens = Qt.application.screens;
        for (let i = 0; i < screens.length; i++) {
            if (screens[i].name === "DSI-1") {
                return screens[i];
            }
        }
        return screens.length > 0 ? screens[0] : null;
    }

    property alias actionDrawer: drawer
    property alias state: drawer.state

    title: "Thorch Action Drawer"
    screen: thorchControlScreen()
    width: screen ? screen.width : 620
    height: screen ? screen.height : 540
    color: "transparent"
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    visible: true

    Component.onCompleted: preloadTimer.start()

    Timer {
        id: preloadTimer
        interval: 1
        onTriggered: {
            window.visible = Qt.binding(() => drawer.intendedToBeVisible);
        }
    }

    onVisibleChanged: {
        if (visible) {
            window.raise();
        }
    }

    ActionDrawer {
        id: drawer
        anchors.fill: parent
    }
}
