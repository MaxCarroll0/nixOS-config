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
        implicitHeight: label.implicitHeight + Tokens.padding.small * 2

        radius: Tokens.rounding.full
        color: WmState.normal ? Colours.palette.m3onSurface : Colours.palette.m3surfaceContainerHigh
        border.width: WmState.normal ? 2 : 1
        border.color: Colours.palette.m3outlineVariant

        StyledText {
            id: label

            anchors.centerIn: parent
            text: WmState.normal ? "N" : "I"
            font: Tokens.font.mono.builders.small.weight(Font.Bold).build()
            color: WmState.normal ? Colours.palette.m3surface : Colours.palette.m3onSurfaceVariant
        }
    }
}
