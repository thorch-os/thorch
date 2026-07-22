import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

QQC2.Button {
    id: control

    required property string optionValue
    property string currentValue: ""
    property string description: ""

    checkable: true
    checked: currentValue === optionValue
    flat: true
    Layout.fillWidth: true
    Layout.minimumHeight: Kirigami.Units.gridUnit * 3.5
    padding: Kirigami.Units.largeSpacing

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            Layout.fillWidth: true
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            text: control.text
            wrapMode: Text.Wrap
        }

        QQC2.Label {
            Layout.fillWidth: true
            color: Kirigami.Theme.disabledTextColor
            horizontalAlignment: Text.AlignHCenter
            text: control.description
            visible: control.description.length > 0
            wrapMode: Text.Wrap
        }
    }

    background: Rectangle {
        radius: 8
        color: control.checked ? Kirigami.Theme.highlightColor : (control.hovered ? Kirigami.Theme.alternateBackgroundColor : Kirigami.Theme.backgroundColor)
        border.color: control.checked ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
        opacity: control.enabled ? 1 : 0.55
    }
}
