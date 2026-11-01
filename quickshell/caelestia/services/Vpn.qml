pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var status: ({})
    property real now: Date.now() / 1000
    property string pending: ""

    readonly property bool present: status.updated !== undefined
    readonly property bool enabled: status.enabled ?? true
    readonly property bool up: status.up ?? false
    readonly property string server: status.server ?? ""
    readonly property string country: server.split("#")[0]
    readonly property string endpoint: status.endpoint ?? ""
    readonly property real handshakeAge: (status.handshake ?? 0) > 0 ? Math.max(0, now - status.handshake) : -1
    readonly property real rx: status.rx ?? 0
    readonly property real tx: status.tx ?? 0
    readonly property string busy: pending || (status.busy ?? "")
    readonly property string failed: pending ? "" : status.failed ?? ""
    readonly property var countries: status.countries ?? []

    function run(verb: string): void {
        if (ctl.running)
            return;
        pending = verb;
        ctl.command = ["systemctl", "start", `vpn-ctl@${verb}.service`];
        ctl.running = true;
    }

    function refresh(): void {
        now = Date.now() / 1000;
        if (!ctl.running && present)
            poke.running = true;
    }

    function age(seconds: real): string {
        if (seconds < 0)
            return "never";
        if (seconds < 90)
            return `${Math.round(seconds)}s ago`;
        if (seconds < 5400)
            return `${Math.round(seconds / 60)}m ago`;
        return `${Math.round(seconds / 3600)}h ago`;
    }

    function bytes(n: real): string {
        const units = ["B", "KiB", "MiB", "GiB", "TiB"];
        let i = 0;
        while (n >= 1024 && i < units.length - 1) {
            n /= 1024;
            i++;
        }
        return `${n.toFixed(i > 0 && n < 10 ? 1 : 0)} ${units[i]}`;
    }

    Process {
        id: ctl

        onExited: {
            root.pending = "";
            file.reload();
        }
    }

    Process {
        id: poke

        command: ["systemctl", "start", "--no-block", "vpn-ctl@status.service"]
    }

    FileView {
        id: file

        path: "/run/proton/status.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.status = JSON.parse(text());
            } catch (e) {}
        }
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: root.now = Date.now() / 1000
    }
}
