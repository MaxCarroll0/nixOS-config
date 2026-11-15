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

    property var trail: []
    property var entries: []
    property bool loading: false
    readonly property var node: trail.length ? trail[trail.length - 1] : null
    readonly property real paneWidth: 1160
    readonly property real chartHeight: 150
    readonly property var rootRows: ledger.segments.map(segment => segmentNode(segment)).filter(item => item.size > 0)
    property var range: null
    property var focusEvent: null
    readonly property var focusNode: !root.node ? null : (root.node.kind === "segment" || root.node.path) ? root.node : root.trail[0]
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
            const freed = Math.max(0, event.freed ?? 0);
            if (last && event.at - last.at < 900) {
                last.events.push(event);
                last.freed += freed;
                last.seconds += event.seconds ?? 0;
                last.items += event.items ?? 0;
                last.failed = last.failed || event.status !== 0;
                last.taken = Object.assign(last.taken, event.taken ?? ({}));
            } else
                out.push({ run: true, at: event.at, events: [event], freed: freed, seconds: event.seconds ?? 0, items: event.items ?? 0, failed: event.status !== 0, taken: Object.assign({}, event.taken ?? ({})), free_gib: event.free_gib ?? 0 });
        }
        return out;
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

    function runOf(event: var): var {
        return root.runs.find(run => run.events.includes(event)) ?? null;
    }

    function focused(event: var): bool {
        return root.focusEvent !== null && root.focusEvent.events.includes(event);
    }

    function runLabel(run: var): string {
        const names = [];
        for (const event of run.events) {
            const name = ledger.stageName(event.stage);
            if (!names.includes(name))
                names.push(name);
        }
        return names.join(", ");
    }

    function runAmount(run: var): var {
        let total = null;
        for (const event of run.events) {
            const amount = root.eventAmount(event);
            if (amount !== null)
                total = (total ?? 0) + amount;
        }
        return total;
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

    function nodeValue(point: var, node: var): real {
        if (node.kind === "segment")
            return ledger.valueOf(point, node.segment);
        const items = point.items ?? ({});
        if (!node.path)
            return 0;
        if (node.path in items)
            return items[node.path];
        let total = 0;
        for (const path in items)
            if (path.startsWith(node.path + "/"))
                total += items[path];
        return total;
    }

    function eventAmount(event: var): var {
        const focus = root.focusNode;
        if (!focus)
            return Math.max(0, event.freed ?? 0);
        const taken = event.taken ?? ({});
        if (focus.kind === "segment") {
            const stages = Object.keys(ledger.stageSegment).filter(stage => ledger.stageSegment[stage] === focus.segment || ((focus.segment.startsWith("project") || focus.segment === "fetched") && stage === "projects"));
            return stages.includes(event.stage) ? Math.max(0, event.freed ?? 0) : null;
        }
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

    DiskLedgerModel {
        id: ledger

        onLedgerChanged: {
            history.requestPaint();
            reclaims.requestPaint();
            Qt.callLater(root.refresh);
        }
        onTargetChanged: history.requestPaint()
    }

    DiskProbe {
        id: probe

        onResultsChanged: Qt.callLater(root.refresh)
        onCurrentChanged: Qt.callLater(root.refresh)
    }

    function scheduledFor(path: string): bool {
        return ledger.queue.some((row, index) => index <= ledger.cut && (row.path === path || path.startsWith(row.path + "/")));
    }

    function segmentNode(segment: var): var {
        const scheduled = ledger.segmentScheduled(segment.key);
        return { id: `segment:${segment.key}`, label: segment.label, path: "", size: ledger.current(segment.key), last_used: 0, color: segment.color, kind: "segment", segment: segment.key, delvable: segment.detail !== "none" || ["system", "home"].includes(segment.key), openable: false, reclaimable: segment.reclaim, scheduled: scheduled };
    }

    function dirNode(row: var, color: color, reclaimable: bool): var {
        const loose = row.path.endsWith("/*");
        return { id: `dir:${row.path}`, label: loose ? "files" : (ledger.shortName(row.path).replace(/^.*\//, "") || row.path), path: row.path, size: row.size, last_used: row.last_used ?? 0, color: color, kind: "directory", delvable: !loose, openable: !loose, reclaimable: reclaimable, scheduled: reclaimable && scheduledFor(row.path) };
    }

    function closureNode(row: var, color: color, label: string, kind: string, reclaimable: bool): var {
        return { id: `closure:${row.path}`, label: label, path: row.path, size: row.size, last_used: row.last_used ?? 0, color: color, kind: kind, delvable: true, openable: false, reclaimable: reclaimable, scheduled: reclaimable && scheduledFor(row.path), roots: row.roots ?? [] };
    }

    function childrenOf(node: var): var {
        const prov = ledger.provenance;
        const color = node.color;
        if (node.kind === "segment") {
            switch (node.segment) {
            case "home_files":
                return (prov.home ?? []).map(row => dirNode(row, color, false));
            case "caches":
                return (prov.caches ?? []).map(row => dirNode(row, color, true));
            case "system_files":
                return (prov.system ?? []).map(row => dirNode(row, color, false));
            case "held":
                return (prov.held ?? []).map(row => ({ id: `held:${row.path}`, label: ledger.shortName(row.path), path: row.path, size: row.size, last_used: row.last_used, color: color, kind: `deleted, held open by ${row.holders.join(", ")}`, delvable: false, openable: false, reclaimable: false, scheduled: false }));
            case "system_generations":
            case "home_generations":
                return (prov.generations ?? []).filter(row => row.profile.startsWith("system") === (node.segment === "system_generations")).map(row => Object.assign(closureNode(row, color, `${row.profile.replace(/.*\//, "")} ${row.number || ""}`.trim(), `generation, ${ledger.clock(row.last_used)}${row.expiring ? ", expiring" : ""}`, row.number > 0)));
            case "deployed":
                return (prov.deployed ?? []).map(row => closureNode(row, color, row.path.replace(/.*\//, ""), `deployed ${ledger.ago(row.last_used)}`, true));
            case "shells":
                return (prov.shells ?? []).map(row => closureNode(row, color, row.path.replace(/.*nix-shell-roots\//, "shell "), "live shell root", false));
            case "other":
                return (prov.other ?? []).map(row => closureNode(row, color, ledger.shortName(row.path), row.roots && row.roots.length === 1 ? `held by ${ledger.shortName(row.roots[0])}` : row.roots && row.roots.length ? `held by ${row.roots.length} roots` : "live, root unknown", false));
            case "system":
                return [closureNode({ path: "/run/current-system", size: node.size, last_used: 0 }, color, "current system", "closure", false)];
            case "home":
                return [closureNode({ path: `${ledger.home}/.local/state/nix/profiles/home-manager`, size: node.size, last_used: 0 }, color, "home-manager profile", "closure", false)];
            case "project_tier1":
            case "project_tier2":
            case "fetched": {
                const tier = { project_tier1: "1", project_tier2: "2", fetched: "3" }[node.segment];
                return (prov.projects ?? []).filter(row => (row.tiers ?? ({}))[tier] > 0).map(row => ({ id: `project:${row.path}`, label: ledger.shortName(row.path), path: row.path, size: row.tiers[tier], last_used: row.last_used, color: color, kind: `project, built ${ledger.ago(row.last_built)}`, delvable: true, openable: true, reclaimable: true, scheduled: scheduledFor(row.path), roots: row.roots, file: row.file ?? "", tier: parseInt(tier) }));
            }
            case "garbage":
                return probed(node, "dead", ledger.deadFile, rows => groupByDay(rows, color));
            default:
                return [];
            }
        }
        if (node.id.startsWith("project:"))
            return probed(node, "file", node.file, rows => rows.filter(row => row.tier === node.tier).map(row => ({ id: `path:${row.path}`, label: ledger.shortName(row.path), path: row.path, size: row.size, last_used: row.last_used, color: color, kind: row.kind, delvable: false, openable: false, reclaimable: true, scheduled: node.scheduled })));
        if (node.id.startsWith("group:"))
            return node.members;
        if (node.id.startsWith("day:"))
            return node.rows.map(row => ({ id: `dead:${row.path}`, label: ledger.shortName(row.path), path: row.path, size: row.size, last_used: row.last_used, color: color, kind: "dead path", delvable: false, openable: false, reclaimable: true, scheduled: node.scheduled }));
        if (node.id.startsWith("closure:"))
            return probed(node, "closure", node.path, rows => rows.map(row => ({ id: `path:${row.path}`, label: ledger.shortName(row.path), path: row.path, size: row.size, last_used: row.last_used, color: color, kind: "store path", delvable: false, openable: false, reclaimable: node.reclaimable, scheduled: node.scheduled })), root.trail.length ? ledger.segmentFile(root.trail[0].segment ?? "") : "");
        if (node.id.startsWith("dir:"))
            return probed(node, "dir", node.path, rows => rows.map(row => dirNode(row, color, node.reclaimable)));
        return [];
    }

    function probed(node: var, kind: string, path: string, build: var, extra: string): var {
        if (!probe.has(node.id)) {
            probe.request(node.id, kind, path, extra ?? "");
            return null;
        }
        return build(probe.results[node.id]);
    }

    function groupByDay(rows: var, color: color): var {
        const next = new Set(ledger.queue.filter((row, index) => index <= ledger.cut && row.stage === "store").map(row => row.path));
        const days = {};
        for (const row of rows) {
            const day = Qt.formatDateTime(new Date(row.last_used * 1000), "yyyy-MM-dd");
            const scheduled = next.has(row.path);
            const key = scheduled ? `${day} next` : day;
            const group = days[key] ?? (days[key] = { id: `day:${key}`, label: scheduled ? `${day}, next collection` : day, path: "", size: 0, last_used: row.last_used, color: color, kind: "day", delvable: true, openable: false, reclaimable: true, scheduled: scheduled, rows: [] });
            group.size += row.size;
            group.rows.push(row);
        }
        return Object.values(days).map(group => Object.assign(group, { kind: `${group.rows.length} dead paths`, extra: group.rows.slice().sort((a, b) => b.size - a.size).slice(0, 3).map(row => ["", `${ledger.shortName(row.path)} ${ledger.gib(row.size)}`]) }));
    }

    function refresh(): void {
        const node = root.trail.length ? root.trail[root.trail.length - 1] : null;
        if (root.focusEvent) {
            const entries = [];
            for (const event of root.focusEvent.events) {
                const taken = event.taken ?? ({});
                const color = ledger.stageColor(event.stage);
                for (const key of Object.keys(taken))
                    entries.push({ id: `taken:${event.stage}:${key}`, label: key.match(/^\d{4}-\d{2}-\d{2}$/) ? key : ledger.shortName(key).replace(/^.*\//, "") || key, path: key.startsWith("/") ? key : "", size: taken[key], last_used: 0, color: color, kind: ledger.stageName(event.stage), delvable: false, openable: key.startsWith("/") && !key.startsWith("/nix/store/"), reclaimable: true, scheduled: false });
            }
            root.entries = entries;
            root.loading = false;
            return;
        }
        if (!node) {
            root.entries = root.rootRows;
            root.loading = false;
            return;
        }
        const rows = childrenOf(node);
        root.loading = rows === null || probe.measuring(node.id);
        root.entries = rows ?? [];
    }

    function delve(row: var): void {
        if (row.delvable)
            root.trail = root.trail.concat([row]);
        else if (row.openable)
            ledger.open(row.path);
    }

    onTrailChanged: {
        bar.hovered = "";
        slices.hovered = null;
        if (root.trail.length)
            root.focusEvent = null;
        refresh();
        history.requestPaint();
        reclaims.requestPaint();
    }
    onRangeChanged: {
        history.requestPaint();
        reclaims.requestPaint();
    }
    onFocusEventChanged: {
        if (root.focusEvent)
            root.trail = [];
        refresh();
        reclaims.requestPaint();
    }
    Component.onCompleted: refresh()

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
                color: ledger.deficit > 0 ? Colours.palette.m3error : ledger.freeColor
            }

            StyledText {
                visible: ledger.collecting
                text: `collecting: ${ledger.collectingStage} ${Qt.formatDateTime(new Date(ledger.collectingSince * 1000), "HH:mm")}`
                font: Tokens.font.body.medium
                color: Colours.palette.m3tertiary
            }

            StyledText {
                visible: ledger.loaded
                text: ledger.clock(ledger.updated.getTime() / 1000)
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
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

            StyledText {
                text: `${ledger.targetGib} GiB`
                font: Tokens.font.body.builders.medium.weight(Font.DemiBold).build()
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
            onPicked: key => root.trail = [root.segmentNode(ledger.segment(key))]
        }

        Flow {
            Layout.preferredWidth: root.paneWidth
            spacing: Tokens.spacing.medium

            Repeater {
                model: ledger.segments

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
                            readonly property bool scheduled: ledger.segmentScheduled(legend.modelData.key)

                            visible: legend.modelData.reclaim
                            dashed: !scheduled
                            hatched: scheduled
                            color: scheduled ? ledger.scheduledColor : ledger.reclaimColor
                            lineWidth: scheduled ? 2 : 1.5
                        }
                    }

                    StyledText {
                        id: legendText

                        text: `${legend.modelData.label} ${ledger.gib(ledger.current(legend.modelData.key))}`
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
                model: [{ label: "can be reclaimed", scheduled: false }, { label: "next collection", scheduled: true }]

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
                            dashed: !key.modelData.scheduled
                            hatched: key.modelData.scheduled
                            color: key.modelData.scheduled ? ledger.scheduledColor : ledger.reclaimColor
                            lineWidth: key.modelData.scheduled ? 2 : 1.5
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
                        text: `${crumb.modelData.label} ${ledger.gib(crumb.modelData.size)}`
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
                text: "measuring…"
                font: Tokens.font.body.medium
                color: Colours.palette.m3tertiary
            }
        }

        ReclaimBar {
            id: slices

            capacity: root.node && !root.focusEvent ? root.node.size : 0

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
                    property var runXs: []
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
                        const points = root.visiblePoints;
                        history.layout = null;
                        if (points.length < 2)
                            return;
                        const plotHeight = plotBottom - 4;
                        const [first, last] = root.span;
                        const spanSeconds = Math.max(1, last - first);
                        const x = at => plotLeft + plotWidth * (at - first) / spanSeconds;
                        const focus = root.focusNode;
                        const series = focus ? [focus] : ledger.segments;
                        const valueFor = (point, item) => focus ? root.nodeValue(point, focus) : ledger.valueOf(point, item.key);
                        const top = focus ? Math.max(1, ...points.map(point => valueFor(point, focus))) * 1.1 : ledger.diskTotal;
                        const y = bytes => plotBottom - plotHeight * bytes / top;
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
                        history.layout = { xs: points.map(point => x(point.at)), bands: bands, y: y, top: top };
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
                            ctx.strokeStyle = "white";
                            ctx.globalAlpha = 0.7;
                            for (let cx = plotLeft - plotHeight; cx < plotLeft + plotWidth; cx += 7) {
                                ctx.beginPath();
                                ctx.moveTo(cx, plotBottom);
                                ctx.lineTo(cx + plotHeight, 4);
                                ctx.stroke();
                            }
                            ctx.restore();
                            const targetLine = y(top - ledger.target);
                            ctx.strokeStyle = Colours.palette.m3error;
                            ctx.setLineDash([4, 4]);
                            ctx.beginPath();
                            ctx.moveTo(plotLeft, targetLine);
                            ctx.lineTo(plotLeft + plotWidth, targetLine);
                            ctx.stroke();
                            ctx.setLineDash([]);
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
                            if (reclaims.hoveredEvent !== event)
                                reclaims.hoveredEvent = event;
                            if (bar.hovered !== key)
                                bar.hovered = key;
                        }
                        onExited: {
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
                                    root.trail = [root.segmentNode(ledger.segment(band.key))];
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
            }

            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                spacing: Tokens.spacing.extraSmall

                StyledText {
                    Layout.maximumWidth: root.paneWidth / 2 - Tokens.spacing.large / 2
                    text: root.focusNode ? `collected from ${root.focusNode.label}` : "collected"
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

                    function stageKey(stage: string): string {
                        return ledger.stageSegment[stage] ?? "garbage";
                    }

                    function stageLit(stage: string): bool {
                        const key = reclaims.stageKey(stage);
                        return bar.hovered === key || (root.trail.length > 0 && root.trail[0].segment === key) || (stage === "projects" && (bar.hovered.startsWith("project") || bar.hovered === "fetched"));
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
                            if (!stages.includes(entry.event.stage))
                                stages.push(entry.event.stage);
                        const totals = ({});
                        for (const stage of stages)
                            totals[stage] = 0;
                        const steps = events.map(entry => {
                            totals[entry.event.stage] += entry.amount;
                            return { at: entry.event.at, event: entry.event, totals: Object.assign({}, totals) };
                        });
                        reclaims.points = steps.map(step => ({ x: reclaims.xOf(step.at), event: step.event }));
                        const peak = Math.max(268435456, steps.length ? Object.values(steps[steps.length - 1].totals).reduce((a, b) => a + b, 0) : 0);
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
                        let below = steps.map(() => 0);
                        for (const stage of stages) {
                            const above = steps.map((step, index) => below[index] + step.totals[stage]);
                            ctx.beginPath();
                            ctx.moveTo(reclaims.plotLeft, bottom);
                            let previous = 0;
                            steps.forEach((step, index) => {
                                const x = reclaims.xOf(step.at);
                                ctx.lineTo(x, y(previous));
                                ctx.lineTo(x, y(above[index]));
                                previous = above[index];
                            });
                            ctx.lineTo(right, y(previous));
                            ctx.lineTo(right, y(below[below.length - 1] ?? 0));
                            for (let index = steps.length - 1; index >= 0; index--) {
                                const x = reclaims.xOf(steps[index].at);
                                ctx.lineTo(x, y(below[index]));
                                ctx.lineTo(x, y(index > 0 ? below[index - 1] : 0));
                            }
                            ctx.closePath();
                            ctx.fillStyle = ledger.stageColor(stage);
                            ctx.globalAlpha = !anyLit || reclaims.stageLit(stage) ? 0.85 : 0.3;
                            ctx.fill();
                            ctx.globalAlpha = 1;
                            below = above;
                        }
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
                            ctx.fillText(ledger.gib(bytes).replace(" GiB", "G").replace(" MiB", "M"), reclaims.plotLeft - 4, y(bytes) + 3);
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
                            const key = event ? reclaims.stageKey(event.stage) : "";
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
                            kind: ledger.stageName(event.stage),
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
