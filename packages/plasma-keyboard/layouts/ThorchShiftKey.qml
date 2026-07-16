// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

Key {
    property int thorchAccent: 1

    key: Qt.Key_Shift
    displayText: "Shift"
    enabled: InputContext.priv.shiftHandler.toggleShiftEnabled
    highlighted: InputContext.shiftActive
    functionKey: true
    noKeyEvent: true

    onClicked: InputContext.priv.shiftHandler.toggleShift()
}
