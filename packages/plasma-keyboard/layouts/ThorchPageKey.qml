// SPDX-License-Identifier: GPL-3.0-only

import QtQuick
import QtQuick.VirtualKeyboard.Components

Key {
    required property bool showNavigationPage
    property int thorchAccent: 1

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

    displayText: showNavigationPage ? "Nav" : "ABC"
    noKeyEvent: true
    functionKey: true

    onClicked: {
        if (pageController) {
            pageController.thorchNavigationPage = showNavigationPage;
        }
    }
}
