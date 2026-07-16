// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.Window
import QtQuick.VirtualKeyboard.Components

Key {
    id: keyItem

    property int thorchAccent: 1

    displayText: "Settings"
    noKeyEvent: true
    functionKey: true

    onClicked: {
        const targetWindow = keyItem.Window.window;
        const showSettings = targetWindow ? targetWindow["showSettings"] : null;
        if (typeof showSettings === "function") {
            showSettings.call(targetWindow);
        }
    }
}
