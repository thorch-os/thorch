import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: root

    required property string label
    required property color accentColor
    property int value: 0
    signal valueEdited(int value)

    spacing: Kirigami.Units.smallSpacing
    Layout.fillWidth: true

    RowLayout {
        Layout.fillWidth: true

        QQC2.Label {
            Layout.fillWidth: true
            font.bold: true
            text: root.label
        }

        QQC2.Label {
            text: String(root.value)
        }
    }

    QQC2.Slider {
        id: slider

        Layout.fillWidth: true
        from: 0
        to: 255
        stepSize: 1
        value: root.value

        palette.highlight: root.accentColor

        onMoved: root.valueEdited(Math.round(value))
        onValueChanged: {
            if (pressed) {
                root.valueEdited(Math.round(value));
            }
        }
    }
}
