pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services
import "boxes.js" as Boxes

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

    readonly property var pieces: {
        const pieces = [];
        let x = 0;
        for (const segment of root.model.segments) {
            const bytes = root.model.current(segment.key);
            const w = root.width * bytes / root.model.total;
            const scheduled = segment.reclaim ? root.model.scheduledBytes(segment.key) : 0;
            pieces.push({
                x: x,
                w: w,
                bytes: bytes,
                key: segment.key,
                label: segment.label,
                reclaimSpans: segment.reclaim ? segment.spans ?? null : null,
                reclaimBytes: segment.reclaim ? segment.reclaimBytes ?? 0 : 0,
                scheduledSpans: scheduled > 0 ? segment.scheduledSpans ?? null : null,
                scheduledBytes: scheduled,
                nextSpans: segment.nextSpan ? [segment.nextSpan] : null,
                deletingSpans: segment.deletingSpans ?? null,
                deletingBytes: segment.reclaim ? root.model.deletingFraction(segment.key) * bytes : 0,
                laggingSpans: segment.laggingSpans ?? null,
                laggingBytes: segment.reclaim ? root.model.laggingFraction(segment.key) * bytes : 0,
                ghostSpans: segment.ghostSpans
            });
            x += w;
        }
        return pieces;
    }

    readonly property var boxes: Boxes.layout(root.pieces)

    readonly property var ghostBoxes: root.pieces.flatMap(piece => piece.ghostSpans.map(ghost => ({
                    x: piece.x + piece.w * ghost.start / Math.max(1, piece.bytes),
                    w: piece.w * ghost.len / Math.max(1, piece.bytes),
                    at: ghost.at
                })))

    implicitHeight: 22
    readonly property font labelFont: Tokens.font.body.builders.small.size(Math.min(Tokens.font.body.small.pointSize, root.implicitHeight * 0.36)).weight(Font.DemiBold).build()

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
                    opacity: root.selected === "" || piece.active ? 1 : 0.35
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

            width: pieces.width * root.model.shownFree / root.model.total
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
                    font: root.labelFont
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

    ReclaimBoxes {
        y: -outset
        width: parent.width
        height: root.height + 2 * outset
        outset: 3
        opacity: root.selected === "" ? 1 : 0.35
        spans: root.boxes.filter(box => !box.scheduled && !box.deleting && !box.lagging && !box.next)
        color: root.model.reclaimColor
    }

    ReclaimBoxes {
        anchors.fill: parent
        opacity: root.selected === "" ? 1 : 0.35
        spans: root.boxes.filter(box => box.scheduled)
        color: root.model.scheduledColor
    }

    Pointers {
        y: -size - 4
        width: parent.width
        height: root.height + 2 * (size + 4)
        barHeight: root.height + 6
        marks: root.boxes.filter(box => box.next)
        color: root.model.deletingColor
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
                visible: box.modelData.lagging === true
                anchors.fill: parent
                color: root.model.laggingColor
            }

            Rectangle {
                visible: box.modelData.deleting === true
                anchors.fill: parent
                color: root.model.deletingColor
            }

            MouseArea {
                readonly property real reach: box.modelData.next ? 10 : 0

                x: Math.min(0, (parent.width - 8) / 2)
                y: -reach
                width: Math.max(parent.width, 8)
                height: parent.height + 2 * reach
                z: box.modelData.next ? 1 : 0
                visible: box.modelData.scheduled === true || box.modelData.next === true
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

    Repeater {
        model: root.ghostBoxes.length

        delegate: Rectangle {
            id: ghost

            required property int index
            readonly property var modelData: root.ghostBoxes[index] ?? ({})

            x: ghost.modelData.x
            width: Math.max(1, ghost.modelData.w - 1)
            height: root.height
            color: root.model.deletingColor
            opacity: Math.max(0, 1 - (root.model.ghostNow - ghost.modelData.at) / root.model.ghostSeconds)
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
