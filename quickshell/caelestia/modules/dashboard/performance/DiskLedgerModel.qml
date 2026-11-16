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
    property real receivedAt: 0
    property bool paused: false
    property bool streamed: false
    property var held: ({})

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
    readonly property real targetGib: targetOverride !== "" && !isNaN(parseInt(targetOverride)) ? parseInt(targetOverride) : Math.round((overview.target ?? 0) / 1073741824)
    readonly property real target: targetGib * 1073741824
    readonly property real deficit: targetOverride !== "" ? Math.max(0, target - free) : (overview.deficit ?? 0)
    readonly property bool due: deficit > 0
    readonly property bool loaded: overview.segments !== undefined
    readonly property date updated: new Date(receivedAt * 1000)
    readonly property bool collecting: collector.state === "collecting"
    readonly property string collectingStage: collecting ? (segment(kindKey[collector.kind] ?? "")?.label ?? collector.kind ?? "") : ""

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
            "game": "home_files"
        })

    readonly property real hue: Colours.palette.m3primary.hslHue < 0 ? 0.6 : Colours.palette.m3primary.hslHue

    function tone(step: real, light: real): color {
        return Qt.hsla((hue + step) % 1, Colours.light ? 0.35 : 0.28, Colours.light ? light + 0.12 : light, 1);
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
            home_files: tone(0.78, 0.5),
            system_files: grey(0.5),
            swap: grey(0.44),
            held: grey(0.38),
            filesystem: grey(0.33),
            reserved: grey(0.58)
        })

    readonly property var segments: (overview.segments ?? []).map(row => ({
                key: row.key,
                label: row.label,
                group: row.group,
                reclaim: row.reclaimable,
                color: swatches[row.key] ?? grey(0.5),
                bytes: row.bytes,
                scheduled: row.scheduled,
                deleting: row.deleting ?? 0,
                reclaimBytes: row.reclaim_bytes ?? (row.reclaimable ? row.bytes : 0),
                weight: row.reclaimable ? row.weight ?? -1 : -1,
                spans: row.reclaim_spans ?? null,
                items: row.items
            }))

    readonly property color hatchColor: Colours.light ? Colours.palette.m3onSurface : "white"
    readonly property color reclaimColor: Qt.hsla(0.36, 0.6, Colours.light ? 0.26 : 0.4, 1)
    readonly property color deletingColor: Qt.hsla(0.0, 0.8, Colours.light ? 0.45 : 0.55, 1)
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
        if (paused && (!drillIds.includes(message.id) || message.id in nodes)) {
            const before = held[message.id];
            held[message.id] = message.append && before ? {
                id: message.id,
                data: before.data,
                append: (before.append ?? []).concat(message.append)
            } : message;
            return;
        }
        apply(message);
    }

    function apply(message: var): void {
        receivedAt = Date.now() / 1000;
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
            const copy = {};
            const sizes = {};
            for (const id in nodes)
                if (paused || drillIds.includes(id)) {
                    copy[id] = nodes[id];
                    sizes[id] = counts[id];
                }
            copy[message.id] = message.data;
            sizes[message.id] = message.count ?? message.data.length;
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
        for (const id in buffered)
            if (["overview", "history", "events", "tracker"].includes(id) || drillIds.includes(id))
                apply(buffered[id]);
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

    function setTarget(gib: int): void {
        const value = Math.max(5, Math.min(200, gib));
        targetOverride = String(value);
        Quickshell.execDetached(["sh", "-c", `mkdir -p "$(dirname "$1")" && printf %s "$2" > "$1"`, "disk-target", targetPath, String(value)]);
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
                retry.start();
            }
        }
        onError: retry.start()
    }

    Timer {
        id: retry

        interval: 2000
        onTriggered: socket.connected = true
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
