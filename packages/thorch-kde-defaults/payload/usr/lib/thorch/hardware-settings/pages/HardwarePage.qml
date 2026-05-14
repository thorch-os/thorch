import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support 2.0 as P5Support

import "../components" as Components

Kirigami.ScrollablePage {
    id: page

    title: qsTr("Thor Hardware")

    property bool loading: true
    property bool actionRunning: false
    property bool preservePendingOnRefresh: false
    property string actionError: ""
    property string statusError: ""
    property string pendingAction: ""

    property string cpuBoost: "1"
    property string fanProfile: "moderate"
    property string fanSensorMode: "max"
    property string rgbMode: "battery"
    property int rgbBrightness: 255
    property int rgbStaticR: 0
    property int rgbStaticG: 128
    property int rgbStaticB: 255

    property string pendingCpuBoost: "1"
    property string pendingFanProfile: "moderate"
    property string pendingFanSensorMode: "max"
    property string pendingRgbMode: "battery"
    property int pendingRgbBrightness: 255
    property int pendingRgbStaticR: 0
    property int pendingRgbStaticG: 128
    property int pendingRgbStaticB: 255

    readonly property string controlCommand: "thorch-hardwarectl"
    readonly property string statusCommand: controlCommand + " status-json"
    readonly property string normalizedFanProfile: fanProfile === "auto" ? "moderate" : fanProfile
    readonly property bool cpuDirty: pendingCpuBoost !== cpuBoost
    readonly property bool coolingDirty: pendingFanProfile !== normalizedFanProfile || pendingFanSensorMode !== fanSensorMode
    readonly property bool lightingDirty: pendingRgbMode !== rgbMode
                                         || pendingRgbBrightness !== rgbBrightness
                                         || pendingRgbStaticR !== rgbStaticR
                                         || pendingRgbStaticG !== rgbStaticG
                                         || pendingRgbStaticB !== rgbStaticB
    readonly property color previewColor: Qt.rgba(
                                              pendingRgbStaticR * pendingRgbBrightness / 65025,
                                              pendingRgbStaticG * pendingRgbBrightness / 65025,
                                              pendingRgbStaticB * pendingRgbBrightness / 65025,
                                              1
                                          )
    readonly property string pendingRgbHex: "#" + hexByte(pendingRgbStaticR) + hexByte(pendingRgbStaticG) + hexByte(pendingRgbStaticB)

    Component.onCompleted: refreshStatus(false)

    function hexByte(value) {
        const hex = Number(value).toString(16).toUpperCase()
        return hex.length < 2 ? "0" + hex : hex
    }

    function parseStatus(stdout) {
        const payload = JSON.parse(stdout)

        cpuBoost = payload.cpu_boost_enabled ? "1" : "0"
        fanProfile = payload.fan_profile
        fanSensorMode = payload.fan_sensor_mode
        rgbMode = payload.rgb_mode
        rgbBrightness = payload.rgb_brightness
        rgbStaticR = payload.rgb_static_r
        rgbStaticG = payload.rgb_static_g
        rgbStaticB = payload.rgb_static_b

        if (!preservePendingOnRefresh) {
            pendingCpuBoost = cpuBoost
            pendingFanProfile = fanProfile === "auto" ? "moderate" : fanProfile
            pendingFanSensorMode = fanSensorMode
            pendingRgbMode = rgbMode
            pendingRgbBrightness = rgbBrightness
            pendingRgbStaticR = rgbStaticR
            pendingRgbStaticG = rgbStaticG
            pendingRgbStaticB = rgbStaticB
        }

        preservePendingOnRefresh = false
    }

    function refreshStatus(preservePending) {
        preservePendingOnRefresh = preservePending === true
        if (loading) {
            statusError = ""
        }
        statusSource.connectSource(statusCommand)
    }

    function runAction(command, actionName) {
        actionError = ""
        actionRunning = true
        pendingAction = actionName
        actionSource.connectSource(command)
    }

    function saveCpu() {
        runAction(controlCommand + " set cpu-boost " + (pendingCpuBoost === "1" ? "on" : "off"),
                  qsTr("CPU boost"))
    }

    function saveCooling() {
        runAction(controlCommand + " set fan-state " + pendingFanProfile + " " + pendingFanSensorMode,
                  qsTr("cooling"))
    }

    function saveLighting() {
        runAction(controlCommand + " set rgb-state "
                  + pendingRgbMode + " "
                  + pendingRgbBrightness + " "
                  + pendingRgbStaticR + " "
                  + pendingRgbStaticG + " "
                  + pendingRgbStaticB,
                  qsTr("lighting"))
    }

    function revertCpu() {
        pendingCpuBoost = cpuBoost
    }

    function revertCooling() {
        pendingFanProfile = normalizedFanProfile
        pendingFanSensorMode = fanSensorMode
    }

    function revertLighting() {
        pendingRgbMode = rgbMode
        pendingRgbBrightness = rgbBrightness
        pendingRgbStaticR = rgbStaticR
        pendingRgbStaticG = rgbStaticG
        pendingRgbStaticB = rgbStaticB
    }

    P5Support.DataSource {
        id: statusSource
        engine: "executable"

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            page.loading = false

            if (data.stdout === undefined || data.stdout.trim().length === 0) {
                page.statusError = qsTr("Could not read current hardware settings.")
                return
            }

            try {
                page.parseStatus(data.stdout.trim())
                page.statusError = ""
            } catch (error) {
                page.statusError = qsTr("Hardware settings output could not be parsed.")
            }
        }
    }

    P5Support.DataSource {
        id: actionSource
        engine: "executable"

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            page.actionRunning = false

            const exitCode = data["exit code"] !== undefined ? Number(data["exit code"]) : 0
            if (exitCode !== 0) {
                const stderrText = data.stderr !== undefined ? data.stderr.trim() : ""
                page.actionError = stderrText.length > 0
                                   ? stderrText
                                   : qsTr("Updating %1 did not complete.").arg(page.pendingAction)
            } else {
                page.actionError = ""
            }

            page.refreshStatus(exitCode !== 0)
        }
    }

    ColumnLayout {
        width: Math.min(page.availableWidth, Kirigami.Units.gridUnit * 36)
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true

            QQC2.Label {
                Layout.fillWidth: true
                color: Kirigami.Theme.disabledTextColor
                text: qsTr("Defaults apply at boot. Changes here persist and take effect right away.")
                wrapMode: Text.Wrap
            }

            QQC2.Button {
                icon.name: "view-refresh"
                text: qsTr("Refresh")
                onClicked: page.refreshStatus(false)
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            text: page.statusError.length > 0 ? page.statusError : page.actionError
            type: Kirigami.MessageType.Error
            visible: text.length > 0
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            text: qsTr("Saving %1…").arg(page.pendingAction)
            type: Kirigami.MessageType.Information
            visible: page.actionRunning
        }

        Components.SectionBlock {
            title: qsTr("Performance")
            description: qsTr("Choose whether boost-capable CPU policies start enabled on this device.")

            RowLayout {
                Layout.fillWidth: true

                QQC2.Label {
                    Layout.fillWidth: true
                    text: qsTr("CPU boost")
                    wrapMode: Text.Wrap
                }

                QQC2.Switch {
                    checked: page.pendingCpuBoost === "1"
                    onToggled: page.pendingCpuBoost = checked ? "1" : "0"
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight

                QQC2.Button {
                    enabled: page.cpuDirty && !page.actionRunning
                    text: qsTr("Revert")
                    onClicked: page.revertCpu()
                }

                QQC2.Button {
                    enabled: page.cpuDirty && !page.actionRunning
                    icon.name: "dialog-ok-apply"
                    text: qsTr("Save")
                    onClicked: page.saveCpu()
                }
            }
        }

        Components.SectionBlock {
            title: qsTr("Cooling")
            description: qsTr("Set how quickly the fan reacts and which thermal reading drives the profile.")

            QQC2.Label {
                Layout.fillWidth: true
                font.bold: true
                text: qsTr("Fan profile")
            }

            GridLayout {
                Layout.fillWidth: true
                columns: width >= Kirigami.Units.gridUnit * 28 ? 4 : 2
                columnSpacing: Kirigami.Units.smallSpacing
                rowSpacing: Kirigami.Units.smallSpacing

                Components.ChoiceButton {
                    currentValue: page.pendingFanProfile
                    description: qsTr("Later ramp")
                    optionValue: "quiet"
                    text: qsTr("Quiet")
                    onClicked: page.pendingFanProfile = optionValue
                }

                Components.ChoiceButton {
                    currentValue: page.pendingFanProfile
                    description: qsTr("Balanced")
                    optionValue: "moderate"
                    text: qsTr("Balanced")
                    onClicked: page.pendingFanProfile = optionValue
                }

                Components.ChoiceButton {
                    currentValue: page.pendingFanProfile
                    description: qsTr("Earlier cooling")
                    optionValue: "aggressive"
                    text: qsTr("Aggressive")
                    onClicked: page.pendingFanProfile = optionValue
                }

                Components.ChoiceButton {
                    currentValue: page.pendingFanProfile
                    description: qsTr("Config thresholds")
                    optionValue: "custom"
                    text: qsTr("Custom")
                    onClicked: page.pendingFanProfile = optionValue
                }
            }

            QQC2.Label {
                Layout.fillWidth: true
                font.bold: true
                text: qsTr("Temperature source")
            }

            GridLayout {
                Layout.fillWidth: true
                columns: width >= Kirigami.Units.gridUnit * 20 ? 2 : 1
                columnSpacing: Kirigami.Units.smallSpacing
                rowSpacing: Kirigami.Units.smallSpacing

                Components.ChoiceButton {
                    currentValue: page.pendingFanSensorMode
                    description: qsTr("Hottest sensor wins")
                    optionValue: "max"
                    text: qsTr("Hottest")
                    onClicked: page.pendingFanSensorMode = optionValue
                }

                Components.ChoiceButton {
                    currentValue: page.pendingFanSensorMode
                    description: qsTr("Average temperature")
                    optionValue: "average"
                    text: qsTr("Average")
                    onClicked: page.pendingFanSensorMode = optionValue
                }
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                text: qsTr("Custom fan thresholds still live in /etc/thorch/hardware.conf for now.")
                type: Kirigami.MessageType.Information
                visible: page.pendingFanProfile === "custom"
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight

                QQC2.Button {
                    enabled: page.coolingDirty && !page.actionRunning
                    text: qsTr("Revert")
                    onClicked: page.revertCooling()
                }

                QQC2.Button {
                    enabled: page.coolingDirty && !page.actionRunning
                    icon.name: "dialog-ok-apply"
                    text: qsTr("Save")
                    onClicked: page.saveCooling()
                }
            }
        }

        Components.SectionBlock {
            title: qsTr("Lighting")
            description: qsTr("Control the Thor stick LEDs without fighting later user changes.")

            QQC2.Label {
                Layout.fillWidth: true
                font.bold: true
                text: qsTr("Mode")
            }

            GridLayout {
                Layout.fillWidth: true
                columns: width >= Kirigami.Units.gridUnit * 28 ? 3 : 1
                columnSpacing: Kirigami.Units.smallSpacing
                rowSpacing: Kirigami.Units.smallSpacing

                Components.ChoiceButton {
                    currentValue: page.pendingRgbMode
                    description: qsTr("LEDs dark")
                    optionValue: "off"
                    text: qsTr("Off")
                    onClicked: page.pendingRgbMode = optionValue
                }

                Components.ChoiceButton {
                    currentValue: page.pendingRgbMode
                    description: qsTr("Battery status")
                    optionValue: "battery"
                    text: qsTr("Battery")
                    onClicked: page.pendingRgbMode = optionValue
                }

                Components.ChoiceButton {
                    currentValue: page.pendingRgbMode
                    description: qsTr("Manual color")
                    optionValue: "static"
                    text: qsTr("Static")
                    onClicked: page.pendingRgbMode = optionValue
                }
            }

            QQC2.Label {
                Layout.fillWidth: true
                font.bold: true
                text: qsTr("Brightness")
            }

            Components.ColorChannelControl {
                accentColor: Kirigami.Theme.highlightColor
                label: qsTr("LED brightness")
                value: page.pendingRgbBrightness
                onValueEdited: value => page.pendingRgbBrightness = value
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing
                visible: page.pendingRgbMode === "static"

                QQC2.Label {
                    Layout.fillWidth: true
                    font.bold: true
                    text: qsTr("Static color")
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Rectangle {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 4
                        radius: 8
                        color: page.previewColor
                        border.color: Kirigami.Theme.disabledTextColor
                    }

                    ColumnLayout {
                        Layout.fillWidth: true

                        QQC2.Label {
                            text: page.pendingRgbHex
                        }

                        QQC2.Label {
                            color: Kirigami.Theme.disabledTextColor
                            text: qsTr("Preview includes current brightness.")
                            wrapMode: Text.Wrap
                        }
                    }
                }

                Components.ColorChannelControl {
                    accentColor: "#D94A4A"
                    label: qsTr("Red")
                    value: page.pendingRgbStaticR
                    onValueEdited: value => page.pendingRgbStaticR = value
                }

                Components.ColorChannelControl {
                    accentColor: "#38B26D"
                    label: qsTr("Green")
                    value: page.pendingRgbStaticG
                    onValueEdited: value => page.pendingRgbStaticG = value
                }

                Components.ColorChannelControl {
                    accentColor: "#3D7CFF"
                    label: qsTr("Blue")
                    value: page.pendingRgbStaticB
                    onValueEdited: value => page.pendingRgbStaticB = value
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight

                QQC2.Button {
                    enabled: page.lightingDirty && !page.actionRunning
                    text: qsTr("Revert")
                    onClicked: page.revertLighting()
                }

                QQC2.Button {
                    enabled: page.lightingDirty && !page.actionRunning
                    icon.name: "dialog-ok-apply"
                    text: qsTr("Save")
                    onClicked: page.saveLighting()
                }
            }
        }
    }
}
