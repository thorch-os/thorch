// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

Key {
    property int thorchAccent: 1

    readonly property var modifierState: {
        let item = parent;
        while (item) {
            if (item.thorchStickyModifiers !== undefined) {
                return item;
            }
            item = item.parent;
        }
        return null;
    }

    key: Qt.Key_Shift
    displayText: InputContext.capsLockActive ? "Caps" : "Shift"
    enabled: InputContext.priv.shiftHandler.toggleShiftEnabled
    highlighted: InputContext.uppercase
    functionKey: true
    noKeyEvent: true

    onClicked: {
        InputContext.priv.shiftHandler.toggleShift();
        if (modifierState) {
            modifierState.thorchManualShiftActive = InputContext.shiftActive && !InputContext.capsLockActive;
        }
    }
}
