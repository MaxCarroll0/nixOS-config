pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services

StyledRect {
    id: root

    property var lines: []
    property var graph: null
    property point at
    property real boundsWidth
    property real boundsHeight

    visible: lines.length > 0
    z: 10
    x: Math.max(0, Math.min(boundsWidth - width, at.x + 14))
    y: at.y + 14 + height > boundsHeight ? Math.max(0, at.y - 10 - height) : at.y + 14
    implicitWidth: column.implicitWidth + Tokens.padding.medium * 2
    implicitHeight: column.implicitHeight + Tokens.padding.small * 2
    radius: Tokens.rounding.small
    color: Colours.palette.m3surfaceContainerHighest

    Column {
        id: column

        anchors.centerIn: parent
        spacing: 1

        Repeater {
            model: root.lines

            delegate: Row {
                id: line

                required property var modelData
                required property int index

                spacing: 6

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!line.modelData[1]
                    implicitWidth: 8
                    implicitHeight: 8
                    radius: 2
                    color: line.modelData[1] || "transparent"
                }

                StyledText {
                    text: line.modelData[0]
                    font: line.index === 0 ? Tokens.font.body.medium : Tokens.font.body.small
                    color: line.index === 0 ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                }
            }
        }

        FleetSparkline {
            graph: root.graph
        }
    }
}
