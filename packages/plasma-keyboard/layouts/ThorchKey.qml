// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

Key {
    id: keyItem

    property string baseText: ""
    property string shiftText: ""
    property int fixedModifiers: Qt.NoModifier
    property int thorchAccent: 0

    readonly property bool thorchManualShift: InputContext.priv.shiftHandler.shiftActive && !InputContext.priv.shiftHandler.capsLockActive
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
    readonly property int activeModifiers: modifierState ? modifierState.thorchStickyModifiers : Qt.NoModifier

    text: shiftText.length > 0 && thorchManualShift ? shiftText : baseText
    displayText: text
    noKeyEvent: activeModifiers !== Qt.NoModifier || fixedModifiers !== Qt.NoModifier || thorchManualShift

    onClicked: {
        if (!noKeyEvent) {
            return;
        }

        const modifiers = activeModifiers | fixedModifiers | (thorchManualShift ? Qt.ShiftModifier : Qt.NoModifier);
        InputContext.sendKeyClick(key, "", modifiers);

        if (thorchManualShift) {
            InputContext.priv.shiftHandler.shiftActive = false;
        }
        if (modifierState && activeModifiers !== Qt.NoModifier) {
            modifierState.consumeThorchModifiers();
        }
    }
}
