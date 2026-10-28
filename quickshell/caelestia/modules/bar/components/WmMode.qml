import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

ColumnLayout {
    id: root

    spacing: Tokens.spacing.small

    OsIcon {
        Layout.alignment: Qt.AlignHCenter
    }

    StyledRect {
        Layout.alignment: Qt.AlignHCenter
        implicitWidth: Tokens.sizes.bar.innerWidth
        implicitHeight: WmState.normal ? label.implicitHeight + Tokens.padding.small * 2 : 0
        visible: implicitHeight > 0
        clip: true

        radius: Tokens.rounding.full
        color: Colours.palette.m3primary

        StyledText {
            id: label

            anchors.centerIn: parent
            text: "N"
            font: Tokens.font.mono.builders.small.weight(Font.Bold).build()
            color: Colours.palette.m3onPrimary
        }

        Behavior on implicitHeight {
            Anim {}
        }
    }
}
