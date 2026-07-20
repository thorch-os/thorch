// SPDX-FileCopyrightText: 2026 Thorch contributors
// SPDX-License-Identifier: GPL-2.0-or-later

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.private.mobileshell as MobileShell

Item {
    id: root

    property bool panelBackground: true
    property int topBrightness: 1
    property int topMaximum: 0
    property int bottomBrightness: 1
    property int bottomMaximum: 0
    property real brightnessPressedValue: 1
    property string lastError: ""

    property bool statusBusy: false
    property string statusCommand: "/usr/bin/thorch-backlight status"
    property int topRequested: 1
    property int topSent: 1
    property bool topWriteBusy: false
    property string topWriteCommand: ""
    property int bottomRequested: 1
    property int bottomSent: 1
    property bool bottomWriteBusy: false
    property string bottomWriteCommand: ""

    readonly property bool userInteracting: topControl.pressed || bottomControl.pressed
    readonly property bool writeBusy: topWriteBusy || bottomWriteBusy

    implicitHeight: brightnessColumn.implicitHeight
    visible: topMaximum > 0 || bottomMaximum > 0

    function bounded(value, maximum) {
        return Math.max(1, Math.min(maximum, Math.round(value)));
    }

    function parseStatus(output) {
        const lines = String(output).trim().split("\n");
        for (let index = 0; index < lines.length; ++index) {
            const parts = lines[index].trim().split(/\s+/);
            if (parts.length < 3) {
                continue;
            }

            const value = Number.parseInt(parts[1], 10);
            const maximum = Number.parseInt(parts[2], 10);
            if (!Number.isFinite(value) || !Number.isFinite(maximum) || maximum < 1) {
                continue;
            }

            if (parts[0] === "top") {
                topMaximum = maximum;
                topBrightness = bounded(value, maximum);
                if (!topControl.pressed && !topWriteBusy) {
                    topRequested = topBrightness;
                }
            } else if (parts[0] === "bottom") {
                bottomMaximum = maximum;
                bottomBrightness = bounded(value, maximum);
                if (!bottomControl.pressed && !bottomWriteBusy) {
                    bottomRequested = bottomBrightness;
                }
            }
        }
    }

    function requestStatus() {
        if (statusBusy || userInteracting || writeBusy) {
            return;
        }
        statusBusy = true;
        statusTimeout.restart();
        statusSource.connectSource(statusCommand);
    }

    function queueBrightness(name, value) {
        lastError = "";
        if (name === "top" && topMaximum > 0) {
            topRequested = bounded(value, topMaximum);
            topBrightness = topRequested;
            topWriteDelay.restart();
        } else if (name === "bottom" && bottomMaximum > 0) {
            bottomRequested = bounded(value, bottomMaximum);
            bottomBrightness = bottomRequested;
            bottomWriteDelay.restart();
        }
    }

    function startTopWrite() {
        if (topWriteBusy || topMaximum < 1) {
            return;
        }
        topSent = topRequested;
        topWriteCommand = "/usr/bin/thorch-backlight set top " + topSent;
        topWriteBusy = true;
        topWriteTimeout.restart();
        topWriteSource.connectSource(topWriteCommand);
    }

    function finishTopWrite(sourceName, succeeded) {
        topWriteSource.disconnectSource(sourceName);
        topWriteTimeout.stop();
        topWriteBusy = false;
        if (!succeeded) {
            lastError = qsTr("Could not set top-screen brightness");
        }
        if (topRequested !== topSent) {
            topWriteDelay.restart();
        } else {
            refreshAfterWrite.restart();
        }
    }

    function startBottomWrite() {
        if (bottomWriteBusy || bottomMaximum < 1) {
            return;
        }
        bottomSent = bottomRequested;
        bottomWriteCommand = "/usr/bin/thorch-backlight set bottom " + bottomSent;
        bottomWriteBusy = true;
        bottomWriteTimeout.restart();
        bottomWriteSource.connectSource(bottomWriteCommand);
    }

    function finishBottomWrite(sourceName, succeeded) {
        bottomWriteSource.disconnectSource(sourceName);
        bottomWriteTimeout.stop();
        bottomWriteBusy = false;
        if (!succeeded) {
            lastError = qsTr("Could not set bottom-screen brightness");
        }
        if (bottomRequested !== bottomSent) {
            bottomWriteDelay.restart();
        } else {
            refreshAfterWrite.restart();
        }
    }

    Behavior on brightnessPressedValue {
        NumberAnimation {
            duration: Kirigami.Units.longDuration * 2
            easing.type: Easing.InOutQuad
        }
    }

    Plasma5Support.DataSource {
        id: statusSource
        engine: "executable"
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
            if (sourceName !== root.statusCommand) {
                return;
            }
            statusTimeout.stop();
            root.statusBusy = false;
            const exitCode = data["exit code"] === undefined ? 0 : Number(data["exit code"]);
            if (exitCode === 0 && data.stdout !== undefined) {
                root.parseStatus(data.stdout);
                root.lastError = "";
            } else {
                root.lastError = qsTr("Brightness status is unavailable");
            }
        }
    }

    Plasma5Support.DataSource {
        id: topWriteSource
        engine: "executable"
        onNewData: (sourceName, data) => {
            const exitCode = data["exit code"] === undefined ? 0 : Number(data["exit code"]);
            root.finishTopWrite(sourceName, exitCode === 0);
        }
    }

    Plasma5Support.DataSource {
        id: bottomWriteSource
        engine: "executable"
        onNewData: (sourceName, data) => {
            const exitCode = data["exit code"] === undefined ? 0 : Number(data["exit code"]);
            root.finishBottomWrite(sourceName, exitCode === 0);
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.requestStatus()
    }

    Timer {
        id: statusTimeout
        interval: 2500
        onTriggered: {
            statusSource.disconnectSource(root.statusCommand);
            root.statusBusy = false;
            root.lastError = qsTr("Brightness status timed out");
        }
    }

    Timer {
        id: topWriteDelay
        interval: 70
        onTriggered: root.startTopWrite()
    }

    Timer {
        id: bottomWriteDelay
        interval: 70
        onTriggered: root.startBottomWrite()
    }

    Timer {
        id: topWriteTimeout
        interval: 2500
        onTriggered: root.finishTopWrite(root.topWriteCommand, false)
    }

    Timer {
        id: bottomWriteTimeout
        interval: 2500
        onTriggered: root.finishBottomWrite(root.bottomWriteCommand, false)
    }

    Timer {
        id: refreshAfterWrite
        interval: 150
        onTriggered: root.requestStatus()
    }

    Timer {
        id: brightnessPressedTimer
        interval: 100
        onTriggered: root.brightnessPressedValue = 0
    }

    MobileShell.PanelBackground {
        anchors.fill: parent
        anchors.leftMargin: -Kirigami.Units.smallSpacing
        anchors.rightMargin: -Kirigami.Units.smallSpacing
        anchors.topMargin: -Kirigami.Units.smallSpacing * 2
        anchors.bottomMargin: -Kirigami.Units.smallSpacing * 2
        visible: root.panelBackground
        panelType: MobileShell.PanelBackground.PanelType.Base
        flatten: root.brightnessPressedValue
        Kirigami.Theme.inherit: false
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
    }

    ColumnLayout {
        id: brightnessColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Kirigami.Units.smallSpacing

        BrightnessSlider {
            id: topControl
            Layout.fillWidth: true
            label: qsTr("Top")
            maximum: root.topMaximum
            currentValue: root.topBrightness
            visible: maximum > 0
            onMovedValue: value => root.queueBrightness("top", value)
            onPressedChangedValue: pressed => {
                if (pressed) {
                    brightnessPressedTimer.restart();
                } else {
                    brightnessPressedTimer.stop();
                    root.brightnessPressedValue = 1;
                    root.queueBrightness("top", sliderValue);
                }
            }
        }

        BrightnessSlider {
            id: bottomControl
            Layout.fillWidth: true
            label: qsTr("Bottom")
            maximum: root.bottomMaximum
            currentValue: root.bottomBrightness
            visible: maximum > 0
            onMovedValue: value => root.queueBrightness("bottom", value)
            onPressedChangedValue: pressed => {
                if (pressed) {
                    brightnessPressedTimer.restart();
                } else {
                    brightnessPressedTimer.stop();
                    root.brightnessPressedValue = 1;
                    root.queueBrightness("bottom", sliderValue);
                }
            }
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            visible: root.lastError.length > 0
            text: root.lastError
            color: Kirigami.Theme.negativeTextColor
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }

    component BrightnessSlider: RowLayout {
        id: sliderRow

        property string label
        property int maximum
        property int currentValue
        readonly property bool pressed: slider.pressed
        readonly property real sliderValue: slider.value
        signal movedValue(real value)
        signal pressedChangedValue(bool pressed)

        spacing: Kirigami.Units.smallSpacing
        implicitHeight: Kirigami.Units.gridUnit * 2.4

        PlasmaComponents.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
            Layout.alignment: Qt.AlignVCenter
            text: sliderRow.label
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }

        PlasmaComponents.Slider {
            id: slider
            Layout.fillWidth: true
            Layout.minimumHeight: Kirigami.Units.gridUnit * 2.4
            from: 1
            to: Math.max(1, sliderRow.maximum)
            onMoved: sliderRow.movedValue(value)
            onPressedChanged: sliderRow.pressedChangedValue(pressed)

            Binding {
                target: slider
                property: "value"
                value: sliderRow.currentValue
                when: !slider.pressed
                restoreMode: Binding.RestoreNone
            }
        }

        PlasmaComponents.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 2.5
            Layout.alignment: Qt.AlignVCenter
            horizontalAlignment: Text.AlignRight
            text: sliderRow.maximum > 0
                ? Math.round(slider.value * 100 / sliderRow.maximum) + "%"
                : ""
        }
    }
}
