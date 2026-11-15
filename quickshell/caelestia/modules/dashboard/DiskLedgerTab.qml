pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.dashboard.performance

Item {
    id: root

    property var trail: []
    readonly property var node: trail.length ? trail[trail.length - 1] : null
    readonly property real paneWidth: 1160
    readonly property real chartHeight: 150
    readonly property var rootRows: ledger.segments.filter(segment => segment.bytes > 0).map(segment => segmentNode(segment))
    property var range: null
    property var bounds: null
    property var focusEvent: null
    readonly property var focusNode: !root.node ? null : root.node
    readonly property string focusSegment: root.trail.length ? root.trail[0].segment : ""
    readonly property var nodeRows: root.node ? ledger.rows(root.node.id) : null
    readonly property bool loading: root.node !== null && root.nodeRows === null && !root.focusEvent
    readonly property var entries: {
        if (root.focusEvent)
            return root.takenRows(root.focusEvent);
        if (!root.node)
            return root.rootRows;
        const color = root.trail[0].color;
        return (root.nodeRows ?? []).filter(row => !row.missing).map(row => Object.assign({}, row, { color: color, segment: root.focusSegment }));
    }
    readonly property var span: {
        if (root.range !== null)
            return root.range;
        const points = ledger.history;
        if (points.length < 2)
            return [Date.now() / 1000 - 3600, Date.now() / 1000];
        return [points[0].at, points[points.length - 1].at];
    }
    readonly property var visiblePoints: {
        const [first, last] = root.span;
        const points = ledger.history.filter(point => point.at >= first && point.at <= last);
        return points.length >= 2 ? points : ledger.history;
    }

    readonly property var fullSpan: {
        const points = ledger.history;
        if (points.length < 2)
            return root.span;
        return [points[0].at, points[points.length - 1].at];
    }

    readonly property var runs: {
        const out = [];
        for (const event of ledger.events) {
            const last = out.length ? out[out.length - 1] : null;
            if (last && event.at - last.at < 900)
                last.events.push(event);
            else
                out.push({ events: [event] });
        }
        return out.map(group => root.runFrom(group.events));
    }

    function runFrom(events: var): var {
        const run = { run: true, at: events[0].at, events: events, freed: 0, seconds: 0, items: 0, failed: false, taken: ({}), free_gib: events[0].free_gib ?? 0 };
        for (const event of events) {
            run.freed += Math.max(0, event.freed ?? 0);
            run.seconds += event.seconds ?? 0;
            run.items += event.items ?? 0;
            run.failed = run.failed || event.status !== 0;
            Object.assign(run.taken, event.taken ?? ({}));
        }
        return run;
    }

    function segmentLabel(key: string): string {
        return ledger.segment(key)?.label ?? key;
    }

    function segmentColor(key: string): color {
        return ledger.swatches[key] ?? Colours.palette.m3outline;
    }

    function runLabel(run: var): string {
        const names = [];
        for (const event of run.events) {
            const name = root.segmentLabel(event.segment);
            if (!names.includes(name))
                names.push(name);
        }
        return names.join(", ");
    }

    function timeText(seconds: real): string {
        return ledger.clock(seconds);
    }

    function parseTime(text: string, fallback: real): real {
        const trimmed = text.trim();
        const now = Date.now() / 1000;
        if (trimmed === "now")
            return now;
        let match = trimmed.match(/^-\s*(\d+(?:\.\d+)?)\s*([mhdw])$/);
        if (match)
            return now - parseFloat(match[1]) * ({ m: 60, h: 3600, d: 86400, w: 7 * 86400 })[match[2]];
        match = trimmed.match(/^(\d{4})[-\/](\d{2})[-\/](\d{2})(?:[ T](\d{1,2}):(\d{2}))?$/);
        if (match)
            return new Date(+match[1], +match[2] - 1, +match[3], +(match[4] ?? 0), +(match[5] ?? 0)).getTime() / 1000;
        match = trimmed.match(/^(\d{1,2})\/(\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?$/);
        if (match)
            return new Date(new Date().getFullYear(), +match[1] - 1, +match[2], +(match[3] ?? 0), +(match[4] ?? 0)).getTime() / 1000;
        const base = new Date(fallback * 1000);
        match = trimmed.match(/^(?:(\w{3})\s+)?(\d{1,2}):(\d{2})$/);
        if (match) {
            const date = new Date(base.getFullYear(), base.getMonth(), base.getDate(), +match[2], +match[3]);
            if (match[1]) {
                const names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
                const want = names.indexOf(match[1].toLowerCase());
                if (want < 0)
                    return NaN;
                const today = new Date();
                date.setFullYear(today.getFullYear(), today.getMonth(), today.getDate() - ((today.getDay() - want + 7) % 7));
                date.setHours(+match[2], +match[3], 0, 0);
            }
            return date.getTime() / 1000;
        }
        match = trimmed.match(/^(\d{1,2})\s+(\w{3})(?:\s+(\d{1,2}):(\d{2}))?$/);
        if (match) {
            const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
            const month = months.indexOf(match[2].toLowerCase());
            if (month < 0)
                return NaN;
            return new Date(new Date().getFullYear(), month, +match[1], +(match[3] ?? 0), +(match[4] ?? 0)).getTime() / 1000;
        }
        return NaN;
    }

    function setRange(from: real, to: real): void {
        if (isNaN(from) || isNaN(to))
            return;
        root.range = [Math.min(from, to - 60), Math.max(to, from + 60)];
    }

    function parseGib(text: string): real {
        const value = parseFloat(text.trim());
        return isNaN(value) ? NaN : value * 1073741824;
    }

    function setBounds(low: real, high: real): void {
        if (isNaN(low) || isNaN(high) || high <= low)
            return;
        root.bounds = [Math.max(0, low), high];
    }

    function gibText(bytes: real): string {
        return String(Math.round(bytes / 1073741824 * 10) / 10);
    }

    function nodeValue(point: var, node: var): real {
        if (node.id.startsWith("segment:"))
            return ledger.valueOf(point, node.segment);
        const items = (ledger.historyItems[point.at] ?? ({}))[root.focusSegment];
        if (typeof items !== "object")
            return NaN;
        let total = 0;
        let found = false;
        if (!node.path) {
            for (const row of node === root.node ? (root.nodeRows ?? []) : [])
                if (row.path && row.path in items) {
                    total += items[row.path];
                    found = true;
                }
            return found ? total : NaN;
        }
        if (node.path in items)
            return items[node.path];
        for (const path in items)
            if (path.startsWith(node.path + "/")) {
                total += items[path];
                found = true;
            }
        return found ? total : NaN;
    }

    function eventAmount(event: var): var {
        const focus = root.focusNode;
        if (!focus)
            return Math.max(0, event.freed ?? 0);
        if (focus.id.startsWith("segment:"))
            return event.segment === focus.segment ? Math.max(0, event.freed ?? 0) : null;
        const taken = event.taken ?? ({});
        let total = 0;
        let any = false;
        for (const key in taken) {
            if (key === focus.path || key.startsWith(focus.path + "/")) {
                total += taken[key];
                any = true;
            }
        }
        return any ? total : null;
    }

    function takenRows(run: var): var {
        const out = [];
        for (const event of run.events) {
            const taken = event.taken ?? ({});
            for (const key of Object.keys(taken))
                out.push({ id: `taken:${event.at}:${key}`, label: ledger.shortName(key), path: key, size: taken[key], last_used: 0, color: root.segmentColor(event.segment), segment: event.segment, kind: `collected ${root.segmentLabel(event.segment)}`, delvable: false, openable: false, reclaimable: true, scheduled: false });
        }
        return out;
    }

    function segmentNode(segment: var): var {
        return { id: `segment:${segment.key}`, label: segment.label, path: "", size: segment.bytes, last_used: 0, color: segment.color, kind: segment.reclaim ? `${segment.items} reclaimable items` : "segment", segment: segment.key, delvable: true, openable: false, reclaimable: segment.reclaim, scheduled: segment.scheduled > 0 };
    }

    function pick(key: string): void {
        const segment = ledger.segment(key);
        if (segment)
            root.trail = [root.segmentNode(segment)];
    }

    function delve(row: var): void {
        if (row.delvable)
            root.trail = root.trail.concat([row]);
        else if (row.pid)
            ledger.focusWindow(row.pid);
        else if (row.openable)
            ledger.open(row.path);
    }

    function repaint(): void {
        history.requestPaint();
        reclaims.requestPaint();
    }

    DiskLedgerModel {
        id: ledger

        drill: root.trail.map(node => node.id)
        onHistoryChanged: root.repaint()
        onEventsChanged: root.repaint()
        onOverviewChanged: root.repaint()
        onTargetChanged: history.requestPaint()
    }

    onTrailChanged: {
        bar.hovered = "";
        slices.hovered = null;
        if (root.trail.length)
            root.focusEvent = null;
        root.bounds = null;
        root.repaint();
    }
    onRangeChanged: root.repaint()
    onBoundsChanged: root.repaint()
    onFocusEventChanged: {
        if (root.focusEvent)
            root.trail = [];
        reclaims.requestPaint();
    }

    implicitWidth: layout.implicitWidth + Tokens.padding.large * 2
    implicitHeight: layout.implicitHeight + Tokens.padding.large * 2

    ColumnLayout {
        id: layout

        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.small

        RowLayout {
            Layout.preferredWidth: root.paneWidth
            spacing: Tokens.spacing.medium

            StyledText {
                text: ledger.loaded ? `${ledger.gib(ledger.free)} free of ${ledger.gib(ledger.diskTotal)}` : "No ledger yet"
                font: Tokens.font.title.medium
                color: ledger.deficit > 0 ? Colours.palette.m3error : Colours.palette.m3onSurface
            }

            StyledText {
                visible: ledger.collecting
                text: `collecting ${ledger.collectingStage}`
                font: Tokens.font.body.medium
                color: Colours.palette.m3tertiary
            }

            IconButton {
                visible: ledger.loaded
                icon: ledger.paused ? "play_arrow" : "pause"
                type: IconButton.Text
                onClicked: ledger.setPaused(!ledger.paused)
            }

            StyledText {
                visible: ledger.loaded
                text: ledger.paused ? `snapshot of ${ledger.clock(ledger.updated.getTime() / 1000)}` : ledger.live ? "live" : `file from ${ledger.clock(ledger.updated.getTime() / 1000)}`
                font: Tokens.font.body.small
                color: ledger.paused ? Colours.palette.m3tertiary : Colours.palette.m3onSurfaceVariant
            }

            Item {
                Layout.fillWidth: true
            }

            StyledText {
                text: "keep free"
                font: Tokens.font.body.medium
                color: Colours.palette.m3onSurfaceVariant
            }

            IconButton {
                icon: "remove"
                type: IconButton.Text
                onClicked: ledger.setTarget(ledger.targetGib - 5)
            }

            StyledTextField {
                id: targetField

                Layout.preferredWidth: 44
                verticalPadding: 2
                horizontalPadding: 6
                radius: 4
                horizontalAlignment: TextInput.AlignRight
                font: Tokens.font.body.builders.medium.weight(Font.DemiBold).build()
                color: Colours.palette.m3error
                validator: IntValidator {
                    bottom: 5
                    top: 200
                }
                text: String(ledger.targetGib)
                onAccepted: ledger.setTarget(parseInt(text))
                onActiveFocusChanged: if (!activeFocus) text = String(ledger.targetGib)

                Connections {
                    target: ledger
                    function onTargetGibChanged(): void {
                        if (!targetField.activeFocus)
                            targetField.text = String(ledger.targetGib);
                    }
                }
            }

            StyledText {
                text: "GiB"
                font: Tokens.font.body.medium
                color: Colours.palette.m3error
            }

            IconButton {
                icon: "add"
                type: IconButton.Text
                onClicked: ledger.setTarget(ledger.targetGib + 5)
            }
        }

        DiskBar {
            id: bar

            Layout.preferredWidth: root.paneWidth
            Layout.preferredHeight: 30
            Layout.bottomMargin: 16
            model: ledger
            selected: root.trail.length ? root.trail[0].segment ?? "" : ""
            onPicked: key => root.pick(key)
        }

        Flow {
            Layout.preferredWidth: root.paneWidth
            spacing: Tokens.spacing.medium

            Repeater {
                model: ledger.segments.filter(segment => segment.bytes > 0)

                delegate: Item {
                    id: legend

                    required property var modelData

                    readonly property bool lit: bar.hovered === legend.modelData.key || (root.trail.length > 0 && root.trail[0].segment === legend.modelData.key)

                    TextMetrics {
                        id: boldMetrics

                        font: Tokens.font.body.builders.small.weight(Font.DemiBold).build()
                        text: legendText.text
                    }

                    implicitWidth: 12 + Tokens.spacing.extraSmall + boldMetrics.width
                    implicitHeight: legendRow.implicitHeight
                    opacity: (bar.hovered === "" && root.trail.length === 0) || legend.lit ? 1 : 0.5

                    Row {
                        id: legendRow

                        spacing: Tokens.spacing.extraSmall

                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        implicitWidth: 12
                        implicitHeight: 12

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: legend.lit ? 0 : 1
                            color: legend.modelData.color
                        }

                        Outline {
                            readonly property bool scheduled: legend.modelData.scheduled > 0

                            visible: legend.modelData.reclaim
                            dashed: !scheduled
                            hatched: scheduled
                            color: scheduled ? ledger.scheduledColor : ledger.reclaimColor
                            lineWidth: scheduled ? 2 : 1.5
                        }
                    }

                    StyledText {
                        id: legendText

                        text: `${legend.modelData.label} ${ledger.gib(legend.modelData.bytes)}`
                        font: legend.lit ? Tokens.font.body.builders.small.weight(Font.DemiBold).build() : Tokens.font.body.small
                        color: legend.lit ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                    }

                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: bar.hovered = legend.modelData.key
                        onExited: if (bar.hovered === legend.modelData.key) bar.hovered = ""
                        onClicked: root.trail = [root.segmentNode(legend.modelData)]
                    }
                }
            }

            Repeater {
                model: [{ label: `free ${ledger.gib(ledger.free)}`, scheduled: false, free: true }, { label: "can be reclaimed", scheduled: false, free: false }, { label: "next collection", scheduled: true, free: false }]

                delegate: Row {
                    id: key

                    required property var modelData

                    spacing: Tokens.spacing.extraSmall

                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        implicitWidth: 12
                        implicitHeight: 12

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            color: Colours.tPalette.m3surfaceContainerHigh
                        }

                        Outline {
                            dashed: !key.modelData.scheduled && !key.modelData.free
                            hatched: key.modelData.scheduled || key.modelData.free
                            color: key.modelData.free ? ledger.hatchColor : key.modelData.scheduled ? ledger.scheduledColor : ledger.reclaimColor
                            lineWidth: key.modelData.scheduled ? 2 : key.modelData.free ? 1 : 1.5
                        }
                    }

                    StyledText {
                        text: key.modelData.label
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }
                }
            }
        }

        StyledText {
            visible: bar.hoveredScheduled !== null
            text: bar.hoveredScheduled ? `next collection takes ${ledger.gib(bar.hoveredScheduled.bytes)} of ${bar.hoveredScheduled.label}` : ""
            font: Tokens.font.body.small
            color: ledger.scheduledColor
        }

        RowLayout {
            Layout.topMargin: Tokens.spacing.small
            Layout.preferredWidth: root.paneWidth
            spacing: Tokens.spacing.small

            StyledText {
                text: "everything"
                font: root.trail.length === 0 && !root.focusEvent ? Tokens.font.title.small : Tokens.font.body.medium
                color: Colours.palette.m3primary

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.focusEvent = null;
                        root.trail = [];
                    }
                }
            }

            StyledText {
                visible: root.focusEvent !== null
                text: root.focusEvent ? `› ${root.focusEvent.events.length === 1 ? "collection" : root.focusEvent.events.length + " collections"} ${ledger.clock(root.focusEvent.at)}${root.focusEvent.events.length === 1 ? "" : "–" + ledger.clock(root.focusEvent.events[root.focusEvent.events.length - 1].at)} ${root.runLabel(root.focusEvent)} ${ledger.gib(root.focusEvent.freed)}` : ""
                font: Tokens.font.title.small
                color: Colours.palette.m3primary
            }

            Repeater {
                model: root.trail

                delegate: Row {
                    id: crumb

                    required property var modelData
                    required property int index

                    spacing: Tokens.spacing.small

                    StyledText {
                        text: "›"
                        font: Tokens.font.body.medium
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    StyledText {
                        readonly property bool middle: crumb.index > 0 && crumb.index < root.trail.length - 1
                        readonly property int room: Math.max(6, Math.floor((root.paneWidth - 760) / Math.max(1, root.trail.length - 2) / 8))
                        readonly property string name: crumb.modelData.label

                        text: !middle ? `${name} ${ledger.gib(crumb.modelData.size)}` : name.length > room ? name.slice(0, room - 1) + "…" : name
                        font: crumb.index === root.trail.length - 1 ? Tokens.font.title.small : Tokens.font.body.medium
                        color: Colours.palette.m3primary

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.trail = root.trail.slice(0, crumb.index + 1)
                        }
                    }
                }
            }

            Item {
                Layout.fillWidth: true
            }

            StyledText {
                visible: root.node !== null && root.node.openable
                text: "open"
                font: Tokens.font.body.medium
                color: Colours.palette.m3primary

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ledger.open(root.node.path)
                }
            }

            StyledText {
                visible: root.loading
                text: "loading…"
                font: Tokens.font.body.medium
                color: Colours.palette.m3tertiary
            }
        }

        ReclaimBar {
            id: slices

            capacity: root.node && !root.focusEvent ? root.node.size : 0
            ordered: root.node === null && !root.focusEvent

            Layout.preferredWidth: root.paneWidth
            model: ledger
            rows: root.entries
            onClicked: row => root.delve(row)
            onRightClicked: row => {
                if (row.openable)
                    ledger.open(row.path);
            }
        }

        Facts {
            Layout.preferredWidth: root.paneWidth
            item: slices.hovered
            fallback: root.node ? [["items", String(root.entries.length)]] : []
        }

        RowLayout {
            Layout.topMargin: Tokens.spacing.medium
            spacing: Tokens.spacing.large

            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                spacing: Tokens.spacing.extraSmall

                RowLayout {
                    Layout.preferredWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    spacing: Tokens.spacing.small

                    StyledText {
                        Layout.maximumWidth: 180
                        text: root.focusNode ? root.focusNode.label : "space over time"
                        font: Tokens.font.title.small
                        color: Colours.palette.m3primary
                        elide: Text.ElideMiddle
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    StyledTextField {
                        id: lowField

                        Layout.preferredWidth: 48
                        verticalPadding: 2
                        horizontalPadding: 6
                        radius: 4
                        horizontalAlignment: TextInput.AlignRight
                        font: Tokens.font.body.small
                        text: root.gibText(history.axis[0])
                        onAccepted: root.setBounds(root.parseGib(text), history.axis[1])
                        onActiveFocusChanged: if (!activeFocus) text = root.gibText(history.axis[0])

                        Connections {
                            target: history
                            function onAxisChanged(): void {
                                if (!lowField.activeFocus)
                                    lowField.text = root.gibText(history.axis[0]);
                            }
                        }
                    }

                    StyledText {
                        text: "–"
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    StyledTextField {
                        id: highField

                        Layout.preferredWidth: 48
                        verticalPadding: 2
                        horizontalPadding: 6
                        radius: 4
                        horizontalAlignment: TextInput.AlignRight
                        font: Tokens.font.body.small
                        text: root.gibText(history.axis[1])
                        onAccepted: root.setBounds(history.axis[0], root.parseGib(text))
                        onActiveFocusChanged: if (!activeFocus) text = root.gibText(history.axis[1])

                        Connections {
                            target: history
                            function onAxisChanged(): void {
                                if (!highField.activeFocus)
                                    highField.text = root.gibText(history.axis[1]);
                            }
                        }
                    }

                    StyledText {
                        text: "GiB"
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    StyledText {
                        visible: root.bounds !== null
                        text: "auto"
                        font: Tokens.font.body.small
                        color: Colours.palette.m3primary

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.bounds = null
                        }
                    }

                    Item {
                        Layout.preferredWidth: 12
                    }

                    StyledTextField {
                        id: fromField

                        Layout.preferredWidth: 92
                        verticalPadding: 2
                        horizontalPadding: 6
                        radius: 4
                        font: Tokens.font.body.small
                        text: root.timeText(root.span[0])
                        onAccepted: root.setRange(root.parseTime(text, root.span[0]), root.span[1])
                        onActiveFocusChanged: if (!activeFocus) text = root.timeText(root.span[0])

                        Connections {
                            target: root
                            function onSpanChanged(): void {
                                if (!fromField.activeFocus)
                                    fromField.text = root.timeText(root.span[0]);
                            }
                        }
                    }

                    StyledText {
                        text: "–"
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    StyledTextField {
                        id: toField

                        Layout.preferredWidth: 92
                        verticalPadding: 2
                        horizontalPadding: 6
                        radius: 4
                        font: Tokens.font.body.small
                        text: root.timeText(root.span[1])
                        onAccepted: root.setRange(root.span[0], root.parseTime(text, root.span[1]))
                        onActiveFocusChanged: if (!activeFocus) text = root.timeText(root.span[1])

                        Connections {
                            target: root
                            function onSpanChanged(): void {
                                if (!toField.activeFocus)
                                    toField.text = root.timeText(root.span[1]);
                            }
                        }
                    }

                    Repeater {
                        model: [["1h", 3600], ["6h", 6 * 3600], ["24h", 86400], ["7d", 7 * 86400]]

                        delegate: StyledText {
                            required property var modelData

                            text: modelData[0]
                            font: Tokens.font.body.small
                            color: Colours.palette.m3primary

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const end = root.range === null ? Date.now() / 1000 : root.span[1];
                                    root.range = [end - parent.modelData[1], end];
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: root.range !== null
                        text: "all"
                        font: Tokens.font.body.small
                        color: Colours.palette.m3primary

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.range = null
                        }
                    }
                }

                Canvas {
                    id: history

                    implicitWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    implicitHeight: root.chartHeight

                    property var layout: null
                    property var hoverPoint: null
                    property string hoverKey: ""
                    property var runXs: []

                    onHoverPointChanged: requestPaint()
                    property real dragFrom: -1
                    property real dragTo: -1

                    function runNear(px: real): var {
                        let best = null;
                        for (const item of history.runXs)
                            if (px >= item.from - 3 && px <= item.to + 3)
                                best = item;
                        return best ? best.run : null;
                    }

                    function eventNear(run: var, px: real): var {
                        if (!run)
                            return null;
                        const at = history.timeAt(px);
                        return run.events.reduce((best, event) => !best || Math.abs(event.at - at) < Math.abs(best.at - at) ? event : best, null);
                    }

                    function pointAt(px: real): var {
                        if (!history.layout)
                            return null;
                        const xs = history.layout.xs;
                        let index = 0;
                        for (let i = 1; i < xs.length; i++)
                            if (Math.abs(xs[i] - px) < Math.abs(xs[index] - px))
                                index = i;
                        return history.layout.points[index] ?? null;
                    }

                    function bandAt(px: real, py: real): var {
                        if (!history.layout)
                            return null;
                        const xs = history.layout.xs;
                        let index = 0;
                        for (let i = 1; i < xs.length; i++)
                            if (Math.abs(xs[i] - px) < Math.abs(xs[index] - px))
                                index = i;
                        return history.layout.bands.find(item => py <= history.layout.y(item.lows[index]) && py >= history.layout.y(item.highs[index])) ?? null;
                    }

                    Connections {
                        target: bar
                        function onHoveredChanged(): void {
                            history.requestPaint();
                            reclaims.requestPaint();
                        }
                    }

                    property var axis: [0, 1]
                    readonly property real plotLeft: 40
                    readonly property real plotBottom: height - 16
                    readonly property real plotWidth: width - plotLeft - 4

                    function timeAt(px: real): real {
                        const [first, last] = root.span;
                        return first + (last - first) * Math.max(0, Math.min(1, (px - plotLeft) / plotWidth));
                    }

                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.reset();
                        const focus = root.focusNode;
                        const points = focus && !focus.id.startsWith("segment:") ? root.visiblePoints.filter(point => isFinite(root.nodeValue(point, focus))) : root.visiblePoints;
                        history.layout = null;
                        if (points.length < 2) {
                            if (focus) {
                                ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
                                ctx.font = "10px sans-serif";
                                ctx.textAlign = "center";
                                ctx.fillText("no history recorded at this depth", plotLeft + plotWidth / 2, plotBottom / 2);
                            }
                            return;
                        }
                        const plotHeight = plotBottom - 4;
                        const [first, last] = root.span;
                        const spanSeconds = Math.max(1, last - first);
                        const x = at => plotLeft + plotWidth * (at - first) / spanSeconds;
                        const series = focus ? [focus] : ledger.segments;
                        const valueFor = (point, item) => focus ? root.nodeValue(point, focus) : ledger.valueOf(point, item.key);
                        const auto = focus ? Math.max(1, ...points.map(point => valueFor(point, focus))) * 1.1 : ledger.diskTotal;
                        const [low, top] = root.bounds ?? [0, auto];
                        if (history.axis[0] !== low || history.axis[1] !== top)
                            history.axis = [low, top];
                        const y = bytes => plotBottom - plotHeight * (bytes - low) / (top - low);
                        ctx.save();
                        ctx.beginPath();
                        ctx.rect(plotLeft, 4, plotWidth, plotHeight);
                        ctx.clip();
                        const base = points.map(() => 0);
                        const bands = [];
                        for (const item of series) {
                            const lows = base.slice();
                            ctx.beginPath();
                            ctx.moveTo(x(points[0].at), y(base[0]));
                            for (let i = 0; i < points.length; i++)
                                ctx.lineTo(x(points[i].at), y(base[i] + valueFor(points[i], item)));
                            for (let i = points.length - 1; i >= 0; i--)
                                ctx.lineTo(x(points[i].at), y(base[i]));
                            ctx.closePath();
                            ctx.fillStyle = item.color;
                            const quiet = bar.hovered === "" && root.trail.length === 0;
                            ctx.globalAlpha = focus || quiet || bar.hovered === item.key || (root.trail.length > 0 && root.trail[0].segment === item.key) ? 1 : 0.35;
                            ctx.fill();
                            ctx.globalAlpha = 1;
                            ctx.strokeStyle = Colours.tPalette.m3surfaceContainer;
                            ctx.beginPath();
                            for (let i = 0; i < points.length; i++)
                                ctx.lineTo(x(points[i].at), y(base[i] + valueFor(points[i], item)));
                            ctx.stroke();
                            for (let i = 0; i < points.length; i++)
                                base[i] += valueFor(points[i], item);
                            bands.push({ key: item.key ?? "", lows: lows, highs: base.slice() });
                        }
                        history.layout = { xs: points.map(point => x(point.at)), points: points, bands: bands, y: y, top: top };
                        if (history.hoverPoint) {
                            ctx.strokeStyle = Colours.palette.m3onSurface;
                            ctx.lineWidth = 1;
                            ctx.beginPath();
                            ctx.moveTo(Math.round(x(history.hoverPoint.at)) + 0.5, 4);
                            ctx.lineTo(Math.round(x(history.hoverPoint.at)) + 0.5, plotBottom);
                            ctx.stroke();
                        }
                        if (!focus) {
                            ctx.save();
                            ctx.beginPath();
                            ctx.moveTo(x(points[0].at), y(base[0]));
                            for (let i = 0; i < points.length; i++)
                                ctx.lineTo(x(points[i].at), y(base[i]));
                            for (let i = points.length - 1; i >= 0; i--)
                                ctx.lineTo(x(points[i].at), y(base[i] + (points[i].free ?? 0)));
                            ctx.closePath();
                            ctx.clip();
                            ctx.strokeStyle = ledger.hatchColor;
                            ctx.globalAlpha = 0.7;
                            for (let cx = plotLeft - plotHeight; cx < plotLeft + plotWidth; cx += 7) {
                                ctx.beginPath();
                                ctx.moveTo(cx, plotBottom);
                                ctx.lineTo(cx + plotHeight, 4);
                                ctx.stroke();
                            }
                            ctx.restore();
                            const targetLine = y(ledger.diskTotal - ledger.target);
                            ctx.strokeStyle = Colours.palette.m3error;
                            ctx.lineWidth = 2;
                            ctx.setLineDash([5, 4]);
                            ctx.beginPath();
                            ctx.moveTo(plotLeft, targetLine);
                            ctx.lineTo(plotLeft + plotWidth, targetLine);
                            ctx.stroke();
                            ctx.setLineDash([]);
                            ctx.lineWidth = 1;
                        }
                        history.runXs = [];
                        for (const run of root.runs) {
                            const start = run.events[0].at;
                            const end = run.events[run.events.length - 1].at + (run.events[run.events.length - 1].seconds ?? 0);
                            if (end < first || start > last)
                                continue;
                            const from = x(Math.max(first, start));
                            const to = Math.max(from + 1.5, x(Math.min(last, end)));
                            history.runXs.push({ from: from, to: to, run: run });
                            ctx.fillStyle = Colours.palette.m3tertiary;
                            ctx.globalAlpha = 0.18;
                            ctx.fillRect(from, 4, to - from, plotBottom - 4);
                            ctx.globalAlpha = 1;
                        }
                        if (root.focusEvent) {
                            const events = root.focusEvent.events;
                            const from = x(events[0].at);
                            const to = Math.max(from + 2, x(events[events.length - 1].at));
                            ctx.fillStyle = Colours.palette.m3tertiary;
                            ctx.globalAlpha = 0.4;
                            ctx.fillRect(from, 4, to - from, plotBottom - 4);
                            ctx.globalAlpha = 1;
                        }
                        if (reclaims.hoveredEvent && reclaims.hoveredEvent.at >= first && reclaims.hoveredEvent.at <= last) {
                            ctx.strokeStyle = Colours.palette.m3tertiary;
                            ctx.lineWidth = 2;
                            ctx.beginPath();
                            ctx.moveTo(x(reclaims.hoveredEvent.at), plotBottom);
                            ctx.lineTo(x(reclaims.hoveredEvent.at), 4);
                            ctx.stroke();
                            ctx.lineWidth = 1;
                        }
                        if (history.dragFrom >= 0 && history.dragTo >= 0) {
                            ctx.fillStyle = Colours.palette.m3primary;
                            ctx.globalAlpha = 0.2;
                            ctx.fillRect(Math.min(history.dragFrom, history.dragTo), 4, Math.abs(history.dragTo - history.dragFrom), plotBottom - 4);
                            ctx.globalAlpha = 1;
                        }
                        ctx.restore();
                        ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
                        ctx.font = "10px sans-serif";
                        ctx.textAlign = "right";
                        for (let step = 0; step <= 4; step++) {
                            const bytes = low + (top - low) * step / 4;
                            ctx.fillText(ledger.gib(bytes).replace(" GiB", "G").replace(" MiB", "M"), plotLeft - 4, y(bytes) + 3);
                        }
                        const labels = Math.min(6, points.length);
                        for (let step = 0; step < labels; step++) {
                            const at = first + spanSeconds * step / Math.max(1, labels - 1);
                            ctx.textAlign = step === 0 ? "left" : step === labels - 1 ? "right" : "center";
                            ctx.fillText(ledger.axisLabel(at, spanSeconds), x(at), height - 4);
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.CrossCursor

                        onPressed: mouse => {
                            history.dragFrom = mouse.x;
                            history.dragTo = mouse.x;
                        }
                        onPositionChanged: mouse => {
                            if (pressed) {
                                history.dragTo = mouse.x;
                                history.requestPaint();
                                return;
                            }
                            const run = history.runNear(mouse.x);
                            const band = run ? null : history.bandAt(mouse.x, mouse.y);
                            const key = band && band.key && !root.focusNode ? band.key : "";
                            const event = history.eventNear(run, mouse.x);
                            const point = history.pointAt(mouse.x);
                            if (history.hoverPoint !== point)
                                history.hoverPoint = point;
                            history.hoverKey = band && band.key ? band.key : "";
                            if (reclaims.hoveredEvent !== event)
                                reclaims.hoveredEvent = event;
                            if (bar.hovered !== key)
                                bar.hovered = key;
                        }
                        onExited: {
                            history.hoverPoint = null;
                            history.hoverKey = "";
                            reclaims.hoveredEvent = null;
                            bar.hovered = "";
                        }
                        onReleased: mouse => {
                            const moved = Math.abs(history.dragTo - history.dragFrom) > 6;
                            if (moved) {
                                const a = history.timeAt(Math.min(history.dragFrom, history.dragTo));
                                const b = history.timeAt(Math.max(history.dragFrom, history.dragTo));
                                root.range = [a, b];
                            } else {
                                const run = history.runNear(mouse.x);
                                const band = run ? null : history.bandAt(mouse.x, mouse.y);
                                if (run)
                                    root.focusEvent = root.focusEvent === run ? null : run;
                                else if (band && band.key)
                                    root.pick(band.key);
                            }
                            history.dragFrom = -1;
                            history.dragTo = -1;
                            history.requestPaint();
                        }
                        onDoubleClicked: root.range = null
                    }
                }

                Item {
                    id: brush

                    implicitWidth: history.implicitWidth
                    implicitHeight: 16

                    property string mode: ""
                    property real pressX: 0
                    property var pressRange: null

                    function xOf(at: real): real {
                        const [first, last] = root.fullSpan;
                        return history.plotLeft + history.plotWidth * (at - first) / Math.max(1, last - first);
                    }

                    function atOf(px: real): real {
                        const [first, last] = root.fullSpan;
                        return first + (last - first) * Math.max(0, Math.min(1, (px - history.plotLeft) / history.plotWidth));
                    }

                    Rectangle {
                        x: history.plotLeft
                        width: history.plotWidth
                        height: 6
                        anchors.verticalCenter: parent.verticalCenter
                        color: Colours.tPalette.m3surfaceContainerHigh
                    }

                    Repeater {
                        model: ledger.events.filter(event => event.freed > 0)

                        delegate: Rectangle {
                            required property var modelData

                            x: brush.xOf(modelData.at)
                            width: 1
                            height: 6
                            anchors.verticalCenter: parent.verticalCenter
                            color: Colours.palette.m3tertiary
                        }
                    }

                    Rectangle {
                        id: window

                        x: brush.xOf(root.span[0])
                        width: Math.max(4, brush.xOf(root.span[1]) - x)
                        height: parent.height
                        color: Qt.alpha(Colours.palette.m3primary, 0.25)
                        border.width: 1
                        border.color: Colours.palette.m3primary

                        Rectangle {
                            width: 3
                            height: parent.height
                            color: Colours.palette.m3primary
                        }

                        Rectangle {
                            width: 3
                            height: parent.height
                            anchors.right: parent.right
                            color: Colours.palette.m3primary
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: {
                            const px = mouseX;
                            if (Math.abs(px - window.x) < 7 || Math.abs(px - window.x - window.width) < 7)
                                return Qt.SizeHorCursor;
                            return px > window.x && px < window.x + window.width ? Qt.OpenHandCursor : Qt.CrossCursor;
                        }
                        onPressed: mouse => {
                            brush.pressX = mouse.x;
                            brush.pressRange = root.span.slice();
                            const left = window.x;
                            const right = window.x + window.width;
                            if (Math.abs(mouse.x - left) < 7)
                                brush.mode = "from";
                            else if (Math.abs(mouse.x - right) < 7)
                                brush.mode = "to";
                            else if (mouse.x > left && mouse.x < right)
                                brush.mode = "pan";
                            else
                                brush.mode = "new";
                        }
                        onPositionChanged: mouse => {
                            if (!pressed)
                                return;
                            const at = brush.atOf(mouse.x);
                            const [first, last] = brush.pressRange;
                            const [fullFirst, fullLast] = root.fullSpan;
                            if (brush.mode === "from")
                                root.setRange(at, last);
                            else if (brush.mode === "to")
                                root.setRange(first, at);
                            else if (brush.mode === "pan") {
                                const span = last - first;
                                const shift = at - brush.atOf(brush.pressX);
                                const from = Math.max(fullFirst, Math.min(first + shift, fullLast - span));
                                root.range = [from, from + span];
                            } else {
                                const origin = brush.atOf(brush.pressX);
                                root.setRange(Math.min(origin, at), Math.max(origin, at));
                            }
                        }
                        onReleased: brush.mode = ""
                        onDoubleClicked: root.range = null
                    }
                }

                Flow {
                    Layout.preferredWidth: history.implicitWidth
                    visible: history.hoverPoint !== null
                    spacing: Tokens.spacing.small

                    StyledText {
                        text: history.hoverPoint ? ledger.clock(history.hoverPoint.at) : ""
                        font: Tokens.font.body.small
                        color: Colours.palette.m3primary
                    }

                    Repeater {
                        model: {
                            const point = history.hoverPoint;
                            if (!point)
                                return [];
                            const focus = root.focusNode;
                            if (focus && !focus.id.startsWith("segment:"))
                                return [{ key: "", label: focus.label, color: Colours.palette.m3primary, size: root.nodeValue(point, focus), bold: true }];
                            const rows = ledger.segments.filter(item => !focus || item.key === focus.segment).map(item => ({ key: item.key, label: item.label, color: item.color, size: ledger.valueOf(point, item.key), bold: item.key === history.hoverKey || (focus && focus.segment === item.key) })).filter(row => row.size > 0);
                            return focus ? rows : rows.concat([{ key: "free", label: "free", color: "transparent", size: point.free ?? 0, bold: false, free: true }]);
                        }

                        RowLayout {
                            id: sliceRow

                            required property var modelData

                            spacing: 3

                            Rectangle {
                                implicitWidth: sliceRow.modelData.free ? 9 : 7
                                implicitHeight: implicitWidth
                                radius: 2
                                color: sliceRow.modelData.color

                                Outline {
                                    visible: sliceRow.modelData.free === true
                                    hatched: true
                                    lineWidth: 1
                                    color: ledger.hatchColor
                                }
                            }

                            StyledText {
                                text: `${sliceRow.modelData.label} ${isFinite(sliceRow.modelData.size) ? ledger.gib(sliceRow.modelData.size) : "?"}`
                                font.pointSize: Tokens.font.body.small.pointSize
                                font.family: Tokens.font.body.small.family
                                font.bold: sliceRow.modelData.bold
                                color: sliceRow.modelData.bold ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                spacing: Tokens.spacing.extraSmall

                StyledText {
                    Layout.maximumWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    text: root.focusNode ? `collection rate from ${root.focusNode.label}` : "collection rate"
                    font: Tokens.font.title.small
                    color: Colours.palette.m3primary
                    elide: Text.ElideMiddle
                }

                Canvas {
                    id: reclaims

                    implicitWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    implicitHeight: root.chartHeight

                    property var points: []
                    property var hoveredEvent: null
                    property real dragFrom: -1
                    property real dragTo: -1
                    readonly property real plotLeft: 44
                    readonly property real plotWidth: width - plotLeft - 4

                    onHoveredEventChanged: {
                        reclaims.requestPaint();
                        history.requestPaint();
                    }

                    function stageLit(key: string): bool {
                        return bar.hovered === key || root.focusSegment === key;
                    }

                    function xOf(at: real): real {
                        const [first, last] = root.span;
                        return reclaims.plotLeft + reclaims.plotWidth * (at - first) / Math.max(1, last - first);
                    }

                    function atOf(px: real): real {
                        const [first, last] = root.span;
                        return first + (last - first) * Math.max(0, Math.min(1, (px - reclaims.plotLeft) / reclaims.plotWidth));
                    }

                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.reset();
                        const [first, last] = root.span;
                        const bottom = height - 16;
                        const plotHeight = bottom - 6;
                        ctx.font = "10px sans-serif";
                        const events = ledger.events.filter(event => event.at >= first && event.at <= last).map(event => ({ event: event, amount: root.eventAmount(event) })).filter(entry => entry.amount !== null && entry.amount > 0);
                        const stages = [];
                        for (const entry of events)
                            if (!stages.includes(entry.event.segment))
                                stages.push(entry.event.segment);
                        const bins = Math.max(12, Math.min(96, Math.round(reclaims.plotWidth / 6)));
                        const binSeconds = Math.max(60, (last - first) / bins);
                        const rates = Array.from({ length: bins }, () => ({}));
                        for (const entry of events) {
                            const index = Math.min(bins - 1, Math.max(0, Math.floor((entry.event.at - first) / binSeconds)));
                            rates[index][entry.event.segment] = (rates[index][entry.event.segment] ?? 0) + entry.amount * 3600 / binSeconds;
                        }
                        const steps = events.map(entry => ({ at: entry.event.at, event: entry.event }));
                        reclaims.points = steps.map(step => ({ x: reclaims.xOf(step.at), event: step.event }));
                        const peak = Math.max(268435456, ...rates.map(bin => Object.values(bin).reduce((a, b) => a + b, 0)));
                        const y = bytes => bottom - plotHeight * bytes / peak;
                        const right = reclaims.plotLeft + reclaims.plotWidth;
                        ctx.strokeStyle = Colours.palette.m3outlineVariant;
                        ctx.lineWidth = 1;
                        ctx.beginPath();
                        ctx.moveTo(reclaims.plotLeft, bottom + 0.5);
                        ctx.lineTo(right, bottom + 0.5);
                        ctx.stroke();
                        if (root.focusEvent) {
                            const events = root.focusEvent.events;
                            const from = reclaims.xOf(events[0].at);
                            const to = reclaims.xOf(events[events.length - 1].at);
                            ctx.fillStyle = Qt.alpha(Colours.palette.m3primary, 0.15);
                            ctx.fillRect(Math.min(from, to) - 2, 6, Math.abs(to - from) + 4, plotHeight);
                        }
                        const anyLit = bar.hovered !== "" || root.trail.length > 0;
                        const barWidth = reclaims.plotWidth / bins;
                        rates.forEach((bin, index) => {
                            let below = 0;
                            const x = reclaims.plotLeft + barWidth * index;
                            for (const stage of stages) {
                                const value = bin[stage] ?? 0;
                                if (value <= 0)
                                    continue;
                                ctx.fillStyle = root.segmentColor(stage);
                                ctx.globalAlpha = !anyLit || reclaims.stageLit(stage) ? 0.85 : 0.3;
                                ctx.fillRect(x + 0.5, y(below + value), Math.max(1, barWidth - 1), y(below) - y(below + value));
                                below += value;
                            }
                        });
                        ctx.globalAlpha = 1;
                        for (const step of steps)
                            if (step.event.status !== 0) {
                                ctx.fillStyle = Colours.palette.m3error;
                                ctx.fillRect(reclaims.xOf(step.at) - 1, bottom - 4, 3, 4);
                            }
                        if (reclaims.dragFrom >= 0) {
                            ctx.fillStyle = Qt.alpha(Colours.palette.m3primary, 0.25);
                            ctx.fillRect(Math.min(reclaims.dragFrom, reclaims.dragTo), 6, Math.abs(reclaims.dragTo - reclaims.dragFrom), plotHeight);
                        }
                        if (reclaims.hoveredEvent) {
                            const x = reclaims.xOf(reclaims.hoveredEvent.at);
                            ctx.strokeStyle = Colours.palette.m3onSurface;
                            ctx.beginPath();
                            ctx.moveTo(x + 0.5, 6);
                            ctx.lineTo(x + 0.5, bottom);
                            ctx.stroke();
                        }
                        ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
                        ctx.textAlign = "right";
                        for (let step = 0; step <= 2; step++) {
                            const bytes = peak * step / 2;
                            ctx.fillText(ledger.gib(bytes).replace(" GiB", "G").replace(" MiB", "M") + "/h", reclaims.plotLeft - 4, y(bytes) + 3);
                        }
                        ctx.textAlign = "center";
                        for (let tick = 0; tick <= 3; tick++) {
                            const at = first + (last - first) * tick / 3;
                            ctx.textAlign = tick === 0 ? "left" : tick === 3 ? "right" : "center";
                            ctx.fillText(ledger.axisLabel(at, last - first), reclaims.xOf(at), height - 4);
                        }
                        if (steps.length === 0) {
                            ctx.textAlign = "center";
                            ctx.fillText("nothing collected in this window", reclaims.plotLeft + reclaims.plotWidth / 2, bottom - plotHeight / 2);
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: reclaims.hoveredEvent ? Qt.PointingHandCursor : Qt.CrossCursor

                        function nearest(px: real): var {
                            let best = null;
                            for (const point of reclaims.points)
                                if (Math.abs(point.x - px) <= 8 && (!best || Math.abs(point.x - px) < Math.abs(best.x - px)))
                                    best = point;
                            return best ? best.event : null;
                        }

                        onPressed: mouse => {
                            reclaims.dragFrom = mouse.x;
                            reclaims.dragTo = mouse.x;
                        }
                        onPositionChanged: mouse => {
                            if (pressed) {
                                reclaims.dragTo = mouse.x;
                                reclaims.requestPaint();
                                return;
                            }
                            const event = nearest(mouse.x);
                            if (reclaims.hoveredEvent !== event)
                                reclaims.hoveredEvent = event;
                            const key = event ? event.segment : "";
                            if (bar.hovered !== key)
                                bar.hovered = key;
                        }
                        onExited: {
                            reclaims.hoveredEvent = null;
                            bar.hovered = "";
                        }
                        onReleased: mouse => {
                            const from = Math.min(reclaims.dragFrom, mouse.x);
                            const to = Math.max(reclaims.dragFrom, mouse.x);
                            reclaims.dragFrom = -1;
                            reclaims.dragTo = -1;
                            if (to - from > 4) {
                                const [start, end] = [reclaims.atOf(from), reclaims.atOf(to)];
                                const events = ledger.events.filter(event => event.at >= start && event.at <= end && root.eventAmount(event) !== null);
                                root.focusEvent = events.length ? root.runFrom(events) : null;
                            } else {
                                const event = nearest(mouse.x);
                                root.focusEvent = event && !(root.focusEvent && root.focusEvent.events.length === 1 && root.focusEvent.events[0] === event) ? root.runFrom([event]) : null;
                            }
                            reclaims.requestPaint();
                        }
                    }
                }

                Facts {
                    Layout.preferredWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    item: {
                        const event = reclaims.hoveredEvent;
                        if (!event)
                            return null;
                        const taken = Object.entries(event.taken ?? ({})).sort((a, b) => b[1] - a[1]).slice(0, 3);
                        return {
                            label: ledger.clock(event.at),
                            path: "",
                            size: root.eventAmount(event) ?? 0,
                            last_used: event.newest ?? 0,
                            kind: root.segmentLabel(event.segment),
                            extra: [["paths", String(event.items ?? 0)], ["duration", `${event.seconds} s`], ["free before", `${event.free_gib} GiB`]].concat(event.refused ? [["held", String(event.refused)]] : []).concat(event.status !== 0 ? [["status", "failed"]] : []).concat(taken.map(([path, size]) => ["", `${ledger.shortName(path).replace(/^.*\//, "")} ${ledger.gib(size)}`]))
                        };
                    }
                    fallback: root.focusEvent ? [["selected", `${root.focusEvent.events.length} collections`], ["freed", ledger.gib(root.focusEvent.freed)], ["paths", String(root.focusEvent.items)]] : [["", "drag to select a window, click a step for its paths"]]
                }
            }
        }
    }

    component Facts: Flow {
        id: facts

        property var item: null
        property var fallback: []

        readonly property var pairs: {
            if (!item)
                return fallback;
            const out = [];
            out.push(["", item.path ? ledger.shortName(item.path) : item.label]);
            out.push(["size", ledger.gib(item.size)]);
            if (item.last_used)
                out.push(["last used", ledger.ago(item.last_used)]);
            if (item.kind)
                out.push(["", item.kind]);
            for (const link of item.roots ?? [])
                out.push(["held by", ledger.shortName(link)]);
            if (item.scheduled)
                out.push(["", "next collection"]);
            return out.concat(item.extra ?? []);
        }

        spacing: Tokens.spacing.medium

        Repeater {
            model: facts.pairs

            delegate: Row {
                id: fact

                required property var modelData

                spacing: Tokens.spacing.extraSmall

                StyledText {
                    visible: fact.modelData[0] !== ""
                    text: fact.modelData[0]
                    font: Tokens.font.body.small
                    color: Colours.palette.m3onSurfaceVariant
                }

                StyledText {
                    text: fact.modelData[1]
                    font: Tokens.font.body.builders.small.weight(Font.DemiBold).build()
                    color: Colours.palette.m3onSurface
                }
            }
        }
    }
}
