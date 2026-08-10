// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard.Components

Key {
    required property string targetPage

    readonly property var pageController: {
        let item = parent;
        while (item) {
            if (item.thorchNavigationPage !== undefined) {
                return item;
            }
            item = item.parent;
        }
        return null;
    }

    property int thorchAccent: pageController && pageController.thorchPage === targetPage ? 2 : 1

    displayText: {
        switch (targetPage) {
        case "main":
            return "ABC";
        case "symbols":
            return "123";
        case "symbolsMore":
            return "#+=";
        case "navigation":
            return "Nav";
        default:
            return "Thorch";
        }
    }
    noKeyEvent: true
    functionKey: true

    onClicked: {
        if (pageController) {
            pageController.showThorchPage(targetPage);
        }
    }
}
