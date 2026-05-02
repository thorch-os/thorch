/*
 *   SPDX-FileCopyrightText: 2012-2013 Daniel Nicoletti <dantti12@gmail.com>
 *   SPDX-FileCopyrightText: 2013, 2015 Kai Uwe Broulik <kde@privat.broulik.de>
 *   SPDX-FileCopyrightText: 2021 Devin Lin <devin@kde.org>
 *
 *   SPDX-License-Identifier: LGPL-2.0-or-later
 */

import QtQuick 2.15
import QtQuick.Layouts 1.1
import org.kde.kirigami as Kirigami

import org.kde.plasma.components 3.0 as PC3
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.private.mobileshell as MobileShell

Item {
    id: root

    implicitHeight: brightnessColumn.implicitHeight
    visible: bottomMax > 0 || topMax > 0

    property int bottomBrightness: 1
    property int bottomMax: 0
    property int topBrightness: 1
    property int topMax: 0
    property double brightnessPressedValue: 1

    function parseStatus(output) {
        const lines = output.trim().split("\n");
        for (let i = 0; i < lines.length; i++) {
            const parts = lines[i].trim().split(/\s+/);
            if (parts.length < 3) {
                continue;
            }
            const value = parseInt(parts[1]);
            const max = parseInt(parts[2]);
            if (parts[0] === "bottom") {
                bottomBrightness = value;
                bottomMax = max;
            } else if (parts[0] === "top") {
                topBrightness = value;
                topMax = max;
            }
        }
    }

    function run(command) {
        backlightSource.connectSource(command);
    }

    function setBrightness(name, value) {
        run("/usr/bin/thorch-backlight set " + name + " " + Math.round(value));
    }

    Behavior on brightnessPressedValue {
        NumberAnimation {
            duration: Kirigami.Units.longDuration * 2
            easing.type: Easing.InOutQuad
        }
    }

    Plasma5Support.DataSource {
        id: backlightSource
        engine: "executable"

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName);
            if (sourceName === "/usr/bin/thorch-backlight status" && data.stdout !== undefined) {
                root.parseStatus(data.stdout);
            }
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.run("/usr/bin/thorch-backlight status")
    }

    MobileShell.PanelBackground {
        anchors.fill: parent
        anchors.leftMargin: -Kirigami.Units.smallSpacing
        anchors.rightMargin: -Kirigami.Units.smallSpacing
        anchors.topMargin: -Kirigami.Units.smallSpacing * 2
        anchors.bottomMargin: -Kirigami.Units.smallSpacing * 2

        panelType: MobileShell.PanelBackground.PanelType.Base
        flatten: root.brightnessPressedValue

        Kirigami.Theme.inherit: false
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
    }

    ColumnLayout {
        id: brightnessColumn
        spacing: Kirigami.Units.smallSpacing

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top

        BrightnessSlider {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            label: i18n("Top")
            maximum: root.topMax
            currentValue: root.topBrightness
            visible: maximum > 0
            onMovedValue: value => root.setBrightness("top", value)
            onPressedChangedValue: pressed => {
                if (pressed) {
                    brightnessPressedTimer.restart();
                } else {
                    brightnessPressedTimer.stop();
                    root.brightnessPressedValue = 1;
                }
            }
        }

        BrightnessSlider {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            label: i18n("Bottom")
            maximum: root.bottomMax
            currentValue: root.bottomBrightness
            visible: maximum > 0
            onMovedValue: value => root.setBrightness("bottom", value)
            onPressedChangedValue: pressed => {
                if (pressed) {
                    brightnessPressedTimer.restart();
                } else {
                    brightnessPressedTimer.stop();
                    root.brightnessPressedValue = 1;
                }
            }
        }
    }

    Timer {
        id: brightnessPressedTimer
        interval: 100
        repeat: false
        onTriggered: root.brightnessPressedValue = 0
    }

    component BrightnessSlider: RowLayout {
        id: sliderRow

        property string label
        property int maximum
        property int currentValue
        signal movedValue(real value)
        signal pressedChangedValue(bool pressed)

        spacing: Kirigami.Units.smallSpacing
        implicitHeight: Kirigami.Units.gridUnit * 2.5

        PC3.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
            Layout.alignment: Qt.AlignVCenter
            text: sliderRow.label
            elide: Text.ElideRight
        }

        PC3.Slider {
            id: slider
            Layout.minimumHeight: Kirigami.Units.gridUnit * 2.5
            Layout.fillWidth: true
            from: 1
            to: Math.max(1, sliderRow.maximum)
            value: sliderRow.currentValue
            onMoved: sliderRow.movedValue(value)
            onPressedChanged: sliderRow.pressedChangedValue(pressed)
        }

        PC3.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 2
            Layout.alignment: Qt.AlignVCenter
            horizontalAlignment: Text.AlignRight
            text: sliderRow.maximum > 0 ? Math.round(slider.value * 100 / sliderRow.maximum) + "%" : ""
        }
    }
}
