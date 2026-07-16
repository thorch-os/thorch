// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard.Components

Key {
    id: keyItem

    required property int modifier
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

    noKeyEvent: true
    functionKey: true
    highlighted: modifierState && (modifierState.thorchStickyModifiers & modifier) !== 0

    onClicked: {
        if (modifierState) {
            modifierState.toggleThorchModifier(modifier);
        }
    }
}
