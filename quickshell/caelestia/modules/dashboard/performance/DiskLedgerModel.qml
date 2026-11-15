pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

Item {
    id: root

    property var ledger: ({})
    property var pressure: ({})
    property string targetOverride: ""

    readonly property string home: Quickshell.env("HOME") || "/home/max"
    readonly property string targetPath: `${home}/.config/caelestia/disk-target`
    readonly property var store: ledger.store_disk ?? ledger.store ?? ({})
    readonly property var queue: ledger.queue ?? []
    readonly property var events: ledger.events ?? []
    readonly property var history: ledger.history ?? []
    readonly property var provenance: ledger.provenance ?? ({})
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"
    readonly property string deadFile: `${runtimeDir}/disk-dead.jsonl`

    function segmentFile(key: string): string {
        return ["system", "home", "system_generations", "home_generations", "deployed", "shells", "other"].includes(key) ? `${runtimeDir}/disk-segment-${key}.jsonl` : "";
    }

    function scheduledBytes(key: string): real {
        const stages = Object.keys(stageSegment).filter(stage => stageSegment[stage] === key || ((key.startsWith("project") || key === "fetched") && stage === "projects"));
        return queue.filter((row, index) => index <= cut && stages.includes(row.stage)).reduce((acc, row) => acc + (row.size ?? 0), 0);
    }

    function scheduledFraction(key: string): real {
        const value = current(key);
        return value > 0 ? Math.min(1, scheduledBytes(key) / value) : 0;
    }
    readonly property real free: ledger.free ?? 0
    readonly property real targetGib: targetOverride !== "" && !isNaN(parseInt(targetOverride)) ? parseInt(targetOverride) : Math.round((ledger.target ?? 0) / 1073741824)
    readonly property real target: targetGib * 1073741824
    readonly property real deficit: Math.max(0, target - free)
    readonly property int cut: {
        if (deficit <= 0)
            return -1;
        let sum = 0;
        for (let index = 0; index < queue.length; index++) {
            sum += queue[index].size;
            if (sum >= deficit)
                return index;
        }
        return queue.length - 1;
    }
    readonly property real diskTotal: (ledger.disk ?? ({})).total ?? accounted
    readonly property bool loaded: (ledger.at ?? 0) > 0
    readonly property date updated: new Date((ledger.at ?? 0) * 1000)
    readonly property bool collecting: pressure.running ?? false
    readonly property string collectingStage: ({ "project-scratch-clean": "tmp and caches", "project-closure-retention": "project closures", "store-collect": "dead store paths" })[pressure.stage ?? ""] ?? (pressure.stage ?? "")
    readonly property real collectingSince: pressure.at ?? 0

    readonly property real hue: Colours.palette.m3primary.hslHue < 0 ? 0.6 : Colours.palette.m3primary.hslHue

    function tone(step: real, light: real): color {
        return Qt.hsla((hue + step) % 1, Colours.light ? 0.35 : 0.28, Colours.light ? light + 0.12 : light, 1);
    }

    readonly property var segments: [
        { key: "system", group: "store", label: "running system", color: tone(0, 0.5), reclaim: false, detail: "none" },
        { key: "home", group: "store", label: "home profile", color: tone(0.06, 0.56), reclaim: false, detail: "none" },
        { key: "system_generations", group: "store", label: "older system generations", color: tone(0.12, 0.48), reclaim: true, detail: "generations" },
        { key: "home_generations", group: "store", label: "older home generations", color: tone(0.15, 0.42), reclaim: true, detail: "generations" },
        { key: "deployed", group: "store", label: "deployed to other hosts", color: tone(0.18, 0.54), reclaim: true, detail: "deployed" },
        { key: "project_tier1", group: "store", label: "projects: builds", color: tone(0.3, 0.52), reclaim: true, detail: "projects" },
        { key: "project_tier2", group: "store", label: "projects: toolchains", color: tone(0.36, 0.46), reclaim: true, detail: "projects" },
        { key: "fetched", group: "store", label: "projects: fetched sources", color: tone(0.42, 0.56), reclaim: true, detail: "projects" },
        { key: "shells", group: "store", label: "live shells and builds", color: tone(0.5, 0.5), reclaim: false, detail: "none" },
        { key: "other", group: "store", label: "other live store paths", color: tone(0.56, 0.44), reclaim: false, detail: "other" },
        { key: "garbage", group: "store", label: "dead store paths", color: tone(0.66, 0.46), reclaim: true, detail: "dead" },
        { key: "metadata", group: "store", label: "store database and link table", color: tone(0.7, 0.36), reclaim: false, detail: "none" },
        { key: "rescan", group: "store", label: "shared files awaiting rescan", color: tone(0.74, 0.4), reclaim: false, detail: "none" },
        { key: "home_files", group: "files", label: "home files", color: tone(0.78, 0.5), reclaim: false, detail: "home" },
        { key: "caches", group: "files", label: "caches", color: tone(0.88, 0.54), reclaim: true, detail: "caches" },
        { key: "reserved", group: "system", label: "ext4 root reserve", color: Qt.hsla(0, 0, Colours.light ? 0.8 : 0.45, 1), reclaim: false, detail: "none" },
        { key: "swap", group: "system", label: "swapfile", color: Qt.hsla(0, 0, Colours.light ? 0.72 : 0.38, 1), reclaim: false, detail: "none" },
        { key: "system_files", group: "system", label: "system files", color: Qt.hsla(0, 0, Colours.light ? 0.62 : 0.3, 1), reclaim: false, detail: "system" },
        { key: "held", group: "system", label: "deleted, still open", color: Qt.hsla(0, 0, Colours.light ? 0.56 : 0.26, 1), reclaim: false, detail: "held" },
        { key: "unaccounted", group: "system", label: "unaccounted", color: Qt.hsla(0, 0, Colours.light ? 0.5 : 0.22, 1), reclaim: false, detail: "none" }
    ]

    readonly property var stageSegment: ({ scratch: "caches", projects: "project_tier1", store: "garbage" })

    function segmentScheduled(key: string): bool {
        const stages = Object.keys(stageSegment).filter(stage => stageSegment[stage] === key || ((key.startsWith("project") || key === "fetched") && stage === "projects"));
        return queue.some((row, index) => index <= cut && stages.includes(row.stage));
    }

    function segment(key: string): var {
        return segments.find(item => item.key === key) ?? null;
    }

    function stageName(stage: string): string {
        return ({ scratch: "tmp and caches", projects: "project closures", store: "dead store paths" })[stage] ?? stage;
    }

    function stageColor(stage: string): color {
        return segment(stageSegment[stage] ?? "garbage").color;
    }

    readonly property color freeColor: Colours.palette.m3primary
    readonly property color reclaimColor: Qt.hsla(0.36, 0.6, Colours.light ? 0.26 : 0.4, 1)
    readonly property color scheduledColor: Qt.hsla(0.08, 0.9, Colours.light ? 0.42 : 0.62, 1)

    function sum(values: var): real {
        let total = 0;
        for (const key in values)
            total += values[key] ?? 0;
        return total;
    }

    function valueOf(point: var, key: string): real {
        if (key === "free")
            return point.free ?? 0;
        if (key === "swap")
            return point.swap ?? 0;
        if (key === "system_files")
            return point.system ?? point.system_files ?? 0;
        if (key === "held")
            return point.held ?? 0;
        if (key === "unaccounted")
            return Math.max(0, point.unaccounted ?? 0);
        if (key === "reserved")
            return point.reserved ?? (ledger.disk ?? ({})).reserved ?? 0;
        const files = point.files;
        if (key === "home_files")
            return typeof files === "number" ? files : (files ?? ({})).home ?? 0;
        if (key === "caches")
            return typeof files === "object" && files ? files.caches ?? 0 : 0;
        const store = point.store_disk ?? point.store ?? ({});
        if (key === "system_generations" && !("system_generations" in store))
            return store.generations ?? 0;
        return store[key] ?? 0;
    }

    function current(key: string): real {
        return valueOf(ledger, key);
    }

    readonly property real accounted: segments.reduce((acc, item) => acc + current(item.key), 0) + free
    readonly property real total: Math.max(1, accounted)

    function gib(bytes: real): string {
        const value = bytes / 1073741824;
        if (value >= 10)
            return `${value.toFixed(0)} GiB`;
        if (value >= 0.1)
            return `${value.toFixed(1)} GiB`;
        return `${Math.round(bytes / 1048576)} MiB`;
    }

    function ago(seconds: real): string {
        if (!seconds)
            return "";
        const delta = Math.max(0, Date.now() / 1000 - seconds);
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

    function setTarget(gib: int): void {
        const value = Math.max(5, Math.min(200, gib));
        targetOverride = String(value);
        Quickshell.execDetached(["sh", "-c", `mkdir -p "$(dirname "$1")" && printf %s "$2" > "$1"`, "disk-target", targetPath, String(value)]);
    }

    function ageShade(base: color, lastUsed: real): color {
        if (!lastUsed)
            return base;
        const days = Math.min(120, Math.max(0, (Date.now() / 1000 - lastUsed) / 86400));
        const fade = 0.2 * days / 120;
        return Qt.hsla(base.hslHue, Math.max(0.08, base.hslSaturation - fade), base.hslLightness + (Colours.light ? fade : -fade), 1);
    }

    FileView {
        path: root.targetPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.targetOverride = text().trim()
    }

    FileView {
        path: `${Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"}/disk-pressure.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.pressure = JSON.parse(text());
            } catch (e) {}
        }
    }

    FileView {
        path: `${Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"}/disk-ledger.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.ledger = JSON.parse(text());
            } catch (e) {}
        }
    }
}
