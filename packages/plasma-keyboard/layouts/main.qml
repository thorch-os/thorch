// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

KeyboardLayoutLoader {
    id: layoutLoader
    objectName: "thorchKeyboardLayout"

    property bool thorchNavigationPage: false
    property int thorchStickyModifiers: Qt.NoModifier

    sourceComponent: thorchNavigationPage ? navigationLayout : mainLayout

    function toggleThorchModifier(modifier) {
        thorchStickyModifiers ^= modifier;
        modifierTimeout.restart();
    }

    function consumeThorchModifiers() {
        thorchStickyModifiers = Qt.NoModifier;
        modifierTimeout.stop();
    }

    onVisibleChanged: {
        if (!visible) {
            thorchNavigationPage = false;
            consumeThorchModifiers();
        }
    }

    Timer {
        id: modifierTimeout
        interval: 8000
        onTriggered: layoutLoader.thorchStickyModifiers = Qt.NoModifier
    }

    Component {
        id: mainLayout

        KeyboardLayout {
            inputMode: InputEngine.InputMode.Latin
            keyWeight: 10

            KeyboardRow {
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
                ThorchKey {
                    key: Qt.Key_QuoteLeft
                    baseText: "`"
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
                    key: Qt.Key_0
                    baseText: "0"
                    shiftText: ")"
                }
                ThorchKey {
                    key: Qt.Key_Minus
                    baseText: "-"
                    shiftText: "_"
                }
                ThorchKey {
                    key: Qt.Key_Equal
                    baseText: "="
                    shiftText: "+"
                }
                ThorchKey {
                    key: Qt.Key_Backspace
                    displayText: "Back"
                    functionKey: true
                    repeat: true
                    weight: 18
                    thorchAccent: 2
                }
            }

            KeyboardRow {
                ThorchKey {
                    key: Qt.Key_Tab
                    displayText: "Tab"
                    functionKey: true
                    weight: 15
                }
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
                }
                ThorchKey {
                    key: Qt.Key_U
                    baseText: "u"
                }
                ThorchKey {
                    key: Qt.Key_I
                    baseText: "i"
                }
                ThorchKey {
                    key: Qt.Key_O
                    baseText: "o"
                }
                ThorchKey {
                    key: Qt.Key_P
                    baseText: "p"
                }
                ThorchKey {
                    key: Qt.Key_BracketLeft
                    baseText: "["
                    shiftText: "{"
                }
                ThorchKey {
                    key: Qt.Key_BracketRight
                    baseText: "]"
                    shiftText: "}"
                }
                ThorchKey {
                    key: Qt.Key_Backslash
                    baseText: "\\"
                    shiftText: "|"
                    weight: 12
                }
            }

            KeyboardRow {
                ThorchCapsLockKey {
                    weight: 18
                }
                ThorchKey {
                    key: Qt.Key_A
                    baseText: "a"
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
                    key: Qt.Key_L
                    baseText: "l"
                }
                ThorchKey {
                    key: Qt.Key_Semicolon
                    baseText: ";"
                    shiftText: ":"
                }
                ThorchKey {
                    key: Qt.Key_Apostrophe
                    baseText: "'"
                    shiftText: "\""
                }
                ThorchKey {
                    key: Qt.Key_Return
                    displayText: "Enter"
                    functionKey: true
                    weight: 20
                    thorchAccent: 2
                }
            }

            KeyboardRow {
                ThorchShiftKey {
                    objectName: "thorchShiftModifierKey"
                    weight: 22
                }
                ThorchKey {
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
                }
                ThorchKey {
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
                }
                ThorchKey {
                    key: Qt.Key_M
                    baseText: "m"
                }
                ThorchKey {
                    key: Qt.Key_Comma
                    baseText: ","
                    shiftText: "<"
                }
                ThorchKey {
                    key: Qt.Key_Period
                    baseText: "."
                    shiftText: ">"
                }
                ThorchKey {
                    key: Qt.Key_Slash
                    baseText: "/"
                    shiftText: "?"
                }
                ThorchShiftKey {
                    weight: 22
                }
            }

            KeyboardRow {
                ThorchModifierKey {
                    objectName: "thorchControlModifierKey"
                    modifier: Qt.ControlModifier
                    displayText: "Ctrl"
                    weight: 16
                }
                ThorchModifierKey {
                    modifier: Qt.MetaModifier
                    displayText: "Super"
                    weight: 15
                }
                ThorchModifierKey {
                    modifier: Qt.AltModifier
                    displayText: "Alt"
                    weight: 14
                }
                ThorchPageKey {
                    objectName: "thorchNavigationPageKey"
                    showNavigationPage: true
                    weight: 16
                }
                ThorchKey {
                    key: Qt.Key_Space
                    baseText: " "
                    displayText: ""
                    weight: 60
                }
                ThorchModifierKey {
                    modifier: Qt.AltModifier
                    displayText: "Alt"
                    weight: 14
                }
                ThorchModifierKey {
                    modifier: Qt.ControlModifier
                    displayText: "Ctrl"
                    weight: 16
                }
                ThorchSettingsKey {
                    weight: 18
                }
                ThorchHideKey {
                    weight: 14
                }
            }
        }
    }

    Component {
        id: navigationLayout

        KeyboardLayout {
            inputMode: InputEngine.InputMode.Latin
            keyWeight: 14

            KeyboardRow {
                ThorchPageKey {
                    objectName: "thorchMainPageKey"
                    showNavigationPage: false
                    weight: 16
                }
                ThorchKey {
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

            KeyboardRow {
                ThorchModifierKey {
                    modifier: Qt.ControlModifier
                    displayText: "Ctrl"
                    weight: 16
                }
                ThorchModifierKey {
                    modifier: Qt.MetaModifier
                    displayText: "Super"
                    weight: 15
                }
                ThorchModifierKey {
                    modifier: Qt.AltModifier
                    displayText: "Alt"
                    weight: 14
                }
                ThorchKey {
                    key: Qt.Key_Space
                    baseText: " "
                    displayText: ""
                    weight: 60
                }
                ThorchModifierKey {
                    modifier: Qt.AltModifier
                    displayText: "Alt"
                    weight: 14
                }
                ThorchModifierKey {
                    modifier: Qt.ControlModifier
                    displayText: "Ctrl"
                    weight: 16
                }
                ThorchSettingsKey {
                    weight: 18
                }
                ThorchHideKey {
                    weight: 14
                }
            }
        }
    }
}
