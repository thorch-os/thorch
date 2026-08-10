// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

Key {
    property int thorchAccent: 2

    displayText: "Hide"
    noKeyEvent: true
    functionKey: true

    onClicked: keyboard.doKeyboardFunction(QtVirtualKeyboard.KeyboardFunction.HideInputPanel)
}
