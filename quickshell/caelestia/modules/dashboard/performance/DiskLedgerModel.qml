pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

Item {
    id: root

    property var overview: ({})
    property var historyData: ({})
    property var events: []
    property var tracker: ({})
    property var nodes: ({})
    property var counts: ({})
    property var drill: []
    property var extra: []
    property bool diagnostics: false
    property string targetOverride: ""
    property int pendingTarget: 0
    readonly property bool targetPending: pendingTarget > 0
    property real receivedAt: 0
    property int frame: 0
    property bool paused: false
    property bool streamed: false
    property var held: ({})
    property bool keepsSnapshot: false

    Component.onCompleted: {
        const saved = keepsSnapshot ? DiskSnapshot.model : null;
        if (!saved)
            return;
        overview = saved.overview;
        historyData = saved.historyData;
        events = saved.events;
        nodes = saved.nodes;
        counts = saved.counts;
        receivedAt = saved.receivedAt;
        paused = true;
    }
    Component.onDestruction: {
        if (keepsSnapshot)
            DiskSnapshot.model = paused ? {
                overview: overview,
                historyData: historyData,
                events: events,
                nodes: nodes,
                counts: counts,
                receivedAt: receivedAt
            } : null;
    }

    readonly property string home: Quickshell.env("HOME") || "/home/max"
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"
    readonly property string targetPath: `${home}/.config/caelestia/disk-target`
    readonly property bool live: socket.connected
    readonly property var watches: ["overview", "history", "events"].concat(diagnostics ? ["tracker"] : []).concat(drill).concat(extra)
    readonly property var drillIds: drill.map(entry => typeof entry === "string" ? entry : entry.id).concat(extra)
    readonly property int eventLimit: 10000
    readonly property int nextSeq: events.length ? events[events.length - 1].seq + 1 : 0

    readonly property var history: historyData.points ?? []
    readonly property var historyItems: historyData.items ?? ({})
    readonly property var disk: overview.disk ?? ({})
    readonly property var collector: overview.gc ?? ({})
    readonly property var head: overview.next ?? null
    readonly property real free: overview.free ?? 0
    readonly property real diskTotal: disk.total ?? 0
    readonly property real total: Math.max(1, diskTotal)
    readonly property real targetGib: targetPending ? pendingTarget : targetOverride !== "" && !isNaN(parseInt(targetOverride)) ? parseInt(targetOverride) : Math.round((overview.target ?? 0) / 1073741824)
    readonly property real target: targetGib * 1073741824
    readonly property real deficit: targetPending || targetOverride !== "" ? Math.max(0, target - free) : (overview.deficit ?? 0)
    readonly property bool due: deficit > 0
    readonly property bool loaded: overview.segments !== undefined
    readonly property date updated: new Date(receivedAt * 1000)
    readonly property bool collecting: collector.state === "collecting"
    readonly property string collectingStage: collecting ? (segment(head?.kind ?? "")?.label ?? "") : ""
    readonly property string collectingText: {
        if (!collecting)
            return "";
        const handed = collector.handed ?? [];
        const first = collector.deleting ?? handed[0] ?? "";
        const name = first.startsWith(home + "/") ? `~${first.slice(home.length)}` : first.replace(/^\/nix\/store\/[a-z0-9]{32}-/, "");
        const more = handed.length > 1 ? ` +${handed.length - 1} queued` : "";
        return name ? `deleting ${name}${more}` : "collecting";
    }

    readonly property var kindKey: ({
            "dead": "dead",
            "cache": "cache",
            "temp": "temp",
            "stale shell": "stale_shell",
            "stray profile": "stray",
            "build": "build",
            "project": "project",
            "deploy": "stray",
            "generation": "generation",
            "agent": "agent",
            "git clone": "home_files",
            "game": "home_files",
            "recycle bin": "trash",
            "download": "downloads"
        })

    readonly property real hue: Colours.palette.m3primary.hslHue < 0 ? 0.6 : Colours.palette.m3primary.hslHue

    readonly property real arcStart: 0.47
    readonly property real arcLength: 0.71

    function tone(step: real, light: real): color {
        const origin = Math.min(arcLength, ((hue - arcStart) % 1 + 1) % 1);
        const along = (origin + step * arcLength) % arcLength;
        return Qt.hsla((arcStart + along) % 1, Colours.light ? 0.35 : 0.28, Colours.light ? light + 0.12 : light, 1);
    }

    function grey(light: real): color {
        return Qt.hsla(0, 0, Colours.light ? 1.05 - light : light, 1);
    }

    readonly property var swatches: ({
            running_system: tone(0, 0.5),
            home_profile: tone(0.04, 0.56),
            profiles: tone(0.07, 0.46),
            shells: tone(0.13, 0.44),
            processes: tone(0.16, 0.54),
            recent: tone(0.22, 0.5),
            building: tone(0.25, 0.46),
            metadata: tone(0.28, 0.36),
            dead: tone(0.34, 0.46),
            cache: tone(0.38, 0.54),
            temp: tone(0.42, 0.44),
            stale_shell: tone(0.46, 0.52),
            stray: tone(0.5, 0.42),
            build: tone(0.54, 0.5),
            project: tone(0.58, 0.44),
            generation: tone(0.66, 0.46),
            agent: tone(0.7, 0.4),
            trash: tone(0.74, 0.48),
            downloads: tone(0.76, 0.42),
            home_files: tone(0.78, 0.5),
            system_files: grey(0.5),
            swap: grey(0.44),
            held: grey(0.38),
            filesystem: grey(0.33),
            reserved: grey(0.58)
        })

    readonly property real ghostSeconds: 1
    property var ghosts: []
    property var redSeen: ({})
    property real ghostNow: 0
    readonly property real ghostTotal: ghosts.reduce((acc, ghost) => acc + ghost.len, 0)
    readonly property real shownFree: Math.max(0, free - ghostTotal)

    function shiftOf(key: string, at: real): real {
        let out = at;
        for (const ghost of ghosts)
            if (ghost.key === key && ghost.start <= out)
                out += ghost.len;
        return out;
    }

    function shiftSpan(key: string, span: var): var {
        if (!span)
            return span;
        const start = shiftOf(key, span[0]);
        let end = start + span[1];
        for (const ghost of ghosts)
            if (ghost.key === key && ghost.start > start && ghost.start < end)
                end += ghost.len;
        return [start, end - start];
    }

    function shiftSpans(key: string, list: var): var {
        return list ? list.map(span => shiftSpan(key, span)) : list;
    }

    function ghostBytes(key: string): real {
        return ghosts.reduce((acc, ghost) => acc + (ghost.key === key ? ghost.len : 0), 0);
    }

    function trackGhosts(): void {
        const now = Date.now() / 1000;
        const present = {};
        for (const row of overview.segments ?? [])
            for (const red of row.red_spans ?? [])
                if (red[2])
                    present[red[2]] = Math.max(0, red[1]);
        const added = [];
        for (const path of Object.keys(redSeen)) {
            const was = redSeen[path];
            const left = present[path] ?? 0;
            if (left < was.len)
                added.push({
                    key: was.key,
                    start: was.start + left,
                    len: was.len - left,
                    at: now
                });
        }
        if (added.length)
            ghosts = ghosts.concat(added).sort((a, b) => a.start - b.start);
        const seen = {};
        for (const row of overview.segments ?? [])
            for (const red of row.red_spans ?? []) {
                if (!red[2] || red[1] <= 0)
                    continue;
                const span = shiftSpan(row.key, [red[0], red[1]]);
                seen[red[2]] = {
                    key: row.key,
                    start: span[0],
                    len: span[1]
                };
            }
        redSeen = seen;
        ghostNow = now;
    }

    function expireGhosts(): void {
        const now = Date.now() / 1000;
        ghostNow = now;
        const expired = ghosts.filter(ghost => now - ghost.at >= ghostSeconds);
        if (!expired.length)
            return;
        let kept = ghosts.filter(ghost => now - ghost.at < ghostSeconds);
        const seen = Object.assign({}, redSeen);
        for (const gone of expired) {
            const pull = entry => entry.key === gone.key && entry.start > gone.start ? Object.assign({}, entry, {
                    start: entry.start - gone.len
                }) : entry;
            kept = kept.map(pull);
            for (const path of Object.keys(seen))
                seen[path] = pull(seen[path]);
        }
        redSeen = seen;
        ghosts = kept;
    }

    onOverviewChanged: trackGhosts()

    Timer {
        running: root.ghosts.length > 0
        interval: 16
        repeat: true
        onTriggered: root.expireGhosts()
    }

    readonly property var segments: (overview.segments ?? []).map(row => ({
                key: row.key,
                label: row.label,
                group: row.group,
                reclaim: row.reclaimable,
                color: swatches[row.key] ?? grey(0.5),
                bytes: row.bytes + ghostBytes(row.key),
                scheduled: row.scheduled,
                deleting: row.deleting ?? 0,
                lagging: row.lagging ?? 0,
                deletingSpans: shiftSpans(row.key, row.deleting_spans ?? null),
                laggingSpans: shiftSpans(row.key, row.lagging_spans ?? null),
                reclaimBytes: row.reclaim_bytes ?? (row.reclaimable ? row.bytes : 0),
                weight: row.reclaimable ? row.weight ?? -1 : -1,
                spans: shiftSpans(row.key, row.reclaim_spans ?? null),
                scheduledSpans: shiftSpans(row.key, row.scheduled_spans ?? null),
                nextSpan: shiftSpan(row.key, row.next_span ?? null),
                ghostSpans: ghosts.filter(ghost => ghost.key === row.key),
                items: row.items
            }))

    readonly property color hatchColor: Colours.light ? Colours.palette.m3onSurface : "white"
    readonly property color reclaimColor: Qt.hsla(0.36, 0.6, Colours.light ? 0.26 : 0.4, 1)
    readonly property color deletingColor: Qt.hsla(0.0, 0.8, Colours.light ? 0.45 : 0.55, 1)
    readonly property color laggingColor: Qt.hsla(0.0, 0.8, Colours.light ? 0.45 : 0.55, 0.45)
    readonly property color scheduledColor: Qt.hsla(0.08, 0.9, Colours.light ? 0.42 : 0.62, 1)

    function segment(key: string): var {
        return segments.find(item => item.key === key) ?? null;
    }

    function current(key: string): real {
        if (key === "free")
            return free;
        return segment(key)?.bytes ?? 0;
    }

    function valueOf(point: var, key: string): real {
        if (key === "free")
            return point.free ?? 0;
        return (point.segments ?? ({}))[key] ?? 0;
    }

    function scheduledBytes(key: string): real {
        return segment(key)?.scheduled ?? 0;
    }

    function scheduledFraction(key: string): real {
        const value = current(key);
        return value > 0 ? Math.min(1, scheduledBytes(key) / value) : 0;
    }

    function deletingFraction(key: string): real {
        const value = current(key);
        return value > 0 ? Math.min(1, (segment(key)?.deleting ?? 0) / value) : 0;
    }

    function laggingFraction(key: string): real {
        const value = current(key);
        return value > 0 ? Math.min(1, (segment(key)?.lagging ?? 0) / value) : 0;
    }

    function rows(id: string): var {
        return nodes[id] ?? null;
    }

    function count(id: string): int {
        return counts[id] ?? (nodes[id] ?? []).length;
    }

    function subscribe(): void {
        if (!socket.connected)
            return;
        socket.write(JSON.stringify({
            watch: watches
        }) + "\n");
        socket.flush();
    }

    function receive(text: string): void {
        let message;
        try {
            message = JSON.parse(text);
        } catch (e) {
            return;
        }
        const fresh = [];
        for (const one of message.messages ?? [message]) {
            if (paused && (!drillIds.includes(one.id) || one.id in nodes)) {
                const before = held[one.id];
                held[one.id] = one.append && before ? {
                    id: one.id,
                    data: before.data,
                    append: (before.append ?? []).concat(one.append)
                } : one;
            } else
                fresh.push(one);
        }
        apply(fresh);
        if (message.frame !== undefined)
            frame = message.frame;
    }

    function apply(messages: var): void {
        receivedAt = Date.now() / 1000;
        let copy = null;
        let sizes = null;
        for (const message of messages) {
            if (message.id === "overview") {
                overview = message.data;
                streamed = true;
            } else if (message.id === "history")
                historyData = message.data;
            else if (message.id === "events") {
                const base = message.data ?? events;
                const joined = message.append ? base.concat(message.append) : base;
                events = joined.length > eventLimit ? joined.slice(joined.length - eventLimit) : joined;
            } else if (message.id === "tracker")
                tracker = message.data;
            else {
                if (copy === null) {
                    copy = {};
                    sizes = {};
                    for (const id in nodes)
                        if (paused || drillIds.includes(id)) {
                            copy[id] = nodes[id];
                            sizes[id] = counts[id];
                        }
                }
                copy[message.id] = message.data;
                sizes[message.id] = message.count ?? message.data.length;
            }
        }
        if (copy !== null) {
            counts = sizes;
            nodes = copy;
        }
    }

    function setPaused(value: bool): void {
        paused = value;
        if (value)
            return;
        const buffered = held;
        held = {};
        const kept = {};
        for (const id of drillIds)
            if (id in nodes)
                kept[id] = nodes[id];
        nodes = kept;
        apply(Object.keys(buffered).filter(id => ["overview", "history", "events", "tracker"].includes(id) || drillIds.includes(id)).map(id => buffered[id]));
    }

    function gib(bytes: real): string {
        const value = bytes / 1073741824;
        if (Math.abs(value) >= 10)
            return `${value.toFixed(0)} GiB`;
        if (Math.abs(value) >= 0.1)
            return `${value.toFixed(1)} GiB`;
        if (Math.abs(bytes) >= 1048576)
            return `${Math.round(bytes / 1048576)} MiB`;
        return `${Math.round(bytes / 1024)} KiB`;
    }

    function ago(seconds: real): string {
        if (!seconds)
            return "";
        const delta = Math.max(0, Date.now() / 1000 - seconds);
        if (delta < 60)
            return "just now";
        if (delta < 3600)
            return `${Math.round(delta / 60)} min ago`;
        if (delta < 86400)
            return `${Math.round(delta / 3600)} h ago`;
        return `${Math.round(delta / 86400)} d ago`;
    }

    function clock(seconds: real): string {
        const age = Date.now() / 1000 - seconds;
        if (age < 6 * 86400 && age > -86400)
            return Qt.formatDateTime(new Date(seconds * 1000), "ddd HH:mm");
        if (age < 300 * 86400)
            return Qt.formatDateTime(new Date(seconds * 1000), "MM/dd HH:mm");
        return Qt.formatDateTime(new Date(seconds * 1000), "yyyy/MM/dd HH:mm");
    }

    function axisLabel(seconds: real, spanSeconds: real): string {
        const format = spanSeconds > 300 * 86400 ? "yyyy/MM/dd" : spanSeconds > 6 * 86400 ? "MM/dd" : spanSeconds > 2 * 86400 ? "ddd HH:mm" : "HH:mm";
        return Qt.formatDateTime(new Date(seconds * 1000), format);
    }

    function shortName(path: string): string {
        if (path.startsWith("/nix/store/"))
            return path.replace(/^\/nix\/store\/[a-z0-9]{32}-/, "");
        return path.startsWith(home) ? "~" + path.slice(home.length) : path;
    }

    function open(path: string): void {
        if (path && !path.startsWith("/nix/store/"))
            Quickshell.execDetached(["xdg-open", path]);
    }

    function focusWindow(pid: int): void {
        Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", `pid:${pid}`]);
    }

    function proposeTarget(gib: int): void {
        const value = Math.max(5, Math.min(200, gib));
        const saved = targetOverride !== "" && !isNaN(parseInt(targetOverride)) ? parseInt(targetOverride) : Math.round((overview.target ?? 0) / 1073741824);
        pendingTarget = value === saved ? 0 : value;
    }

    function applyTarget(): void {
        if (targetPending)
            setTarget(pendingTarget);
        pendingTarget = 0;
    }

    function setTarget(gib: int): void {
        const value = Math.max(5, Math.min(200, gib));
        targetOverride = String(value);
        Quickshell.execDetached(["sh", "-c", `mkdir -p "$(dirname "$1")" && printf %s "$2" > "$1"`, "disk-target", targetPath, String(value)]);
        if (socket.connected) {
            socket.write(JSON.stringify({
                target: value
            }) + "\n");
            socket.flush();
        }
    }

    function weightText(weight: real): string {
        return weight >= 1 ? `×${Math.round(weight)}` : `×1/${Math.round(1 / weight)}`;
    }

    function weightOpacity(weight: real): real {
        if (!(weight > 0))
            return 1;
        const reach = Math.max(0, Math.min(1, (Math.log2(weight) + 6) / 12));
        return 1 - 0.6 * reach;
    }

    function ageShade(base: color, lastUsed: real): color {
        if (!lastUsed)
            return base;
        const days = Math.min(120, Math.max(0, (Date.now() / 1000 - lastUsed) / 86400));
        const fade = 0.2 * days / 120;
        return Qt.hsla(base.hslHue, Math.max(0.08, base.hslSaturation - fade), base.hslLightness + (Colours.light ? fade : -fade), 1);
    }

    onWatchesChanged: subscribe()

    Socket {
        id: socket

        path: `${root.runtimeDir}/disk-tree.sock`
        connected: true
        parser: SplitParser {
            onRead: data => root.receive(data)
        }
        onConnectionStateChanged: {
            if (connected) {
                root.subscribe();
            } else {
                root.streamed = false;
            }
        }
    }

    Timer {
        interval: 2000
        repeat: true
        running: !socket.connected
        onTriggered: {
            socket.connected = false;
            socket.connected = true;
        }
    }

    FileView {
        path: root.streamed || root.paused ? "" : `${root.runtimeDir}/disk-ledger.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const data = JSON.parse(text());
                root.overview = data;
                root.historyData = {
                    points: data.history ?? [],
                    items: ({})
                };
                root.events = data.events ?? [];
                root.receivedAt = data.at ?? 0;
            } catch (e) {}
        }
    }

    FileView {
        path: root.targetPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.targetOverride = text().trim()
    }
}
