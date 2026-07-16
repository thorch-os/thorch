// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.Window
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Settings

Window {
    id: root

    width: 1240
    height: 1080
    visible: true

    TextInput {
        id: input
        focus: true
        width: 200
        height: 40

        property int receivedKey: Qt.Key_unknown
        property int receivedModifiers: Qt.NoModifier

        Keys.onPressed: event => {
            receivedKey = event.key;
            receivedModifiers = event.modifiers;
            event.accepted = true;
        }
    }

    InputPanel {
        id: inputPanel
        active: true
        width: parent.width
        y: parent.height - height
    }

    Timer {
        interval: 5000
        running: true

        onTriggered: {
            const layout = inputPanel.keyboard.keyboardLayoutLoader.item;
            if (!layout || layout.objectName !== "thorchKeyboardLayout") {
                console.error("Configured path:", VirtualKeyboardSettings.layoutPath);
                console.error("Available locales:", VirtualKeyboardSettings.availableLocales);
                console.error("Layout URL:", inputPanel.keyboard.layout);
                console.error("Layout locale:", inputPanel.keyboard.locale);
                console.error("Layout root:", layout ? layout.objectName : "null");
                console.error("Thorch keyboard layout was not instantiated");
                Qt.exit(1);
                return;
            }
            if (!layout.item || layout.item.children.length !== 6) {
                console.error("Thorch keyboard main page has an unexpected row count");
                Qt.exit(1);
                return;
            }

            const ctrlKey = findNamedItem(layout, "thorchControlModifierKey");
            const cKey = findNamedItem(layout, "thorchLetterCKey");
            const shiftKey = findNamedItem(layout, "thorchShiftModifierKey");
            const numberOneKey = findNamedItem(layout, "thorchNumberOneKey");
            const navKey = findNamedItem(layout, "thorchNavigationPageKey");
            if (!ctrlKey || !cKey || !shiftKey || !numberOneKey || !navKey) {
                console.error("Thorch keyboard test controls were not instantiated");
                Qt.exit(1);
                return;
            }

            input.forceActiveFocus();
            input.receivedKey = Qt.Key_unknown;
            input.receivedModifiers = Qt.NoModifier;
            ctrlKey.clicked();
            cKey.clicked();
            if (input.receivedKey !== Qt.Key_C || !(input.receivedModifiers & Qt.ControlModifier)) {
                console.error("Input focus:", input.activeFocus, root.activeFocusItem);
                console.error("Sticky Ctrl chord did not reach the focused input");
                Qt.exit(1);
                return;
            }
            if (layout.thorchStickyModifiers !== Qt.NoModifier) {
                console.error("Sticky Ctrl modifier was not consumed after one chord");
                Qt.exit(1);
                return;
            }

            input.receivedKey = Qt.Key_unknown;
            input.receivedModifiers = Qt.NoModifier;
            shiftKey.clicked();
            numberOneKey.clicked();
            if (input.receivedKey !== Qt.Key_1 || !(input.receivedModifiers & Qt.ShiftModifier)) {
                console.error("Shift chord did not reach the focused input:", input.receivedKey, input.receivedModifiers);
                Qt.exit(1);
                return;
            }

            navKey.clicked();
            Qt.callLater(checkNavigationPage);
        }
    }

    function findNamedItem(item, name) {
        if (!item) {
            return null;
        }
        if (item.objectName === name) {
            return item;
        }
        const children = item.children || [];
        for (let index = 0; index < children.length; ++index) {
            const match = findNamedItem(children[index], name);
            if (match) {
                return match;
            }
        }
        return null;
    }

    function checkNavigationPage() {
        const layout = inputPanel.keyboard.keyboardLayoutLoader.item;
        if (!layout.thorchNavigationPage || !layout.item || layout.item.children.length !== 6) {
            console.error("Thorch keyboard navigation page did not activate");
            Qt.exit(1);
            return;
        }

        const mainKey = findNamedItem(layout, "thorchMainPageKey");
        const keypadSevenKey = findNamedItem(layout, "thorchKeypadSevenKey");
        if (!mainKey || !keypadSevenKey) {
            console.error("Thorch keyboard navigation page cannot return to the main page");
            Qt.exit(1);
            return;
        }

        input.receivedKey = Qt.Key_unknown;
        input.receivedModifiers = Qt.NoModifier;
        keypadSevenKey.clicked();
        if (input.receivedKey !== Qt.Key_7 || !(input.receivedModifiers & Qt.KeypadModifier)) {
            console.error("Numeric keypad event did not reach the focused input:", input.receivedKey, input.receivedModifiers);
            Qt.exit(1);
            return;
        }

        mainKey.clicked();
        Qt.callLater(() => {
            if (layout.thorchNavigationPage) {
                console.error("Thorch keyboard did not return to the main page");
                Qt.exit(1);
                return;
            }
            console.log("Thorch keyboard layout smoke test passed");
            Qt.quit();
        });
    }

    Component.onCompleted: {
        VirtualKeyboardSettings.activeLocales = ["en_US"];
        VirtualKeyboardSettings.locale = "en_US";
        root.requestActivate();
        input.forceActiveFocus();
    }
}
