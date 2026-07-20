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
    readonly property bool thorchManualShiftPending: modifierState ? modifierState.thorchManualShiftActive : false
    readonly property bool thorchManualShift: thorchManualShiftPending && !noModifier
    readonly property int activeModifiers: modifierState ? modifierState.thorchStickyModifiers : Qt.NoModifier
    readonly property bool thorchUppercase: InputContext.uppercase && !noModifier
    readonly property string thorchEffectiveText: thorchUppercase
        ? (shiftText.length > 0 ? shiftText : baseText.toUpperCase())
        : baseText

    text: baseText
    displayText: thorchEffectiveText
    noKeyEvent: activeModifiers !== Qt.NoModifier || fixedModifiers !== Qt.NoModifier || thorchManualShift

    onClicked: {
        if (!noKeyEvent) {
            if (modifierState && thorchManualShiftPending) {
                modifierState.consumeThorchShift();
            }
            return;
        }

        const modifiers = activeModifiers | fixedModifiers | (thorchManualShift ? Qt.ShiftModifier : Qt.NoModifier);
        InputContext.sendKeyClick(key, thorchEffectiveText, modifiers);

        if (modifierState && thorchManualShiftPending) {
            modifierState.consumeThorchShift();
        }
        if (modifierState && activeModifiers !== Qt.NoModifier) {
            modifierState.consumeThorchModifiers();
        }
    }
}
