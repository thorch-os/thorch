// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

Key {
    property int thorchAccent: 1

    key: Qt.Key_CapsLock
    displayText: "Caps"
    highlighted: InputContext.capsLockActive
    functionKey: true
    noKeyEvent: true

    onClicked: {
        const shiftHandler = InputContext.priv.shiftHandler;
        shiftHandler.capsLockActive = !shiftHandler.capsLockActive;
        shiftHandler.shiftActive = false;
    }
}
