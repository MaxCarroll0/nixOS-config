import QtQuick
import Caelestia.Config
import qs.components
import qs.services

StyledRect {
    id: root

    property alias text: label.text
    property bool prominent

    implicitWidth: Math.max(label.implicitWidth + Tokens.padding.small * 2, implicitHeight)
    implicitHeight: label.implicitHeight + Tokens.padding.extraSmall * 2

    radius: Tokens.rounding.small
    color: prominent ? Colours.palette.m3primaryContainer : Colours.tPalette.m3surfaceContainerHigh

    StyledText {
        id: label

        anchors.centerIn: parent
        font: Tokens.font.mono.small
        color: root.prominent ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
    }
}
