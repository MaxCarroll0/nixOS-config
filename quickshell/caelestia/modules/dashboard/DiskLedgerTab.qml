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

    property var trail: DiskSnapshot.model ? DiskSnapshot.trail : []

    Component.onDestruction: DiskSnapshot.trail = root.trail
    readonly property var node: trail.length ? trail[trail.length - 1] : null
    readonly property real paneWidth: 1160
    readonly property real chartHeight: 150
    readonly property var everShown: ({})
    readonly property var shownSegments: {
        const shown = ledger.segments.filter(segment => segment.bytes > 0 || root.everShown[segment.key]);
        for (const segment of shown)
            root.everShown[segment.key] = true;
        return shown;
    }
    readonly property var rootRows: ledger.segments.filter(segment => segment.bytes > 0).map(segment => segmentNode(segment))
    property var range: null
    readonly property real defaultSpan: 86400
    property var focusEvent: null
    readonly property var focusNode: !root.node ? null : root.node
    readonly property string focusSegment: root.trail.length ? root.trail[0].segment : ""
    readonly property bool collectable: !root.trail.length || root.trail[0].reclaimable
    readonly property real historyWidth: root.collectable ? root.paneWidth / 2 - Tokens.spacing.large / 2 : root.paneWidth
    readonly property var nodeRows: root.node ? (root.node.id.startsWith("group:") ? root.node.members : ledger.rows(root.node.id)) : null
    readonly property bool loading: (root.node !== null && root.nodeRows === null && !root.focusEvent) || (root.focusEvent !== null && ledger.rows(root.takenId) === null)
    readonly property string rateId: {
        const focus = root.focusNode;
        if (!focus || focus.id.startsWith("segment:") || !focus.path)
            return "";
        const first = ledger.events.find(event => event.at >= root.span[0]);
        return `rate:${first ? first.seq : ledger.nextSeq}:${focus.path}`;
    }
    readonly property var rateBySeq: {
        const out = {};
        for (const [seq, amount] of ledger.rows(root.rateId) ?? [])
            out[seq] = amount;
        return out;
    }
    readonly property string takenId: root.focusEvent ? `taken:${root.focusEvent.events[0].seq}:${root.focusEvent.events[root.focusEvent.events.length - 1].seq}` : ""
    readonly property bool takenGroup: root.focusEvent !== null && root.node !== null && root.node.id.startsWith("group:taken:")
    readonly property var entries: {
        if (root.focusEvent)
            return root.takenGroup ? root.node.members : root.takenRows(root.focusEvent);
        if (!root.node)
            return root.rootRows;
        const color = root.trail[0].color;
        return (root.nodeRows ?? []).filter(row => !row.missing).map(row => Object.assign({}, row, {
                color: color,
                segment: root.focusSegment
            }));
    }
    readonly property var span: {
        if (root.range !== null)
            return root.range;
        const points = ledger.history;
        const end = points.length ? points[points.length - 1].at : Date.now() / 1000;
        return [end - root.defaultSpan, end];
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
                out.push({
                    events: [event]
                });
        }
        return out.map(group => root.runFrom(group.events));
    }

    function runFrom(events: var): var {
        const run = {
            run: true,
            at: events[0].at,
            events: events,
            freed: 0,
            seconds: 0,
            items: 0,
            failed: false,
            free_gib: events[0].free_gib ?? 0
        };
        for (const event of events) {
            run.freed += Math.max(0, event.freed ?? 0);
            run.seconds += event.seconds ?? 0;
            run.items += event.items ?? 0;
            run.failed = run.failed || event.status !== 0;
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

    function panBy(fraction: real): void {
        const [from, to] = root.span;
        const length = to - from;
        const [first, last] = root.fullSpan;
        const start = Math.max(first, Math.min(last - length, from + fraction * length));
        root.range = start + length >= last && length === root.defaultSpan ? null : [start, start + length];
    }

    function setRange(from: real, to: real): void {
        if (isNaN(from) || isNaN(to))
            return;
        root.range = [Math.min(from, to - 60), Math.max(to, from + 60)];
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
                for (const path of row.paths ?? [row.path])
                    if (path && path in items) {
                        total += items[path];
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
        return root.rateBySeq[event.seq] ?? null;
    }

    readonly property var eventSummary: {
        const run = root.focusEvent;
        if (!run)
            return null;
        const seqs = new Set(run.events.map(event => event.seq));
        const entries = (ledger.rows(root.takenId) ?? []).filter(entry => seqs.has(entry.seq));
        const taken = root.entries.slice().sort((a, b) => b.size - a.size);
        const refusals = entries.reduce((acc, entry) => acc.concat(entry.refusals ?? []), []);
        const reasons = {};
        for (const refusal of refusals)
            reasons[refusal.reason] = (reasons[refusal.reason] ?? 0) + 1;
        const segments = {};
        for (const row of taken)
            segments[row.segment] = (segments[row.segment] ?? 0) + row.size;
        const extra = [["in", Object.keys(segments).sort((a, b) => segments[b] - segments[a]).map(key => `${root.segmentLabel(key)} ${ledger.gib(segments[key])}`).join(", ")]];
        if (refusals.length)
            extra.push(["refused", Object.keys(reasons).map(reason => `${reasons[reason]} ${reason}`).join(", ")]);
        for (const row of taken.slice(0, 12))
            extra.push([ledger.gib(row.size), row.label, {
                    path: row.path
                }]);
        if (taken.length > 12)
            extra.push(["", `and ${taken.length - 12} more, hover the bar`]);
        return {
            label: `${run.events.length > 1 ? `${run.events.length} collections` : "collection"} at ${ledger.clock(run.at)}`,
            size: run.freed,
            kind: `${taken.length} paths freed in ${Math.round(run.seconds * 10) / 10}s${run.failed ? ", with failures" : ""}`,
            extra: extra
        };
    }

    function takenRows(run: var): var {
        const out = [];
        const bySeq = {};
        for (const event of run.events)
            bySeq[event.seq] = event;
        for (const entry of ledger.rows(root.takenId) ?? []) {
            const event = bySeq[entry.seq];
            if (!event)
                continue;
            const taken = entry.taken;
            for (const key of Object.keys(taken))
                out.push({
                    id: `taken:${event.seq}:${key}`,
                    label: ledger.shortName(key),
                    path: key,
                    size: taken[key],
                    last_used: 0,
                    color: root.segmentColor(event.segment),
                    segment: event.segment,
                    kind: `collected ${root.segmentLabel(event.segment)}`,
                    delvable: false,
                    openable: false,
                    reclaimable: true,
                    scheduled: false
                });
        }
        return out;
    }

    function segmentNode(segment: var): var {
        return {
            id: `segment:${segment.key}`,
            label: segment.label,
            path: "",
            size: segment.bytes,
            last_used: 0,
            color: segment.color,
            kind: segment.reclaim ? `${segment.items} reclaimable items` : "segment",
            segment: segment.key,
            delvable: true,
            openable: false,
            reclaimable: segment.reclaim,
            weight: segment.weight,
            scheduled: segment.scheduled > 0,
            scheduledBytes: segment.scheduled,
            reclaimBytes: segment.reclaimBytes,
            reclaimSpans: segment.spans,
            scheduledSpans: segment.scheduledSpans
        };
    }

    function pick(key: string): void {
        const segment = ledger.segment(key);
        if (root.focusSegment === key && root.trail.length === 1)
            root.trail = [];
        else if (segment)
            root.trail = [root.segmentNode(segment)];
    }

    function delve(row: var): void {
        if (row.delvable)
            root.trail = root.trail.concat([row]);
        else if (row.openable)
            ledger.open(row.path);
    }

    function jumpTo(path: string): void {
        const area = path.startsWith("/tmp/") ? "temp" : path.startsWith("/home/") ? "home_files" : "system_files";
        const segment = ledger.segment(area);
        if (!segment || path.startsWith("/nix/store/"))
            return;
        const parts = path.split("/").filter(part => part);
        const trail = [root.segmentNode(segment)];
        for (let depth = area === "system_files" ? 1 : 2; depth < parts.length; depth++) {
            const directory = "/" + parts.slice(0, depth).join("/");
            trail.push({
                id: `dir:files:${directory}`,
                label: parts[depth - 1],
                path: directory,
                size: 0,
                last_used: 0,
                kind: "directory",
                delvable: true,
                openable: true,
                reclaimable: false
            });
        }
        root.trail = trail;
    }

    function follow(action: var): void {
        if (action.pid)
            ledger.focusWindow(action.pid);
        else if (action.path)
            root.jumpTo(action.path);
    }

    function repaint(): void {
        history.requestPaint();
        reclaims.requestPaint();
    }

    FontMetrics {
        id: smallLine

        font: Tokens.font.body.small
    }

    DiskLedgerModel {
        id: ledger

        keepsSnapshot: true

        drill: root.trail.filter(node => !node.id.startsWith("group:")).map(node => ({
                    id: node.id,
                    slots: Math.floor(root.paneWidth / slices.minSlice),
                    total: node.size ?? 0
                }))
        extra: [root.rateId, root.takenId].filter(id => id !== "")
        onNodesChanged: reclaims.requestPaint()
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
        root.repaint();
    }
    onRangeChanged: root.repaint()
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
                Layout.preferredWidth: 240
                text: ledger.loaded ? `${ledger.gib(ledger.free)} free of ${ledger.gib(ledger.diskTotal)}` : "No ledger yet"
                font: Tokens.font.title.medium
                color: ledger.deficit > 0 ? Colours.palette.m3error : Colours.palette.m3onSurface
            }

            StyledText {
                Layout.preferredWidth: 220
                text: ledger.collectingText
                font: Tokens.font.body.medium
                color: Colours.palette.m3tertiary
                elide: Text.ElideRight
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
                onClicked: ledger.proposeTarget(ledger.targetGib - 5)
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
                onAccepted: ledger.proposeTarget(parseInt(text))
                onActiveFocusChanged: if (!activeFocus)
                    text = String(ledger.targetGib)

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
                onClicked: ledger.proposeTarget(ledger.targetGib + 5)
            }

            IconButton {
                visible: ledger.targetPending
                icon: "check"
                type: IconButton.Tonal
                onClicked: ledger.applyTarget()
            }

            IconButton {
                visible: ledger.targetPending
                icon: "close"
                type: IconButton.Text
                onClicked: ledger.pendingTarget = 0
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
            id: legends

            property real tallest: 0

            Layout.preferredWidth: root.paneWidth
            Layout.preferredHeight: tallest
            spacing: Tokens.spacing.medium
            onImplicitHeightChanged: tallest = Math.max(tallest, implicitHeight)

            Repeater {
                model: root.shownSegments.length

                delegate: Item {
                    id: legend

                    required property int index
                    readonly property var modelData: root.shownSegments[index] ?? ({})

                    readonly property bool lit: bar.hovered === legend.modelData.key || (root.trail.length > 0 && root.trail[0].segment === legend.modelData.key)

                    TextMetrics {
                        id: boldMetrics

                        font: Tokens.font.body.builders.small.weight(Font.DemiBold).build()
                        text: `${legend.modelData.label} 8888 KiB`
                    }

                    implicitWidth: Math.ceil((12 + Tokens.spacing.extraSmall + boldMetrics.width) / 24) * 24
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
                                opacity: ledger.weightOpacity(legend.modelData.weight)
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
                        onExited: if (bar.hovered === legend.modelData.key)
                            bar.hovered = ""
                        onClicked: root.pick(legend.modelData.key)
                    }
                }
            }

            Repeater {
                model: [
                    {
                        label: `free ${ledger.gib(ledger.free)}`,
                        scheduled: false,
                        free: true
                    },
                    {
                        label: "can be reclaimed",
                        scheduled: false,
                        free: false
                    },
                    {
                        label: "collecting",
                        scheduled: true,
                        free: false
                    },
                    {
                        label: "next collection",
                        pointer: true,
                        scheduled: false,
                        free: false
                    }
                ].filter(entry => entry.scheduled ? ledger.due : entry.pointer ? ledger.head !== null : true)

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

                        ReclaimBoxes {
                            anchors.fill: parent
                            visible: !key.modelData.free && !key.modelData.pointer
                            spans: [{ x: 0, w: width }]
                            color: key.modelData.scheduled ? ledger.scheduledColor : ledger.reclaimColor
                        }

                        Pointers {
                            anchors.fill: parent
                            visible: key.modelData.pointer === true
                            size: 5
                            barHeight: 0
                            marks: [{ x: 1, w: 10 }]
                            color: ledger.deletingColor
                        }

                        Outline {
                            visible: key.modelData.free
                            hatched: true
                            color: ledger.hatchColor
                            lineWidth: 1
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
            Layout.preferredHeight: smallLine.height
            color: bar.hoveredScheduled?.next ? ledger.deletingColor : ledger.scheduledColor
            text: !bar.hoveredScheduled ? "" : bar.hoveredScheduled.next ? (ledger.head ? `next collection: ${ledger.head.label}, ${ledger.gib(ledger.head.size)}` : "") : `collecting: ${ledger.gib(bar.hoveredScheduled.bytes)} of ${bar.hoveredScheduled.label}`
            font: Tokens.font.body.small
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
                font: root.trail.length === 0 ? Tokens.font.title.small : Tokens.font.body.medium
                color: Colours.palette.m3primary

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.trail = []
                }
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
            node: root.node && (!root.focusEvent || root.takenGroup) ? root.node.id : ""
            weight: root.trail.length && root.trail[0].reclaimable && !root.focusEvent ? root.trail[0].weight ?? -1 : -1
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
            Layout.preferredHeight: smallLine.height * (root.focusEvent ? 4 : 2) + Tokens.spacing.medium * (root.focusEvent ? 3 : 1)
            clip: true
            item: slices.hovered ?? (root.focusEvent ? root.eventSummary : root.node)
            onFollowed: action => root.follow(action)
            fallback: root.node ? [["items", String(root.focusEvent ? root.entries.length : ledger.count(root.node.id))]] : []
        }

        RowLayout {
            Layout.topMargin: Tokens.spacing.medium
            spacing: Tokens.spacing.large

            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                spacing: Tokens.spacing.extraSmall

                RowLayout {
                    Layout.preferredWidth: root.historyWidth
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
                        id: fromField

                        Layout.preferredWidth: 92
                        verticalPadding: 2
                        horizontalPadding: 6
                        radius: 4
                        font: Tokens.font.body.small
                        text: root.timeText(root.span[0])
                        onAccepted: root.setRange(root.parseTime(text, root.span[0]), root.span[1])
                        onActiveFocusChanged: if (!activeFocus)
                            text = root.timeText(root.span[0])

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
                        onActiveFocusChanged: if (!activeFocus)
                            text = root.timeText(root.span[1])

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

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: wheel => {
                            const dx = wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.angleDelta.x / 4;
                            wheel.accepted = dx !== 0;
                            if (dx !== 0)
                                root.panBy(-dx / Math.max(1, width));
                        }
                    }

                    implicitWidth: root.historyWidth
                    implicitHeight: root.chartHeight

                    property var layout: null
                    property var hoverPoint: null
                    property string hoverKey: ""
                    property var runXs: []

                    onHoverPointChanged: requestPaint()
                    onWidthChanged: requestPaint()
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

                    readonly property real plotLeft: 44
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
                        const top = auto;
                        const y = bytes => plotBottom - plotHeight * bytes / top;
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
                            bands.push({
                                key: item.key ?? "",
                                lows: lows,
                                highs: base.slice()
                            });
                        }
                        history.layout = {
                            xs: points.map(point => x(point.at)),
                            points: points,
                            bands: bands,
                            y: y,
                            top: top
                        };
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
                            const from = Math.floor(x(Math.max(first, start)));
                            const to = Math.max(from + 2, Math.ceil(x(Math.min(last, end))));
                            history.runXs.push({
                                from: from,
                                to: to,
                                run: run
                            });
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
                            const bytes = top * step / 4;
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
                                if (run) {
                                    root.focusEvent = root.focusEvent === run ? null : run;
                                    root.trail = [];
                                } else if (band && band.key)
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
                    property real tallest: smallLine.height * 3 + Tokens.spacing.small * 2

                    Layout.preferredWidth: history.implicitWidth
                    Layout.preferredHeight: tallest
                    onImplicitHeightChanged: tallest = Math.max(tallest, implicitHeight)
                    opacity: history.hoverPoint !== null ? 1 : 0
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
                                return [
                                    {
                                        key: "",
                                        label: focus.label,
                                        color: Colours.palette.m3primary,
                                        size: root.nodeValue(point, focus),
                                        bold: true
                                    }
                                ];
                            const rows = ledger.segments.filter(item => !focus || item.key === focus.segment).map(item => ({
                                        key: item.key,
                                        label: item.label,
                                        color: item.color,
                                        size: ledger.valueOf(point, item.key),
                                        bold: item.key === history.hoverKey || (focus && focus.segment === item.key)
                                    })).filter(row => row.size > 0);
                            return focus ? rows : rows.concat([
                                {
                                    key: "free",
                                    label: "free",
                                    color: "transparent",
                                    size: point.free ?? 0,
                                    bold: false,
                                    free: true
                                }
                            ]);
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
                visible: root.collectable
                spacing: Tokens.spacing.extraSmall

                StyledText {
                    Layout.maximumWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    text: (root.focusNode ? `collections from ${root.focusNode.label}` : "collections") + reclaims.zoom.map(level => ` › ${level.events.length} at ${ledger.clock(level.events[0].at)}`).join("")
                    font: Tokens.font.title.small
                    color: Colours.palette.m3primary
                    elide: Text.ElideMiddle

                    MouseArea {
                        anchors.fill: parent
                        enabled: reclaims.zoom.length > 0
                        cursorShape: Qt.PointingHandCursor
                        onClicked: reclaims.zoomOut()
                    }
                }

                Canvas {
                    id: reclaims

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: wheel => {
                            const dx = wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.angleDelta.x / 4;
                            wheel.accepted = dx !== 0;
                            if (dx !== 0)
                                root.panBy(-dx / Math.max(1, width));
                        }
                    }

                    implicitWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    implicitHeight: root.chartHeight

                    property var bars: []
                    property var zoom: []
                    property var hoveredEvent: null
                    property real dragFrom: -1
                    property real dragTo: -1
                    readonly property real plotLeft: 44
                    readonly property real plotWidth: width - plotLeft - 4
                    readonly property real barWidth: 4
                    readonly property real minGap: 6
                    readonly property real maxBar: 24

                    onZoomChanged: reclaims.requestPaint()
                    onHoveredEventChanged: {
                        reclaims.requestPaint();
                        history.requestPaint();
                    }

                    function stageLit(key: string): bool {
                        return bar.hovered === key || root.focusSegment === key;
                    }

                    function barAt(px: real): var {
                        const inside = reclaims.bars.find(item => px >= item.x && px < item.x + item.w);
                        if (inside)
                            return inside;
                        const left = reclaims.bars.filter(item => item.x + item.w <= px).reduce((best, item) => !best || item.x > best.x ? item : best, null);
                        const right = reclaims.bars.filter(item => item.x > px).reduce((best, item) => !best || item.x < best.x ? item : best, null);
                        const toLeft = left ? px - (left.x + left.w) : Infinity;
                        const toRight = right ? right.x - px : Infinity;
                        if (toLeft * 1.25 <= toRight)
                            return left;
                        if (toRight * 1.25 <= toLeft)
                            return right;
                        return null;
                    }

                    property bool zooming: false

                    Connections {
                        target: root

                        function onSpanChanged(): void {
                            if (!reclaims.zooming)
                                reclaims.zoom = [];
                        }
                    }

                    function zoomTo(range: var, stack: var): void {
                        reclaims.zooming = true;
                        root.range = range;
                        reclaims.zoom = stack;
                        reclaims.zooming = false;
                    }

                    function zoomOut(): void {
                        if (reclaims.zoom.length)
                            reclaims.zoomTo(reclaims.zoom[reclaims.zoom.length - 1].previous, reclaims.zoom.slice(0, -1));
                        root.focusEvent = null;
                    }

                    function zoomInto(item: var): void {
                        const events = item.entries.map(entry => entry.event);
                        const from = events[0].at;
                        const to = events[events.length - 1].at;
                        const pad = Math.max(30, (to - from) * 0.1);
                        reclaims.zoomTo([from - pad, to + pad], reclaims.zoom.concat([
                            {
                                events: events,
                                previous: root.range
                            }
                        ]));
                        root.focusEvent = root.runFrom(events);
                    }

                    function makeBar(entries: var, x: real, w: real): var {
                        return {
                            x: x,
                            w: w,
                            entries: entries,
                            total: entries.reduce((acc, entry) => acc + entry.amount, 0)
                        };
                    }

                    function layoutBars(entries: var, first: real, last: real): var {
                        if (entries.length === 0)
                            return [];
                        if (last <= first) {
                            const slots = Math.max(1, Math.floor(reclaims.plotWidth / reclaims.minGap));
                            const per = Math.ceil(entries.length / slots);
                            const count = Math.ceil(entries.length / per);
                            const step = reclaims.plotWidth / count;
                            const out = [];
                            for (let index = 0; index < count; index++)
                                out.push(reclaims.makeBar(entries.slice(index * per, (index + 1) * per), reclaims.plotLeft + index * step + Math.max(0, step - reclaims.maxBar) / 2, Math.min(reclaims.maxBar, Math.max(1, step - 1))));
                            return out;
                        }
                        const scale = reclaims.plotWidth / (last - first);
                        const groups = [];
                        for (const entry of entries) {
                            const x = Math.min(reclaims.plotLeft + reclaims.plotWidth - reclaims.barWidth, reclaims.plotLeft + (entry.event.at - first) * scale);
                            const tail = groups[groups.length - 1];
                            if (tail && x - tail.x < reclaims.minGap) {
                                tail.entries.push(entry);
                                tail.end = x;
                            } else
                                groups.push({
                                    x: x,
                                    end: x,
                                    entries: [entry]
                                });
                        }
                        return groups.map(group => reclaims.makeBar(group.entries, group.x, group.end - group.x + reclaims.barWidth));
                    }

                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.reset();
                        const [first, last] = root.span;
                        const bottom = height - 16;
                        const plotHeight = bottom - 6;
                        ctx.font = "10px sans-serif";
                        const entries = ledger.events.filter(event => event.at >= first && event.at <= last).map(event => ({
                                    event: event,
                                    amount: root.eventAmount(event)
                                })).filter(entry => entry.amount !== null && entry.amount > 0);
                        const bars = reclaims.layoutBars(entries, first, last);
                        reclaims.bars = bars;
                        const peak = Math.max(1048576, ...bars.map(item => item.total));
                        const y = bytes => bottom - plotHeight * bytes / peak;
                        const right = reclaims.plotLeft + reclaims.plotWidth;
                        ctx.strokeStyle = Colours.palette.m3outlineVariant;
                        ctx.lineWidth = 1;
                        ctx.beginPath();
                        ctx.moveTo(reclaims.plotLeft, bottom + 0.5);
                        ctx.lineTo(right, bottom + 0.5);
                        ctx.stroke();
                        const anyLit = bar.hovered !== "" || root.trail.length > 0;
                        const chosen = root.focusEvent ? new Set(root.focusEvent.events.map(event => event.seq)) : null;
                        for (const item of bars) {
                            const selected = chosen && item.entries.some(entry => chosen.has(entry.event.seq));
                            if (selected) {
                                ctx.fillStyle = Qt.alpha(Colours.palette.m3primary, 0.15);
                                ctx.fillRect(item.x, 6, item.w, plotHeight);
                            }
                            let below = 0;
                            for (const entry of item.entries) {
                                const top = Math.min(y(below + entry.amount), y(below) - 2);
                                ctx.fillStyle = root.segmentColor(entry.event.segment);
                                ctx.globalAlpha = !anyLit || reclaims.stageLit(entry.event.segment) ? 0.9 : 0.3;
                                ctx.fillRect(item.x + 0.5, top, Math.max(1, item.w - 1), y(below) - top);
                                below = bottom - top >= 2 ? below + entry.amount : peak * (bottom - top) / plotHeight;
                            }
                            ctx.globalAlpha = 1;
                            if (item.entries.some(entry => entry.event.status !== 0)) {
                                ctx.fillStyle = Colours.palette.m3error;
                                ctx.fillRect(item.x, bottom + 2, Math.max(2, item.w - 1), 3);
                            }
                            if (item.entries.length > 1 && item.w + 8 >= ctx.measureText(String(item.entries.length)).width) {
                                ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
                                ctx.textAlign = "center";
                                ctx.fillText(String(item.entries.length), item.x + item.w / 2, Math.max(14, y(item.total) - 3));
                            }
                            if (reclaims.hoveredEvent && item.entries.some(entry => entry.event === reclaims.hoveredEvent)) {
                                ctx.strokeStyle = Colours.palette.m3onSurface;
                                ctx.strokeRect(item.x + 0.5, y(item.total) - 1.5, Math.max(1, item.w - 1), bottom - y(item.total) + 1);
                            }
                        }
                        if (reclaims.dragFrom >= 0) {
                            ctx.fillStyle = Qt.alpha(Colours.palette.m3primary, 0.25);
                            ctx.fillRect(Math.min(reclaims.dragFrom, reclaims.dragTo), 6, Math.abs(reclaims.dragTo - reclaims.dragFrom), plotHeight);
                        }
                        ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
                        ctx.textAlign = "right";
                        for (let step = 0; step <= 2; step++) {
                            const bytes = peak * step / 2;
                            ctx.fillText(ledger.gib(bytes).replace(" GiB", "G").replace(" MiB", "M").replace(" KiB", "K"), reclaims.plotLeft - 4, y(bytes) + 3);
                        }
                        const labels = last > first ? Math.max(1, Math.min(4, Math.floor(reclaims.plotWidth / 90))) : 0;
                        const fine = last - first < 3600;
                        ctx.textAlign = "left";
                        for (let step = 0; step <= labels; step++) {
                            const at = first + (last - first) * step / labels;
                            const label = fine ? Qt.formatDateTime(new Date(at * 1000), "HH:mm:ss") : ledger.clock(at);
                            const width = ctx.measureText(label).width;
                            ctx.fillText(label, Math.min(Math.max(reclaims.plotLeft + reclaims.plotWidth * step / labels - width / 2, reclaims.plotLeft), right - width), height - 4);
                        }
                        if (bars.length === 0) {
                            ctx.textAlign = "center";
                            ctx.fillText("nothing collected in this window", reclaims.plotLeft + reclaims.plotWidth / 2, bottom - plotHeight / 2);
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: reclaims.hoveredEvent ? Qt.PointingHandCursor : Qt.CrossCursor

                        function nearest(px: real): var {
                            const item = reclaims.barAt(px);
                            if (!item)
                                return null;
                            return item.entries.reduce((best, entry) => !best || entry.amount > best.amount ? entry : best, null).event;
                        }

                        function eventsBetween(from: real, to: real): var {
                            return reclaims.bars.filter(item => item.x + item.w > from && item.x < to).reduce((acc, item) => acc.concat(item.entries.map(entry => entry.event)), []);
                        }

                        onPressed: mouse => {
                            if (mouse.button === Qt.RightButton) {
                                reclaims.zoomOut();
                                return;
                            }
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
                            if (mouse.button === Qt.RightButton)
                                return;
                            const from = Math.min(reclaims.dragFrom, mouse.x);
                            const to = Math.max(reclaims.dragFrom, mouse.x);
                            reclaims.dragFrom = -1;
                            reclaims.dragTo = -1;
                            if (to - from > 4) {
                                const events = eventsBetween(from, to);
                                root.focusEvent = events.length ? root.runFrom(events) : null;
                            } else {
                                const item = reclaims.barAt(mouse.x);
                                if (item && item.entries.length > 1) {
                                    reclaims.zoomInto(item);
                                    reclaims.requestPaint();
                                    return;
                                }
                                const events = item ? item.entries.map(entry => entry.event) : [];
                                const same = root.focusEvent && events.length && root.focusEvent.events.length === events.length && root.focusEvent.events.every((event, index) => event === events[index]);
                                root.focusEvent = events.length && !same ? root.runFrom(events) : null;
                            }
                            reclaims.requestPaint();
                        }
                    }
                }

                Facts {
                    Layout.preferredWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    Layout.preferredHeight: smallLine.height * 3 + Tokens.spacing.medium * 2
                    clip: true
                    item: {
                        const event = reclaims.hoveredEvent;
                        if (!event)
                            return null;
                        const taken = event.top ?? [];
                        return {
                            label: ledger.clock(event.at),
                            path: "",
                            size: root.eventAmount(event) ?? 0,
                            last_used: event.newest ?? 0,
                            kind: root.segmentLabel(event.segment),
                            extra: [["paths", String(event.items ?? 0)], ["duration", `${event.seconds} s`], ["free before", `${event.free_gib} GiB`]].concat(event.refused ? [["held", String(event.refused)]] : []).concat(event.status !== 0 ? [["status", "failed"]] : []).concat(taken.map(([path, size]) => ["", `${ledger.shortName(path).replace(/^.*\//, "")} ${ledger.gib(size)}`]))
                        };
                    }
                    fallback: root.focusEvent ? [["selected", `${root.focusEvent.events.length} collections`], ["freed", ledger.gib(root.focusEvent.freed)], ["paths", String(root.focusEvent.items)]] : []
                }
            }
        }
    }

    component Facts: Flow {
        id: facts

        property var item: null
        property var fallback: []
        signal followed(var action)

        readonly property var pairs: {
            if (!item)
                return fallback;
            const out = [];
            out.push(["", item.path ? ledger.shortName(item.path) : item.label]);
            out.push(["size", ledger.gib(item.size)]);
            if (item.last_used)
                out.push(["last used", ledger.ago(item.last_used)]);
            if (item.rank !== undefined)
                out.push(["rank", `#${item.rank + 1} to collect`]);
            else if (item.ranks)
                out.push(["ranks", `#${item.ranks[0] + 1} to #${item.ranks[1] + 1}`]);
            if (item.weight > 0)
                out.push(["weight", ledger.weightText(item.weight)]);
            if (item.kind)
                out.push(["", item.kind]);
            for (const link of item.roots ?? [])
                out.push(["held by", ledger.shortName(link), link.startsWith("/") && !link.startsWith("/proc/") ? {
                        path: link
                    } : null]);
            if (item.holder)
                out.push(["held by", item.holder, item.pid ? {
                        pid: item.pid
                    } : null]);
            if (item.scheduled)
                out.push(["", "next collection"]);
            return out.concat(item.extra ?? []);
        }

        spacing: Tokens.spacing.medium

        Repeater {
            model: facts.pairs.length

            delegate: Row {
                id: fact

                required property int index
                readonly property var modelData: facts.pairs[index] ?? ({})

                spacing: Tokens.spacing.extraSmall

                StyledText {
                    visible: fact.modelData[0] !== ""
                    text: fact.modelData[0]
                    font: Tokens.font.body.small
                    color: Colours.palette.m3onSurfaceVariant
                }

                StyledText {
                    readonly property var action: fact.modelData[2] ?? null

                    text: fact.modelData[1]
                    font: Tokens.font.body.builders.small.weight(Font.DemiBold).build()
                    color: action ? Colours.palette.m3primary : Colours.palette.m3onSurface

                    MouseArea {
                        anchors.fill: parent
                        enabled: parent.action !== null
                        cursorShape: Qt.PointingHandCursor
                        onClicked: facts.followed(parent.action)
                    }
                }
            }
        }
    }
}
