// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.Window
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Settings

import org.kde.plasma.keyboard

Window {
    id: root

    width: 1240
    height: 1080
    visible: true

    property var initialThorchLayout: null
    property var initialMainPage: null

    function fail(message) {
        console.error(message);
        Qt.exit(1);
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

    function findBaseText(item, text) {
        if (!item) {
            return null;
        }
        if (item.baseText !== undefined && item.baseText === text) {
            return item;
        }
        const children = item.children || [];
        for (let index = 0; index < children.length; ++index) {
            const match = findBaseText(children[index], text);
            if (match) {
                return match;
            }
        }
        return null;
    }

    function childIndex(parentItem, childItem) {
        const children = parentItem.children || [];
        for (let index = 0; index < children.length; ++index) {
            if (children[index] === childItem) {
                return index;
            }
        }
        return -1;
    }

    function visibleRowCount(keyboardLayout) {
        let count = 0;
        const children = keyboardLayout.children || [];
        for (let index = 0; index < children.length; ++index) {
            if (children[index].visible) {
                ++count;
            }
        }
        return count;
    }

    function activePage(layout) {
        if (!layout || (initialThorchLayout && layout !== initialThorchLayout)) {
            return null;
        }
        return layout.thorchActiveLayout;
    }

    function checkUtilityRow(layout) {
        const page = activePage(layout);
        const utilityRow = findNamedItem(page, "thorchUtilityRow");
        const ctrlKey = findNamedItem(page, "thorchControlModifierKey");
        const altKey = findNamedItem(page, "thorchAltModifierKey");
        const navigationKey = findNamedItem(page, "thorchNavigationPageKey");
        const settingsKey = findNamedItem(page, "thorchKeyboardSettingsKey");

        if (!utilityRow || !ctrlKey || !altKey || !navigationKey || !settingsKey) {
            fail("Desktop utility row is incomplete");
            return false;
        }
        if (utilityRow.children.length !== 4) {
            fail("Desktop utility row must contain exactly Ctrl, Alt, Nav, and Settings");
            return false;
        }
        if (ctrlKey.modifier !== Qt.ControlModifier
                || altKey.modifier !== Qt.AltModifier
                || navigationKey.displayText !== "Nav") {
            fail("Desktop utility row has incorrect modifier or page bindings");
            return false;
        }
        return true;
    }

    TextInput {
        id: input
        focus: true
        width: 200
        height: 40
        inputMethodHints: Qt.ImhNoAutoUppercase

        property int receivedKey: Qt.Key_unknown
        property int receivedModifiers: Qt.NoModifier
        property string receivedText: ""

        Keys.onPressed: event => {
            receivedKey = event.key;
            receivedModifiers = event.modifiers;
            receivedText = event.text;
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

        onTriggered: checkMainPage()
    }

    function currentLayout() {
        return inputPanel.keyboard.keyboardLayoutLoader.item;
    }

    function resetShiftState(layout) {
        const shiftHandler = InputContext.priv.shiftHandler;
        shiftHandler.capsLockActive = false;
        shiftHandler.shiftActive = false;
        shiftHandler.clearToggleShiftTimer();
        layout.thorchManualShiftActive = false;
    }

    function checkMainPage() {
        const layout = currentLayout();
        if (!layout || layout.objectName !== "thorchKeyboardLayout") {
            console.error("Configured path:", VirtualKeyboardSettings.layoutPath);
            console.error("Available locales:", VirtualKeyboardSettings.availableLocales);
            console.error("Layout URL:", inputPanel.keyboard.layout);
            console.error("Layout locale:", inputPanel.keyboard.locale);
            fail("Thorch keyboard layout was not instantiated");
            return;
        }
        initialThorchLayout = layout;
        const page = activePage(layout);
        initialMainPage = page;
        if (layout.thorchPage !== "main" || !page || page.objectName !== "thorchMainLayout"
                || page.children.length !== 7 || visibleRowCount(page) !== 6) {
            fail("ABC page does not have the expected six visible touch rows");
            return;
        }

        const functionRow = findNamedItem(page, "thorchFunctionRow");
        const numberRow = findNamedItem(page, "thorchNumberRow");
        const tabKey = findNamedItem(page, "thorchTabKey");
        const aKey = findNamedItem(page, "thorchLetterAKey");
        const oKey = findNamedItem(page, "thorchLetterOKey");
        const pKey = findNamedItem(page, "thorchLetterPKey");
        const lKey = findNamedItem(page, "thorchLetterLKey");
        const shiftKey = findNamedItem(page, "thorchShiftModifierKey");
        const zKey = findNamedItem(page, "thorchLetterZKey");
        const cKey = findNamedItem(page, "thorchLetterCKey");
        const vKey = findNamedItem(page, "thorchLetterVKey");
        const mKey = findNamedItem(page, "thorchLetterMKey");
        const backspaceKey = findNamedItem(page, "thorchMainBackspaceKey");
        const symbolsKey = findNamedItem(page, "thorchSymbolsPageKey");
        const ctrlKey = findNamedItem(page, "thorchControlModifierKey");

        if (!functionRow || !numberRow || !tabKey || !aKey || !oKey || !pKey || !lKey
                || !shiftKey || !zKey || !cKey || !vKey || !mKey || !backspaceKey
                || !symbolsKey || !ctrlKey) {
            fail("ABC page is missing a required touch or desktop key");
            return;
        }
        if (functionRow.visible || !numberRow.visible) {
            fail("ABC page defaults must hide F-keys and show the number row");
            return;
        }
        if (shiftKey.parent !== zKey.parent
                || childIndex(zKey.parent, shiftKey) + 1 !== childIndex(zKey.parent, zKey)) {
            fail("Shift is not immediately left of Z");
            return;
        }
        if (mKey.parent !== backspaceKey.parent
                || childIndex(mKey.parent, mKey) + 1 !== childIndex(mKey.parent, backspaceKey)) {
            fail("Backspace is not immediately right of M");
            return;
        }
        if (Math.abs(tabKey.width - aKey.width) > 1) {
            fail("Tab is not the same size as the home-row letter keys");
            return;
        }
        const oCenter = oKey.mapToItem(page, oKey.width / 2, 0).x;
        const pCenter = pKey.mapToItem(page, pKey.width / 2, 0).x;
        const lCenter = lKey.mapToItem(page, lKey.width / 2, 0).x;
        if (!(lCenter > oCenter && lCenter < pCenter)) {
            fail("Home row is not staggered with L beneath O and P");
            return;
        }
        if (!checkUtilityRow(layout)) {
            return;
        }

        input.forceActiveFocus();
        input.receivedKey = Qt.Key_unknown;
        input.receivedModifiers = Qt.NoModifier;
        ctrlKey.clicked();
        cKey.clicked();
        if (input.receivedKey !== Qt.Key_C || !(input.receivedModifiers & Qt.ControlModifier)) {
            fail("Sticky Ctrl+C did not reach the focused input");
            return;
        }
        if (layout.thorchStickyModifiers !== Qt.NoModifier) {
            fail("Sticky Ctrl was not consumed after one chord");
            return;
        }

        input.receivedKey = Qt.Key_unknown;
        input.receivedModifiers = Qt.NoModifier;
        ctrlKey.clicked();
        vKey.clicked();
        if (input.receivedKey !== Qt.Key_V || !(input.receivedModifiers & Qt.ControlModifier)) {
            fail("Sticky Ctrl+V did not reach the focused input");
            return;
        }

        resetShiftState(layout);
        const numberOneKey = findNamedItem(page, "thorchNumberOneKey");
        input.receivedKey = Qt.Key_unknown;
        input.receivedModifiers = Qt.NoModifier;
        input.receivedText = "";
        shiftKey.clicked();
        numberOneKey.clicked();
        if (input.receivedKey !== Qt.Key_1
                || !(input.receivedModifiers & Qt.ShiftModifier)
                || input.receivedText !== "!") {
            fail("Shifted number-row symbols did not produce the mapped text");
            return;
        }

        resetShiftState(layout);
        input.receivedKey = Qt.Key_unknown;
        input.receivedModifiers = Qt.NoModifier;
        input.receivedText = "";
        shiftKey.clicked();
        tabKey.clicked();
        if (input.receivedKey !== Qt.Key_Tab || !(input.receivedModifiers & Qt.ShiftModifier)) {
            fail("One-shot Shift+Tab did not reach the focused input");
            return;
        }
        if (layout.thorchManualShiftActive || InputContext.shiftActive) {
            fail("One-shot Shift was not consumed");
            return;
        }

        resetShiftState(layout);
        input.receivedKey = Qt.Key_unknown;
        input.receivedModifiers = Qt.NoModifier;
        input.receivedText = "";
        shiftKey.clicked();
        cKey.clicked();
        if (input.receivedKey !== Qt.Key_C
                || !(input.receivedModifiers & Qt.ShiftModifier)
                || input.receivedText !== "C") {
            fail("One-shot Shift+C did not produce an uppercase key event");
            return;
        }

        resetShiftState(layout);
        shiftKey.clicked();
        shiftKey.clicked();
        if (!InputContext.capsLockActive || shiftKey.displayText !== "Caps"
                || layout.thorchManualShiftActive || cKey.displayText !== "C") {
            fail("Double-tapping Shift did not enable Caps Lock");
            return;
        }
        shiftKey.clicked();
        if (InputContext.capsLockActive || shiftKey.displayText !== "Shift") {
            fail("Tapping Shift did not disable Caps Lock");
            return;
        }

        PlasmaKeyboardSettings.showFunctionRow = true;
        if (!functionRow.visible) {
            fail("Function-row setting did not show the F-keys");
            return;
        }
        PlasmaKeyboardSettings.showFunctionRow = false;
        PlasmaKeyboardSettings.showNumberRow = false;
        if (functionRow.visible || numberRow.visible) {
            fail("Row visibility settings did not update the ABC page");
            return;
        }
        PlasmaKeyboardSettings.showNumberRow = true;

        for (const height of [100, 65, 50]) {
            PlasmaKeyboardSettings.panelHeightPercent = height;
            if (PlasmaKeyboardSettings.panelHeightPercent !== height) {
                fail("Keyboard height setting did not preserve " + height + "%");
                return;
            }
        }
        PlasmaKeyboardSettings.panelHeightPercent = 100;

        symbolsKey.clicked();
        if (!layout.thorchSymbolsPage || activePage(layout).objectName !== "thorchSymbolsLayout") {
            fail("123 page did not switch synchronously");
            return;
        }
        Qt.callLater(checkSymbolsPage);
    }

    function checkSymbolsPage() {
        const layout = currentLayout();
        const page = activePage(layout);
        if (!layout.thorchSymbolsPage || !page || page.children.length !== 5
                || findNamedItem(layout, "thorchMainLayout") !== initialMainPage) {
            fail("123 page did not activate with five touch rows");
            return;
        }

        const zeroKey = findNamedItem(page, "thorchSymbolsZeroKey");
        const moreKey = findNamedItem(page, "thorchSymbolsMorePageKey");
        const mainKey = findNamedItem(page, "thorchSymbolsMainPageKey");
        const backspaceKey = findNamedItem(page, "thorchSymbolsBackspaceKey");
        if (!zeroKey || !moreKey || !mainKey || !backspaceKey
                || moreKey.displayText !== "#+=" || mainKey.displayText !== "ABC") {
            fail("123 page is missing its zero, mode, ABC, or Backspace key");
            return;
        }
        if (!findBaseText(page, "-") || !findBaseText(page, "@")
                || !findBaseText(page, "\"") || !findBaseText(page, "?")) {
            fail("123 page is missing required punctuation");
            return;
        }
        if (!checkUtilityRow(layout)) {
            return;
        }

        moreKey.clicked();
        Qt.callLater(checkSymbolsMorePage);
    }

    function checkSymbolsMorePage() {
        const layout = currentLayout();
        const page = activePage(layout);
        if (!layout.thorchSymbolsMorePage || !page || page.children.length !== 5) {
            fail("#+= page did not activate with five touch rows");
            return;
        }
        if (!findBaseText(page, "[") || !findBaseText(page, "}")
                || !findBaseText(page, "\\") || !findBaseText(page, "|")
                || !findBaseText(page, "£") || !findBaseText(page, "€")
                || !findBaseText(page, "¥") || !findBaseText(page, "•")) {
            fail("#+= page is missing required programming or currency symbols");
            return;
        }

        const symbolsKey = findNamedItem(page, "thorchSymbolsMoreBackKey");
        const mainKey = findNamedItem(page, "thorchSymbolsMoreMainPageKey");
        const backspaceKey = findNamedItem(page, "thorchSymbolsMoreBackspaceKey");
        if (!symbolsKey || !mainKey || !backspaceKey
                || symbolsKey.displayText !== "123" || mainKey.displayText !== "ABC") {
            fail("#+= page is missing its mode, ABC, or Backspace key");
            return;
        }
        if (!checkUtilityRow(layout)) {
            return;
        }

        symbolsKey.clicked();
        Qt.callLater(() => {
            const symbolsLayout = currentLayout();
            const mainPageKey = findNamedItem(activePage(symbolsLayout), "thorchSymbolsMainPageKey");
            if (!symbolsLayout.thorchSymbolsPage || !mainPageKey) {
                fail("#+= page could not return to 123");
                return;
            }
            mainPageKey.clicked();
            Qt.callLater(checkNavigationEntry);
        });
    }

    function checkNavigationEntry() {
        const layout = currentLayout();
        const navigationKey = findNamedItem(activePage(layout), "thorchNavigationPageKey");
        if (layout.thorchPage !== "main" || !navigationKey) {
            fail("123 page could not return to ABC");
            return;
        }

        navigationKey.clicked();
        Qt.callLater(checkNavigationPage);
    }

    function checkNavigationPage() {
        const layout = currentLayout();
        const page = activePage(layout);
        if (!layout.thorchNavigationPage || !page || page.children.length !== 7) {
            fail("Navigation page did not activate");
            return;
        }

        const mainKey = findNamedItem(page, "thorchMainPageKey");
        const keypadSevenKey = findNamedItem(page, "thorchKeypadSevenKey");
        const escapeKey = findNamedItem(page, "thorchNavigationEscapeKey");
        const f12Key = findNamedItem(page, "thorchNavigationF12Key");
        if (!mainKey || !keypadSevenKey || !escapeKey || !f12Key || !checkUtilityRow(layout)) {
            fail("Nav page is missing its ABC, Esc, function, navigation, keypad, or utility controls");
            return;
        }

        input.receivedKey = Qt.Key_unknown;
        input.receivedModifiers = Qt.NoModifier;
        keypadSevenKey.clicked();
        if (input.receivedKey !== Qt.Key_7 || !(input.receivedModifiers & Qt.KeypadModifier)) {
            fail("Numeric keypad event did not reach the focused input");
            return;
        }

        mainKey.clicked();
        Qt.callLater(() => {
            if (layout.thorchPage !== "main") {
                fail("Navigation page did not return to ABC");
                return;
            }
            console.log("Thorch keyboard layout smoke test passed");
            Qt.quit();
        });
    }

    Component.onCompleted: {
        PlasmaKeyboardSettings.showFunctionRow = false;
        PlasmaKeyboardSettings.showNumberRow = true;
        VirtualKeyboardSettings.activeLocales = ["en_US"];
        VirtualKeyboardSettings.locale = "en_US";
        root.requestActivate();
        input.forceActiveFocus();
    }
}
