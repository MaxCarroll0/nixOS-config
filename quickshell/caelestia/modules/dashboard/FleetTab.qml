pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.dashboard.performance

Item {
    id: root

    readonly property real paneWidth: 1160

    implicitWidth: paneWidth
    implicitHeight: layout.implicitHeight
    focus: true

    FleetModel {
        id: fleetData

        active: root.visible
    }

    Keys.onLeftPressed: fleetData.anchor = fleetData.at - fleetData.smoothing / 2
    Keys.onRightPressed: {
        const next = fleetData.at + fleetData.smoothing / 2;
        fleetData.anchor = next >= fleetData.now ? null : next;
    }
    Keys.onSpacePressed: player.running = !player.running

    Timer {
        id: player

        interval: 400
        repeat: true
        onTriggered: {
            const next = fleetData.at + fleetData.smoothing / 4;
            if (next >= fleetData.now) {
                fleetData.anchor = null;
                running = false;
            } else
                fleetData.anchor = next;
        }
    }

    function timeText(seconds: real): string {
        return fleetData.stamp(seconds);
    }

    function parseTime(text: string): real {
        const trimmed = text.trim();
        const now = Date.now() / 1000;
        if (trimmed === "now")
            return now;
        let match = trimmed.match(/^-\s*(\d+(?:\.\d+)?)\s*([mhdw])$/);
        if (match)
            return now - parseFloat(match[1]) * ({
                    m: 60,
                    h: 3600,
                    d: 86400,
                    w: 7 * 86400
                })[match[2]];
        match = trimmed.match(/^(\d{4})[-\/](\d{2})[-\/](\d{2})(?:[ T](\d{1,2}):(\d{2}))?$/);
        if (match)
            return new Date(+match[1], +match[2] - 1, +match[3], +(match[4] ?? 0), +(match[5] ?? 0)).getTime() / 1000;
        match = trimmed.match(/^(\d{1,2})\/(\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?$/);
        if (match)
            return new Date(new Date().getFullYear(), +match[1] - 1, +match[2], +(match[3] ?? 0), +(match[4] ?? 0)).getTime() / 1000;
        match = trimmed.match(/^(?:(\w{3})\s+)?(\d{1,2}):(\d{2})$/);
        if (match) {
            const date = new Date();
            date.setHours(+match[2], +match[3], 0, 0);
            if (match[1]) {
                const want = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].indexOf(match[1].toLowerCase());
                if (want < 0)
                    return NaN;
                date.setDate(date.getDate() - ((date.getDay() - want + 7) % 7));
            }
            return date.getTime() / 1000;
        }
        return NaN;
    }

    function hoverAt(x: real, y: real): void {
        const onMap = map.mapFromItem(root, x, y);
        const onTimeline = timeline.mapFromItem(root, x, y);
        map.pointer = map.contains(onMap) ? onMap : null;
        timeline.pointer = timeline.contains(onTimeline) ? onTimeline : null;
    }

    function setRange(from: real, to: real): void {
        if (isNaN(from) || isNaN(to))
            return;
        timeline.setRange(Math.min(from, to), Math.max(from, to));
    }

    component Choice: StyledText {
        id: choice

        property bool selected
        signal picked

        font: Tokens.font.body.small
        color: selected ? Colours.palette.m3onSurface : Colours.palette.m3primary

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: choice.picked()
        }
    }

    component TimeField: StyledTextField {
        Layout.preferredWidth: 96
        verticalPadding: 2
        horizontalPadding: 6
        radius: 4
        font: Tokens.font.body.small
    }

    ColumnLayout {
        id: layout

        width: root.paneWidth
        spacing: Tokens.spacing.medium

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.medium

            StyledText {
                text: "Fleet"
                font: Tokens.font.title.small
                color: Colours.palette.m3primary
            }

            StyledText {
                text: fleetData.following ? "live" : `at ${fleetData.stamp(fleetData.at)}`
                font: Tokens.font.body.small
                color: fleetData.following ? Colours.palette.m3tertiary : Colours.palette.m3onSurface
            }

            Choice {
                visible: !fleetData.following
                text: "back to live"
                onPicked: {
                    player.running = false;
                    fleetData.anchor = null;
                }
            }

            MaterialIcon {
                text: player.running ? "pause" : "play_arrow"
                color: Colours.palette.m3primary

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!player.running && fleetData.following)
                            fleetData.anchor = fleetData.range[0] + fleetData.smoothing;
                        player.running = !player.running;
                    }
                }
            }

            StyledText {
                visible: !fleetData.reachable
                text: fleetData.error
                font: Tokens.font.body.small
                color: Colours.palette.m3error
            }

            Item {
                Layout.fillWidth: true
            }

            StyledText {
                text: "window"
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
            }

            Repeater {
                model: [["1m", 60], ["5m", 300], ["10m", 600], ["30m", 1800], ["1h", 3600]]

                delegate: Choice {
                    required property var modelData

                    text: modelData[0]
                    selected: Math.abs(fleetData.smoothing - modelData[1]) < 1
                    onPicked: fleetData.smoothing = modelData[1]
                }
            }

            StyledText {
                visible: ![60, 300, 600, 1800, 3600].some(value => Math.abs(fleetData.smoothing - value) < 1)
                text: fleetData.smoothing >= 3600 ? `${(fleetData.smoothing / 3600).toFixed(1)}h` : `${Math.round(fleetData.smoothing / 60)}m`
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurface
            }
        }

        FleetMap {
            id: map

            Layout.fillWidth: true
            Layout.preferredHeight: 360
            fleet: fleetData

            FleetLegend {
                rows: 15
                colours: fleetData.colours
                entries: [["", "load"], ["outline", "load per core"], ["ring", "1 per core"], ["cpu", "cpu stall"], ["io", "io stall"], ["memory", "memory stall"], ["", "links"], ["direct", "direct"], ["relayed", "relayed"], ["down", "unreachable"], ["", "traffic"], ["lane:1000", "1 KB/s"], ["lane:100000", "100 KB/s"], ["lane:10000000", "10 MB/s"], ["builds", "builds"]]
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            FleetLegend {
                rows: 1
                flow: Grid.LeftToRight
                colours: fleetData.colours
                entries: [["barDirect", "direct"], ["barRelayed", "relayed"], ["barDown", "offline"], ["line", "traffic (log)"]]
            }

            Item {
                Layout.fillWidth: true
            }

            TimeField {
                id: fromField

                text: root.timeText(fleetData.range[0])
                onAccepted: root.setRange(root.parseTime(text), fleetData.range[1])
                onActiveFocusChanged: if (!activeFocus)
                    text = root.timeText(fleetData.range[0])
            }

            StyledText {
                text: "–"
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
            }

            TimeField {
                id: toField

                text: root.timeText(fleetData.range[1])
                onAccepted: root.setRange(fleetData.range[0], root.parseTime(text))
                onActiveFocusChanged: if (!activeFocus)
                    text = root.timeText(fleetData.range[1])
            }

            Connections {
                target: fleetData
                function onRangeChanged(): void {
                    if (!fromField.activeFocus)
                        fromField.text = root.timeText(fleetData.range[0]);
                    if (!toField.activeFocus)
                        toField.text = root.timeText(fleetData.range[1]);
                }
            }

            Repeater {
                model: [["1h", 3600], ["6h", 6 * 3600], ["24h", 86400], ["7d", 7 * 86400], ["30d", 30 * 86400]]

                delegate: Choice {
                    required property var modelData

                    text: modelData[0]
                    selected: Math.abs(fleetData.range[1] - fleetData.range[0] - modelData[1]) < 60
                    onPicked: {
                        const end = fleetData.range[1] >= fleetData.now - 60 ? fleetData.now : fleetData.range[1];
                        root.setRange(end - modelData[1], end);
                    }
                }
            }
        }

        FleetTimeline {
            id: timeline

            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            fleet: fleetData
        }
    }
}
