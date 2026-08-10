// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard.Components

KeyboardRow {
    objectName: "thorchUtilityRow"

    ThorchModifierKey {
        objectName: "thorchControlModifierKey"
        modifier: Qt.ControlModifier
        displayText: "Ctrl"
        weight: 24
    }
    ThorchModifierKey {
        objectName: "thorchAltModifierKey"
        modifier: Qt.AltModifier
        displayText: "Alt"
        weight: 20
    }
    ThorchPageKey {
        objectName: "thorchNavigationPageKey"
        targetPage: "navigation"
        weight: 28
    }
    ThorchSettingsKey {
        objectName: "thorchKeyboardSettingsKey"
        weight: 28
    }
}
