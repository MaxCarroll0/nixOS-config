pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property DiskLedgerModel model
    property string selected: ""
    property string hovered: ""
    property var hoveredScheduled: null
    property bool showTarget: true
    signal picked(string key)

    readonly property real targetX: width * (1 - model.target / model.total)
    readonly property color divider: Colours.tPalette.m3surfaceContainer

    readonly property var boxes: {
        const out = [];
        let x = 0;
        for (const segment of root.model.segments) {
            const w = root.width * root.model.current(segment.key) / root.model.total;
            const inner = Math.max(0, w - 1);
            if (w > 0 && segment.reclaim) {
                if (segment.spans) {
                    const bytes = Math.max(1, root.model.current(segment.key));
                    for (const span of segment.spans) {
                        const from = x + w * span[0] / bytes;
                        const to = Math.min(x + inner, from + w * span[1] / bytes);
                        if (to > from)
                            out.push({ x: from, w: to - from, scheduled: false });
                    }
                } else
                    out.push({ x: x, w: inner, scheduled: false });
                const scheduled = root.model.scheduledFraction(segment.key);
                if (scheduled > 0)
                    out.push({ x: x, w: Math.min(w, w * scheduled + 1), scheduled: true, key: segment.key, label: segment.label, bytes: root.model.scheduledBytes(segment.key) });
                const deleting = root.model.deletingFraction(segment.key);
                if (deleting > 0)
                    out.push({ x: x, w: Math.min(w, w * deleting + 1), deleting: true });
            }
            x += w;
        }
        return out;
    }

    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        color: root.divider
    }

    HoverHandler {
        onHoveredChanged: if (!hovered) root.hovered = ""
    }

    Row {
        id: pieces

        anchors.fill: parent
        spacing: 0

        Repeater {
            model: root.model.segments.length

            delegate: Item {
                id: piece

                required property int index
                readonly property var modelData: root.model.segments[index] ?? ({})

                readonly property real value: root.model.current(piece.modelData.key)
                readonly property bool active: root.selected === piece.modelData.key || root.hovered === piece.modelData.key

                width: pieces.width * piece.value / root.model.total
                height: pieces.height
                visible: width > 0

                Rectangle {
                    anchors.fill: parent
                    anchors.rightMargin: 1
                    color: piece.modelData.color
                    opacity: root.model.weightOpacity(piece.modelData.weight) * (root.selected === "" || piece.active ? 1 : 0.35)
                }

                Outline {
                    anchors.rightMargin: 1
                    visible: piece.active
                    color: Colours.palette.m3onSurface
                    lineWidth: 2
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.hovered = piece.modelData.key
                    onExited: if (root.hovered === piece.modelData.key) root.hovered = ""
                    onClicked: root.picked(piece.modelData.key)
                }
            }
        }

        Item {
            id: free

            width: pieces.width * root.model.free / root.model.total
            height: pieces.height

            Canvas {
                id: hatch

                anchors.fill: parent
                readonly property color ink: root.model.hatchColor

                onInkChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.strokeStyle = ink;
                    ctx.lineWidth = 1;
                    ctx.strokeRect(0.5, 0.5, width - 1, height - 1);
                    ctx.globalAlpha = 0.7;
                    for (let x = -height; x < width; x += 7) {
                        ctx.beginPath();
                        ctx.moveTo(x, height);
                        ctx.lineTo(x + height, 0);
                        ctx.stroke();
                    }
                }
            }

            Rectangle {
                anchors.centerIn: parent
                visible: free.width > label.implicitWidth + 24
                width: label.implicitWidth + 16
                height: Math.min(free.height - 4, label.implicitHeight + 6)
                color: Colours.tPalette.m3surfaceContainer

                StyledText {
                    id: label

                    anchors.centerIn: parent
                    text: `${root.model.gib(root.model.free)} free`
                    font: Tokens.font.body.builders.small.size(Math.min(Tokens.font.body.small.pointSize, root.height * 0.36)).weight(Font.DemiBold).build()
                    color: Colours.palette.m3onSurface
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.hovered = "free"
                onExited: if (root.hovered === "free") root.hovered = ""
            }
        }
    }

    ReclaimHatch {
        anchors.fill: parent
        opacity: root.selected === "" ? 1 : 0.35
        spans: root.boxes.filter(box => !box.scheduled && !box.deleting)
        color: root.model.reclaimColor
    }

    Repeater {
        model: root.boxes.length

        delegate: Item {
            id: box

            required property int index
            readonly property var modelData: root.boxes[index] ?? ({})

            x: box.modelData.x
            width: Math.max(0, box.modelData.w - 1)
            height: root.height
            opacity: root.selected === "" ? 1 : 0.35

            Rectangle {
                visible: box.modelData.deleting === true
                anchors.fill: parent
                color: root.model.deletingColor
            }

            Outline {
                visible: box.modelData.scheduled === true
                hatched: true
                color: root.model.scheduledColor
                lineWidth: 2
            }

            MouseArea {
                anchors.fill: parent
                visible: box.modelData.scheduled
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: {
                    root.hovered = box.modelData.key;
                    root.hoveredScheduled = box.modelData;
                }
                onExited: {
                    if (root.hoveredScheduled === box.modelData)
                        root.hoveredScheduled = null;
                    if (root.hovered === box.modelData.key)
                        root.hovered = "";
                }
            }
        }
    }

    Rectangle {
        visible: root.showTarget && root.model.target > 0
        x: root.targetX - 1
        width: 2
        height: parent.height + 8
        anchors.verticalCenter: parent.verticalCenter
        color: Colours.palette.m3error
    }

    StyledText {
        visible: root.showTarget && root.model.target > 0
        anchors.top: parent.bottom
        anchors.topMargin: 3
        x: Math.max(0, Math.min(root.targetX - implicitWidth / 2, parent.width - implicitWidth))
        text: `target ${root.model.gib(root.model.target)} free`
        font: Tokens.font.body.small
        color: Colours.palette.m3error
    }
}
