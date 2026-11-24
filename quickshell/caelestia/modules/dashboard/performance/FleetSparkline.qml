pragma ComponentBehavior: Bound

import QtQuick
import Caelestia
import Caelestia.Components
import qs.services

Item {
    id: root

    property var graph: null
    readonly property var series: graph ? Array.from(graph.series) : []
    readonly property real peak: series.reduce((top, item) => Array.from(item.values).reduce((high, value) => isFinite(value) ? Math.max(high, value) : high, top), 0)
    readonly property real targetMax: nice(Math.max(graph?.floor ?? 1, peak))
    property real smoothMax: 1
    property string shownId: ""
    readonly property real axisWidth: 46

    function nice(value: real): real {
        const power = Math.pow(10, Math.floor(Math.log10(value)));
        for (const step of [1, 2, 5, 10])
            if (value <= step * power * 1.0001)
                return step * power;
        return 10 * power;
    }

    function follow(): void {
        const id = `${graph?.id ?? ""}\u001f${peak > 0}`;
        if (id === shownId) {
            smoothMax = targetMax;
            return;
        }
        shownId = id;
        scaleAnimation.enabled = false;
        smoothMax = targetMax;
        scaleAnimation.enabled = true;
    }

    onTargetMaxChanged: follow()
    onGraphChanged: follow()

    visible: graph !== null
    implicitWidth: 280
    implicitHeight: visible ? 84 : 0

    Behavior on smoothMax {
        id: scaleAnimation

        NumberAnimation {
            duration: 400
            easing.type: Easing.OutCubic
        }
    }

    Item {
        id: plot

        anchors.left: parent.left
        anchors.leftMargin: root.axisWidth
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 6
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16

        Repeater {
            model: 3

            Rectangle {
                required property int index

                width: plot.width
                height: 1
                y: plot.height * index / 2
                color: Qt.alpha(Colours.palette.m3onSurface, index === 2 ? 0.25 : 0.1)
            }
        }

        Repeater {
            model: root.series

            SparklineItem {
                id: line

                required property var modelData

                anchors.fill: parent
                line1: CircularBuffer {
                    id: buffer
                }
                line1Color: modelData.colour
                line1FillAlpha: 0.15
                lineWidth: 1.5
                maxValue: root.smoothMax
                historyLength: buffer.capacity
                slideProgress: 1

                function load(): void {
                    const values = Array.from(modelData.values);
                    buffer.capacity = Math.max(2, values.length);
                    buffer.clear();
                    for (const value of values)
                        buffer.push(isFinite(value) ? Math.max(0, value) : 0);
                }

                onModelDataChanged: load()
                Component.onCompleted: load()
            }
        }
    }

    Repeater {
        model: 3

        Text {
            required property int index

            anchors.right: plot.left
            anchors.rightMargin: 4
            y: plot.y + plot.height * index / 2 - height / 2
            text: index === 2 ? "0" : root.graph ? root.graph.format(root.smoothMax * (1 - index / 2)) : ""
            font.pixelSize: 9
            color: Colours.palette.m3onSurfaceVariant
        }
    }

    Text {
        anchors.left: plot.left
        anchors.top: plot.bottom
        anchors.topMargin: 2
        text: root.graph ? `-${root.graph.span}` : ""
        font.pixelSize: 9
        color: Colours.palette.m3onSurfaceVariant
    }

    Text {
        anchors.right: plot.right
        anchors.top: plot.bottom
        anchors.topMargin: 2
        text: "now"
        font.pixelSize: 9
        color: Colours.palette.m3onSurfaceVariant
    }
}
