import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

QQC2.Frame {
    id: root

    required property string title
    property string description: ""
    default property alias content: body.data

    Layout.fillWidth: true
    padding: Kirigami.Units.largeSpacing

    background: Rectangle {
        radius: 8
        color: Kirigami.Theme.alternateBackgroundColor
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.10)
    }

    contentItem: ColumnLayout {
        id: body

        spacing: Kirigami.Units.largeSpacing

        QQC2.Label {
            Layout.fillWidth: true
            font.bold: true
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
            text: root.title
            wrapMode: Text.Wrap
        }

        QQC2.Label {
            Layout.fillWidth: true
            color: Kirigami.Theme.disabledTextColor
            text: root.description
            visible: root.description.length > 0
            wrapMode: Text.Wrap
        }
    }
}
