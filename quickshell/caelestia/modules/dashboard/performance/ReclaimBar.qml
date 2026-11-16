pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property DiskLedgerModel model
    required property var rows
    property var hovered: null
    property real capacity: 0
    property bool ordered: false
    property string node: ""
    property real weight: -1
    readonly property real minSlice: 3
    signal clicked(var row)
    signal rightClicked(var row)

    readonly property bool timed: !root.ordered && (root.rows ?? []).length > 0 && root.rows.every(row => row.last_used > 0)
    readonly property real barHeight: 28
    readonly property real axisHeight: root.ordered ? 0 : 14

    readonly property var slices: {
        const list = root.rows.filter(row => row.size > 0);
        const timed = root.timed;
        const presorted = list.length > 0 && list.every(row => row.at !== undefined || row.from !== undefined);
        if (!root.ordered && !presorted)
            list.sort((a, b) => timed ? a.last_used - b.last_used : b.size - a.size);
        const used = list.reduce((acc, item) => acc + item.size, 0);
        const total = Math.max(1, used, root.capacity);
        const minShare = root.minSlice / Math.max(1, root.width);
        const merged = [];
        let pending = [];
        const flush = () => {
            if (pending.length === 1 || (pending.length === list.length && root.node.startsWith("group:")))
                merged.push(...pending);
            else if (pending.length > 1)
                merged.push(root.group(pending));
            pending = [];
        };
        for (const item of list) {
            if (item.size / total >= minShare) {
                flush();
                merged.push(item);
            } else
                pending.push(item);
        }
        flush();
        const shares = merged.map(item => Math.max(minShare, item.size / total));
        const sum = shares.reduce((acc, share) => acc + share, 0);
        const scale = Math.min(1, used / total) / Math.max(sum, 1e-9);
        return merged.map((item, index) => Object.assign({}, item, {
                share: shares[index] * scale
            }));
    }

    function group(members: var): var {
        const first = members[0];
        const last = members[members.length - 1];
        const count = members.reduce((acc, item) => acc + (item.count ?? 1), 0);
        const ranged = root.node !== "" && !root.node.startsWith("group:") && members.every(item => item.at !== undefined || item.from !== undefined);
        return {
            id: ranged ? `slice:${first.from ?? first.at}:${last.to ?? last.at + 1}:${root.node}` : `group:${first.id}:${members.length}`,
            label: `${count} items`,
            path: "",
            paths: members.reduce((acc, item) => acc.concat(item.paths ?? [item.path]), []).filter(path => path),
            size: members.reduce((acc, item) => acc + item.size, 0),
            last_used: first.last_used,
            color: first.color,
            kind: "",
            count: count,
            from: first.from ?? first.at,
            to: last.to ?? last.at + 1,
            delvable: true,
            openable: false,
            reclaimable: members.every(item => item.reclaimable),
            weight: members.some(item => item.weight !== undefined) ? members.reduce((acc, item) => Math.max(acc, item.weight ?? -1), -1) : undefined,
            scheduled: members.every(item => item.scheduled),
            scheduledBytes: members.reduce((acc, item) => acc + (item.scheduledBytes ?? (item.scheduled ? item.size : 0)), 0),
            reclaimBytes: members.reduce((acc, item) => acc + (item.reclaimBytes ?? (item.reclaimable ? item.size : 0)), 0),
            members: members
        };
    }

    readonly property var boxes: {
        const out = [];
        let x = 0;
        let open = null;
        let openScheduled = null;
        for (const slice of root.slices) {
            const w = root.width * slice.share;
            if (slice.reclaimable && slice.reclaimSpans) {
                open = null;
                out.push(...root.model.mergeBoxes(slice.reclaimSpans.map(span => ({
                                x: x + w * span[0] / Math.max(1, slice.size),
                                w: w * span[1] / Math.max(1, slice.size),
                                scheduled: false
                            }))));
                openScheduled = null;
            } else if (slice.reclaimable) {
                const reach = slice.reclaimBytes !== undefined ? Math.min(1, slice.reclaimBytes / Math.max(1, slice.size)) : 1;
                if (open)
                    open.w = x + w * reach - open.x;
                else {
                    open = {
                        x: x,
                        w: w * reach,
                        scheduled: false
                    };
                    out.push(open);
                }
                if (reach < 1)
                    open = null;
                const part = slice.scheduledBytes !== undefined ? Math.min(1, slice.scheduledBytes / Math.max(1, slice.size)) : slice.scheduled ? 1 : 0;
                if (part > 0) {
                    if (openScheduled)
                        openScheduled.w = x + w * part - openScheduled.x;
                    else {
                        openScheduled = {
                            x: x,
                            w: w * part,
                            scheduled: true
                        };
                        out.push(openScheduled);
                    }
                    if (part < 1)
                        openScheduled = null;
                } else
                    openScheduled = null;
            } else {
                open = null;
                openScheduled = null;
            }
            x += w;
        }
        return root.ordered ? out : root.model.mergeBoxes(out);
    }

    readonly property var ticks: {
        if (!root.timed)
            return [];
        const out = [];
        const span = root.slices.length ? root.slices[root.slices.length - 1].last_used - root.slices[0].last_used : 0;
        let x = 0;
        let lastEnd = -1e9;
        let lastLabel = "";
        for (const slice of root.slices) {
            const label = root.model.axisLabel(slice.last_used, span);
            if (label !== lastLabel && x >= lastEnd) {
                out.push({
                    x: x,
                    label: label
                });
                lastEnd = x + label.length * 6.5 + 10;
                lastLabel = label;
            }
            x += root.width * slice.share;
        }
        return out;
    }

    implicitHeight: barHeight + axisHeight

    Rectangle {
        width: parent.width
        height: root.barHeight
        color: Colours.tPalette.m3surfaceContainer
    }

    HoverHandler {
        onHoveredChanged: if (!hovered)
            root.hovered = null
    }

    Repeater {
        model: root.ticks.length

        delegate: Item {
            id: tick

            required property int index
            readonly property var modelData: root.ticks[index] ?? ({})

            x: tick.modelData.x
            y: root.barHeight

            Rectangle {
                width: 1
                height: 4
                color: Colours.palette.m3onSurfaceVariant
            }

            StyledText {
                y: 3
                x: 2
                text: tick.modelData.label
                font: Tokens.font.body.builders.small.size(9).build()
                color: Colours.palette.m3onSurfaceVariant
            }
        }
    }

    Row {
        id: row

        width: parent.width
        height: root.barHeight
        spacing: 0

        Repeater {
            model: root.slices.length

            delegate: Item {
                id: slice

                required property int index
                readonly property var modelData: root.slices[index] ?? ({})

                readonly property bool lit: root.hovered !== null && root.hovered.id === slice.modelData.id

                width: row.width * slice.modelData.share
                height: row.height

                Rectangle {
                    anchors.fill: parent
                    anchors.rightMargin: 1
                    color: root.model.ageShade(slice.modelData.color, slice.modelData.last_used)
                    opacity: root.model.weightOpacity(slice.modelData.weight ?? (slice.modelData.reclaimable ? root.weight : -1))
                }

                Outline {
                    anchors.rightMargin: 1
                    visible: slice.lit
                    color: Colours.palette.m3onSurface
                    lineWidth: 2
                }

                Row {
                    anchors.centerIn: parent
                    visible: slice.width > amount.implicitWidth + 8
                    spacing: 4

                    StyledText {
                        readonly property real room: slice.width - 12 - amount.implicitWidth

                        visible: room > 24
                        text: slice.modelData.label
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurface
                        elide: /^[~/]/.test(slice.modelData.label) ? Text.ElideLeft : Text.ElideRight
                        width: Math.min(implicitWidth, room)
                    }

                    StyledText {
                        id: amount

                        text: root.model.gib(slice.modelData.size)
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurface
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: slice.modelData.delvable || slice.modelData.openable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onEntered: root.hovered = slice.modelData
                    onExited: if (slice.lit)
                        root.hovered = null
                    onClicked: mouse => {
                        if (mouse.button === Qt.LeftButton)
                            root.clicked(slice.modelData);
                        else
                            root.rightClicked(slice.modelData);
                    }
                }
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
            height: root.barHeight

            Outline {
                outset: box.modelData.scheduled ? 0 : 3
                dashed: !box.modelData.scheduled
                hatched: box.modelData.scheduled
                color: box.modelData.scheduled ? root.model.scheduledColor : root.model.reclaimColor
                lineWidth: box.modelData.scheduled ? 2 : 1.5
            }
        }
    }
}
