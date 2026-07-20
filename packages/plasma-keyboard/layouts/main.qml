// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.Layouts
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

import org.kde.plasma.keyboard

KeyboardLayout {
    id: layoutLoader
    objectName: "thorchKeyboardLayout"
    inputMode: InputEngine.InputMode.Latin

    property string thorchPage: "main"
    readonly property bool thorchNavigationPage: thorchPage === "navigation"
    readonly property bool thorchSymbolsPage: thorchPage === "symbols"
    readonly property bool thorchSymbolsMorePage: thorchPage === "symbolsMore"
    property int thorchStickyModifiers: Qt.NoModifier
    property bool thorchManualShiftActive: false
    readonly property int thorchPageIndex: thorchSymbolsPage
        ? 1
        : thorchSymbolsMorePage
            ? 2
            : thorchNavigationPage
                ? 3
                : 0
    readonly property Item thorchActiveLayout: thorchPageIndex === 1
        ? symbolsLayout
        : thorchPageIndex === 2
            ? symbolsMoreLayout
            : thorchPageIndex === 3
                ? navigationLayout
                : mainLayout

    function scanLayout() {
        return thorchActiveLayout ? thorchActiveLayout.scanLayout() : null;
    }

    function showThorchPage(page) {
        if (page !== thorchPage) {
            consumeThorchShift();
            thorchPage = page;
            // The pages stay instantiated, so switching is immediate and does
            // not reset the input method. Refresh only the touch key map.
            keyboard.notifyLayoutChanged();
        }
    }

    function toggleThorchModifier(modifier) {
        thorchStickyModifiers ^= modifier;
        modifierTimeout.restart();
    }

    function consumeThorchModifiers() {
        thorchStickyModifiers = Qt.NoModifier;
        modifierTimeout.stop();
    }

    function consumeThorchShift() {
        if (!thorchManualShiftActive) {
            return;
        }

        thorchManualShiftActive = false;
        const shiftHandler = InputContext.priv.shiftHandler;
        if (!shiftHandler.capsLockActive) {
            shiftHandler.shiftActive = false;
        }
        shiftHandler.clearToggleShiftTimer();
    }

    onVisibleChanged: {
        if (!visible) {
            thorchPage = "main";
            consumeThorchModifiers();
            consumeThorchShift();
        }
    }

    Timer {
        id: modifierTimeout
        interval: 8000
        onTriggered: layoutLoader.thorchStickyModifiers = Qt.NoModifier
    }

    StackLayout {
        id: pageStack
        Layout.fillWidth: true
        Layout.fillHeight: true
        currentIndex: layoutLoader.thorchPageIndex

        KeyboardLayout {
            id: mainLayout
            objectName: "thorchMainLayout"
            inputMode: InputEngine.InputMode.Latin
            keyWeight: 10

            KeyboardRow {
                objectName: "thorchFunctionRow"
                visible: PlasmaKeyboardSettings.showFunctionRow

                ThorchKey {
                    key: Qt.Key_Escape
                    displayText: "Esc"
                    functionKey: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_F1
                    displayText: "F1"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F2
                    displayText: "F2"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F3
                    displayText: "F3"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F4
                    displayText: "F4"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F5
                    displayText: "F5"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F6
                    displayText: "F6"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F7
                    displayText: "F7"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F8
                    displayText: "F8"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F9
                    displayText: "F9"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F10
                    displayText: "F10"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F11
                    displayText: "F11"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_F12
                    displayText: "F12"
                    functionKey: true
                }
            }

            KeyboardRow {
                objectName: "thorchNumberRow"
                visible: PlasmaKeyboardSettings.showNumberRow

                ThorchKey {
                    key: Qt.Key_QuoteLeft
                    baseText: "\`"
                    shiftText: "~"
                }
                ThorchKey {
                    objectName: "thorchNumberOneKey"
                    key: Qt.Key_1
                    baseText: "1"
                    shiftText: "!"
                }
                ThorchKey {
                    key: Qt.Key_2
                    baseText: "2"
                    shiftText: "@"
                }
                ThorchKey {
                    key: Qt.Key_3
                    baseText: "3"
                    shiftText: "#"
                }
                ThorchKey {
                    key: Qt.Key_4
                    baseText: "4"
                    shiftText: "$"
                }
                ThorchKey {
                    key: Qt.Key_5
                    baseText: "5"
                    shiftText: "%"
                }
                ThorchKey {
                    key: Qt.Key_6
                    baseText: "6"
                    shiftText: "^"
                }
                ThorchKey {
                    key: Qt.Key_7
                    baseText: "7"
                    shiftText: "&"
                }
                ThorchKey {
                    key: Qt.Key_8
                    baseText: "8"
                    shiftText: "*"
                }
                ThorchKey {
                    key: Qt.Key_9
                    baseText: "9"
                    shiftText: "("
                }
                ThorchKey {
                    objectName: "thorchNumberZeroKey"
                    key: Qt.Key_0
                    baseText: "0"
                    shiftText: ")"
                }
            }

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_Q
                    baseText: "q"
                }
                ThorchKey {
                    key: Qt.Key_W
                    baseText: "w"
                }
                ThorchKey {
                    key: Qt.Key_E
                    baseText: "e"
                    alternativeKeys: "éèêëe"
                }
                ThorchKey {
                    key: Qt.Key_R
                    baseText: "r"
                }
                ThorchKey {
                    key: Qt.Key_T
                    baseText: "t"
                }
                ThorchKey {
                    key: Qt.Key_Y
                    baseText: "y"
                    alternativeKeys: "ýÿy"
                }
                ThorchKey {
                    key: Qt.Key_U
                    baseText: "u"
                    alternativeKeys: "úùûüu"
                }
                ThorchKey {
                    key: Qt.Key_I
                    baseText: "i"
                    alternativeKeys: "íìîïi"
                }
                ThorchKey {
                    objectName: "thorchLetterOKey"
                    key: Qt.Key_O
                    baseText: "o"
                    alternativeKeys: "óòôöõøo"
                }
                ThorchKey {
                    objectName: "thorchLetterPKey"
                    key: Qt.Key_P
                    baseText: "p"
                }
            }

            KeyboardRow {
                ThorchKey {
                    objectName: "thorchTabKey"
                    key: Qt.Key_Tab
                    displayText: "Tab"
                    functionKey: true
                    weight: 10
                }
                ThorchKey {
                    objectName: "thorchLetterAKey"
                    key: Qt.Key_A
                    baseText: "a"
                    alternativeKeys: "áàâäãåa"
                }
                ThorchKey {
                    key: Qt.Key_S
                    baseText: "s"
                }
                ThorchKey {
                    key: Qt.Key_D
                    baseText: "d"
                }
                ThorchKey {
                    key: Qt.Key_F
                    baseText: "f"
                }
                ThorchKey {
                    key: Qt.Key_G
                    baseText: "g"
                }
                ThorchKey {
                    key: Qt.Key_H
                    baseText: "h"
                }
                ThorchKey {
                    key: Qt.Key_J
                    baseText: "j"
                }
                ThorchKey {
                    key: Qt.Key_K
                    baseText: "k"
                }
                ThorchKey {
                    objectName: "thorchLetterLKey"
                    key: Qt.Key_L
                    baseText: "l"
                }
                FillerKey {
                    weight: 5
                }
            }

            KeyboardRow {
                ThorchShiftKey {
                    objectName: "thorchShiftModifierKey"
                    weight: 14
                }
                ThorchKey {
                    objectName: "thorchLetterZKey"
                    key: Qt.Key_Z
                    baseText: "z"
                }
                ThorchKey {
                    key: Qt.Key_X
                    baseText: "x"
                }
                ThorchKey {
                    objectName: "thorchLetterCKey"
                    key: Qt.Key_C
                    baseText: "c"
                    alternativeKeys: "çc"
                }
                ThorchKey {
                    objectName: "thorchLetterVKey"
                    key: Qt.Key_V
                    baseText: "v"
                }
                ThorchKey {
                    key: Qt.Key_B
                    baseText: "b"
                }
                ThorchKey {
                    key: Qt.Key_N
                    baseText: "n"
                    alternativeKeys: "ñńn"
                }
                ThorchKey {
                    objectName: "thorchLetterMKey"
                    key: Qt.Key_M
                    baseText: "m"
                }
                ThorchKey {
                    objectName: "thorchMainBackspaceKey"
                    key: Qt.Key_Backspace
                    displayText: "⌫"
                    functionKey: true
                    repeat: true
                    weight: 16
                    thorchAccent: 2
                }
            }

            KeyboardRow {
                ThorchPageKey {
                    objectName: "thorchSymbolsPageKey"
                    targetPage: "symbols"
                    weight: 18
                }
                ThorchKey {
                    objectName: "thorchSpaceKey"
                    key: Qt.Key_Space
                    baseText: " "
                    displayText: "Space"
                    repeat: true
                    weight: 62
                }
                ThorchKey {
                    objectName: "thorchEnterKey"
                    key: Qt.Key_Return
                    displayText: "Enter"
                    functionKey: true
                    weight: 20
                    thorchAccent: 2
                }
            }

            ThorchUtilityRow {
            }
        }

        KeyboardLayout {
            id: symbolsLayout
            objectName: "thorchSymbolsLayout"
            inputMode: InputEngine.InputMode.Latin
            keyWeight: 10

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_1
                    baseText: "1"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_2
                    baseText: "2"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_3
                    baseText: "3"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_4
                    baseText: "4"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_5
                    baseText: "5"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_6
                    baseText: "6"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_7
                    baseText: "7"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_8
                    baseText: "8"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_9
                    baseText: "9"
                    noModifier: true
                }
                ThorchKey {
                    objectName: "thorchSymbolsZeroKey"
                    key: Qt.Key_0
                    baseText: "0"
                    noModifier: true
                }
            }

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_Minus
                    baseText: "-"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Slash
                    baseText: "/"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Colon
                    baseText: ":"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Semicolon
                    baseText: ";"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_ParenLeft
                    baseText: "("
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_ParenRight
                    baseText: ")"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Dollar
                    baseText: "$"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Ampersand
                    baseText: "&"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_At
                    baseText: "@"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_QuoteDbl
                    baseText: "\""
                    noModifier: true
                }
            }

            KeyboardRow {
                ThorchPageKey {
                    objectName: "thorchSymbolsMorePageKey"
                    targetPage: "symbolsMore"
                    weight: 18
                }
                ThorchKey {
                    key: Qt.Key_Period
                    baseText: "."
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Comma
                    baseText: ","
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Question
                    baseText: "?"
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Exclam
                    baseText: "!"
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Apostrophe
                    baseText: "'"
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    objectName: "thorchSymbolsBackspaceKey"
                    key: Qt.Key_Backspace
                    displayText: "⌫"
                    functionKey: true
                    repeat: true
                    weight: 22
                    thorchAccent: 2
                }
            }

            KeyboardRow {
                ThorchPageKey {
                    objectName: "thorchSymbolsMainPageKey"
                    targetPage: "main"
                    weight: 18
                }
                ThorchKey {
                    key: Qt.Key_Space
                    baseText: " "
                    displayText: "Space"
                    repeat: true
                    weight: 62
                }
                ThorchKey {
                    key: Qt.Key_Return
                    displayText: "Enter"
                    functionKey: true
                    weight: 20
                    thorchAccent: 2
                }
            }

            ThorchUtilityRow {
            }
        }

        KeyboardLayout {
            id: symbolsMoreLayout
            objectName: "thorchSymbolsMoreLayout"
            inputMode: InputEngine.InputMode.Latin
            keyWeight: 10

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_BracketLeft
                    baseText: "["
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_BracketRight
                    baseText: "]"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_BraceLeft
                    baseText: "{"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_BraceRight
                    baseText: "}"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_NumberSign
                    baseText: "#"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Percent
                    baseText: "%"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_AsciiCircum
                    baseText: "^"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Asterisk
                    baseText: "*"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Plus
                    baseText: "+"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Equal
                    baseText: "="
                    noModifier: true
                }
            }

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_Underscore
                    baseText: "_"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Backslash
                    baseText: "\\"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Bar
                    baseText: "|"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_AsciiTilde
                    baseText: "~"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Less
                    baseText: "<"
                    noModifier: true
                }
                ThorchKey {
                    key: Qt.Key_Greater
                    baseText: ">"
                    noModifier: true
                }
                ThorchKey {
                    key: 0x00a3
                    baseText: "£"
                    noModifier: true
                }
                ThorchKey {
                    key: 0x20ac
                    baseText: "€"
                    noModifier: true
                }
                ThorchKey {
                    key: 0x00a5
                    baseText: "¥"
                    noModifier: true
                }
                ThorchKey {
                    key: 0x2022
                    baseText: "•"
                    noModifier: true
                }
            }

            KeyboardRow {
                ThorchPageKey {
                    objectName: "thorchSymbolsMoreBackKey"
                    targetPage: "symbols"
                    weight: 18
                }
                ThorchKey {
                    key: Qt.Key_Period
                    baseText: "."
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Comma
                    baseText: ","
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Question
                    baseText: "?"
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Exclam
                    baseText: "!"
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Apostrophe
                    baseText: "'"
                    noModifier: true
                    weight: 12
                }
                ThorchKey {
                    objectName: "thorchSymbolsMoreBackspaceKey"
                    key: Qt.Key_Backspace
                    displayText: "⌫"
                    functionKey: true
                    repeat: true
                    weight: 22
                    thorchAccent: 2
                }
            }

            KeyboardRow {
                ThorchPageKey {
                    objectName: "thorchSymbolsMoreMainPageKey"
                    targetPage: "main"
                    weight: 18
                }
                ThorchKey {
                    key: Qt.Key_Space
                    baseText: " "
                    displayText: "Space"
                    repeat: true
                    weight: 62
                }
                ThorchKey {
                    key: Qt.Key_Return
                    displayText: "Enter"
                    functionKey: true
                    weight: 20
                    thorchAccent: 2
                }
            }

            ThorchUtilityRow {
            }
        }

        KeyboardLayout {
            id: navigationLayout
            objectName: "thorchNavigationLayout"
            inputMode: InputEngine.InputMode.Latin
            keyWeight: 14

            KeyboardRow {
                ThorchPageKey {
                    objectName: "thorchMainPageKey"
                    targetPage: "main"
                    weight: 16
                }
                ThorchKey {
                    objectName: "thorchNavigationEscapeKey"
                    key: Qt.Key_Escape
                    displayText: "Esc"
                    functionKey: true
                    weight: 12
                }
                ThorchKey {
                    key: Qt.Key_Print
                    displayText: "Print"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_ScrollLock
                    displayText: "Scroll"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_Pause
                    displayText: "Pause"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_NumLock
                    displayText: "Num"
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_Slash
                    displayText: "/"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                    weight: 10
                }
                ThorchKey {
                    key: Qt.Key_Asterisk
                    displayText: "*"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                    weight: 10
                }
                ThorchKey {
                    key: Qt.Key_Minus
                    displayText: "-"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                    weight: 10
                }
            }

            KeyboardRow {
                objectName: "thorchNavigationFunctionRow"

                ThorchKey { key: Qt.Key_F1; displayText: "F1"; functionKey: true }
                ThorchKey { key: Qt.Key_F2; displayText: "F2"; functionKey: true }
                ThorchKey { key: Qt.Key_F3; displayText: "F3"; functionKey: true }
                ThorchKey { key: Qt.Key_F4; displayText: "F4"; functionKey: true }
                ThorchKey { key: Qt.Key_F5; displayText: "F5"; functionKey: true }
                ThorchKey { key: Qt.Key_F6; displayText: "F6"; functionKey: true }
                ThorchKey { key: Qt.Key_F7; displayText: "F7"; functionKey: true }
                ThorchKey { key: Qt.Key_F8; displayText: "F8"; functionKey: true }
                ThorchKey { key: Qt.Key_F9; displayText: "F9"; functionKey: true }
                ThorchKey { key: Qt.Key_F10; displayText: "F10"; functionKey: true }
                ThorchKey { key: Qt.Key_F11; displayText: "F11"; functionKey: true }
                ThorchKey {
                    objectName: "thorchNavigationF12Key"
                    key: Qt.Key_F12
                    displayText: "F12"
                    functionKey: true
                }
            }

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_Insert
                    displayText: "Insert"
                    functionKey: true
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_Home
                    displayText: "Home"
                    functionKey: true
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_PageUp
                    displayText: "PgUp"
                    functionKey: true
                    weight: 16
                }
                FillerKey {
                    weight: 8
                }
                ThorchKey {
                    objectName: "thorchKeypadSevenKey"
                    key: Qt.Key_7
                    displayText: "7"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_8
                    displayText: "8"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_9
                    displayText: "9"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_Plus
                    displayText: "+"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                    thorchAccent: 2
                }
            }

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_Delete
                    displayText: "Delete"
                    functionKey: true
                    repeat: true
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_End
                    displayText: "End"
                    functionKey: true
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_PageDown
                    displayText: "PgDn"
                    functionKey: true
                    weight: 16
                }
                FillerKey {
                    weight: 8
                }
                ThorchKey {
                    key: Qt.Key_4
                    displayText: "4"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_5
                    displayText: "5"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_6
                    displayText: "6"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_Plus
                    displayText: "+"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                    thorchAccent: 2
                }
            }

            KeyboardRow {
                FillerKey {
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_Up
                    displayText: "↑"
                    functionKey: true
                    repeat: true
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_Menu
                    displayText: "Menu"
                    functionKey: true
                    weight: 16
                }
                FillerKey {
                    weight: 8
                }
                ThorchKey {
                    key: Qt.Key_1
                    displayText: "1"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_2
                    displayText: "2"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_3
                    displayText: "3"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_Enter
                    displayText: "Enter"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                    thorchAccent: 2
                }
            }

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_Left
                    displayText: "←"
                    functionKey: true
                    repeat: true
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_Down
                    displayText: "↓"
                    functionKey: true
                    repeat: true
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_Right
                    displayText: "→"
                    functionKey: true
                    repeat: true
                    weight: 16
                }
                FillerKey {
                    weight: 8
                }
                ThorchKey {
                    key: Qt.Key_0
                    displayText: "0"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                    weight: 28
                }
                ThorchKey {
                    key: Qt.Key_Period
                    displayText: "."
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                }
                ThorchKey {
                    key: Qt.Key_Enter
                    displayText: "Enter"
                    fixedModifiers: Qt.KeypadModifier
                    functionKey: true
                    thorchAccent: 2
                }
            }

            ThorchUtilityRow {
            }
        }

    }
}
