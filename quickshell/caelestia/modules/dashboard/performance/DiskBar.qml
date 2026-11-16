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
        let open = null;
        for (const segment of root.model.segments) {
            const w = root.width * root.model.current(segment.key) / root.model.total;
            if (w > 0) {
                if (segment.reclaim && segment.spans) {
                    open = null;
                    const bytes = Math.max(1, root.model.current(segment.key));
                    out.push(...root.model.mergeBoxes(segment.spans.map(span => ({ x: x + w * span[0] / bytes, w: w * span[1] / bytes, scheduled: false }))));
                } else if (segment.reclaim) {
                    if (open)
                        open.w = x + w - open.x;
                    else {
                        open = { x: x, w: w, scheduled: false };
                        out.push(open);
                    }
                    const scheduled = root.model.scheduledFraction(segment.key);
                    if (scheduled > 0)
                        out.push({ x: x, w: w * scheduled, scheduled: true, key: segment.key, label: segment.label, bytes: root.model.scheduledBytes(segment.key) });
                } else
                    open = null;
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
                visible: free.width > label.implicitWidth + 16
                width: label.implicitWidth + 10
                height: label.implicitHeight + 2
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

            Outline {
                outset: box.modelData.scheduled ? 0 : 3
                dashed: !box.modelData.scheduled
                hatched: box.modelData.scheduled
                color: box.modelData.scheduled ? root.model.scheduledColor : root.model.reclaimColor
                lineWidth: box.modelData.scheduled ? 2 : 1.5
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
