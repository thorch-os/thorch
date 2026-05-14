import QtQuick
import org.kde.kirigami as Kirigami

import "pages"

Kirigami.ApplicationWindow {
    id: root

    width: Kirigami.Units.gridUnit * 42
    height: Kirigami.Units.gridUnit * 50
    minimumWidth: Kirigami.Units.gridUnit * 26
    minimumHeight: Kirigami.Units.gridUnit * 34
    visible: true
    title: qsTr("Thorch Hardware")

    readonly property int quitAfterMs: {
        for (let i = 0; i < Qt.application.arguments.length; ++i) {
            const argument = Qt.application.arguments[i]
            if (argument.indexOf("--quit-after-ms=") === 0) {
                return Number(argument.slice("--quit-after-ms=".length))
            }
        }
        return 0
    }

    pageStack.initialPage: HardwarePage {}

    Timer {
        interval: root.quitAfterMs
        repeat: false
        running: root.quitAfterMs > 0
        onTriggered: Qt.quit()
    }
}
