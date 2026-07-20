// SPDX-FileCopyrightText: 2026 Thorch contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import QtQuick
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS
import org.kde.plasma.plasma5support as Plasma5Support

QS.QuickSetting {
    id: root

    text: i18n("Active to Top")
    status: running ? i18n("Moving window") : i18n("Move focused app to the top display")
    icon: "go-up"
    enabled: running

    property bool running: false

    function toggle() {
        if (!running) {
            running = true;
            recoveryTimer.restart();
            actionSource.connectSource("/usr/bin/thorch-windowctl move-active-top");
        }
    }

    Plasma5Support.DataSource {
        id: actionSource
        engine: "executable"
        onNewData: sourceName => {
            disconnectSource(sourceName);
            recoveryTimer.stop();
            root.running = false;
        }
    }

    Timer {
        id: recoveryTimer
        interval: 5000
        onTriggered: root.running = false
    }
}
