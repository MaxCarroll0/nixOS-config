pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Singleton {
    id: root

    readonly property string stateDir: `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/interview`
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"

    property var current: null
    property var lockdown: null
    property var log: ({
            today: "",
            required_per_day: 2,
            days: {}
        })
    property real now: Date.now() / 1000
    property string testOutput: ""
    property int testExit: -1
    property string lastError: ""
    property string openError: ""
    property var settingsDoc: null
    property string settingsMessage: ""
    property bool settingsFailed: false
    property int settingsSaved: 0

    readonly property string phase: current?.phase ?? "idle"
    readonly property bool active: phase !== "idle"
    readonly property real codingLeft: current ? Math.max(0, current.coding_budget - current.used_before - (current.running_since ? now - current.running_since : 0)) : 0
    readonly property bool reviewing: phase === "review" || phase === "records"
    readonly property real reviewElapsed: current?.review_started ? Math.max(0, (current.review_ended ?? now) - current.review_started) : 0
    readonly property real left: reviewing ? reviewElapsed : codingLeft
    readonly property var today: log.days[log.today] ?? null
    readonly property int completedToday: today?.completed ?? 0
    readonly property int required: log.required_per_day ?? 2
    readonly property real todaySeconds: today?.total ?? 0
    readonly property bool testing: tests.running
    readonly property bool locked: lockdown !== null
    readonly property bool finishApproved: (phase === "coding" || phase === "paused") && (!!current?.finish_approved || current?.hidden_tests === "pass")

    readonly property var settings: settingsDoc?.settings ?? null
    readonly property var languages: settingsDoc?.languages ?? []
    readonly property var interviewDays: settings?.days ?? ["Mon", "Tue", "Thu", "Fri"]
    readonly property bool settingsBusy: settingsProc.running
    readonly property var langColours: {
        const out = {};
        for (const l of languages)
            if (l.colour)
                out[l.id] = l.colour;
        return out;
    }
    readonly property var langNames: {
        const out = {};
        for (const l of languages)
            out[l.id] = l.name;
        return out;
    }

    function clock(seconds: real): string {
        const s = Math.max(0, Math.round(seconds));
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    }

    function hours(seconds: real): string {
        const m = Math.round(seconds / 60);
        if (m < 60)
            return `${m}m`;
        return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`;
    }

    function dateKey(d: date): string {
        return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    }

    function day(key: string): var {
        return log.days[key] ?? null;
    }

    function isInterviewDay(d: date): bool {
        const name = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()];
        const from = settings?.from ?? "";
        return interviewDays.includes(name) && (!from || dateKey(d) >= from);
    }

    function streak(): int {
        let count = 0;
        const d = new Date();
        if (!(day(dateKey(d))?.completed >= required))
            d.setDate(d.getDate() - 1);
        for (let i = 0; i < 400; i++) {
            const done = (day(dateKey(d))?.completed ?? 0) >= required;
            if (done)
                count++;
            else if (isInterviewDay(d))
                break;
            d.setDate(d.getDate() - 1);
        }
        return count;
    }

    function totals(): var {
        const out = {};
        for (const key of Object.keys(log.days)) {
            for (const s of log.days[key].sessions) {
                const t = out[s.lang] ?? (out[s.lang] = {
                        lang: s.lang,
                        coding: 0,
                        review: 0,
                        completed: 0
                    });
                t.coding += s.coding;
                t.review += s.review;
                if (s.complete)
                    t.completed++;
            }
        }
        return Object.values(out).sort((a, b) => b.coding - a.coding);
    }

    function command(args: list<string>): void {
        if (ctl.running)
            return;
        ctl.command = ["interview", ...args];
        ctl.running = true;
    }

    function toggle(): void {
        command(["toggle"]);
    }

    function startNext(): void {
        command(["start", "--open"]);
    }

    function finishEarly(): void {
        command(["done"]);
    }

    function endInterview(): void {
        command(["end"]);
    }

    function openSession(dir: string, what: string): void {
        if (opener.running)
            return;
        openError = "";
        opener.command = ["interview", "open", dir, what];
        opener.running = true;
    }

    function runTests(): void {
        if (tests.running || !current)
            return;
        testOutput = "";
        testExit = -1;
        tests.running = true;
    }

    function refresh(): void {
        if (!logProc.running)
            logProc.running = true;
        if (!settingsShow.running)
            settingsShow.running = true;
    }

    function saveSettings(password: string, next: var): void {
        settingsCall(["set"], `${password}\n${JSON.stringify(next)}`);
    }

    function resetSettings(password: string): void {
        settingsCall(["reset"], `${password}\n`);
    }

    function settingsCall(action: list<string>, input: string): void {
        if (settingsProc.running)
            return;
        settingsMessage = "";
        settingsFailed = false;
        settingsProc.input = input;
        settingsProc.command = ["interview", "settings", ...action];
        settingsProc.running = true;
    }

    Process {
        id: settingsShow

        command: ["interview", "settings", "show", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.settingsDoc = JSON.parse(text);
                } catch (e) {}
            }
        }
    }

    Process {
        id: settingsProc

        property string input

        stdinEnabled: true
        stdout: StdioCollector {
            id: settingsOut
        }
        stderr: StdioCollector {
            id: settingsErr
        }
        onStarted: {
            write(input);
            stdinEnabled = false;
        }
        onExited: code => {
            stdinEnabled = true;
            root.settingsFailed = code !== 0;
            root.settingsMessage = (code === 0 ? settingsOut.text : settingsErr.text || settingsOut.text).trim();
            if (code === 0)
                root.settingsSaved++;
            root.refresh();
        }
    }

    Process {
        id: ctl

        stderr: StdioCollector {
            onStreamFinished: root.lastError = text.trim()
        }
        onExited: {
            currentFile.reload();
            root.refresh();
        }
    }

    Process {
        id: opener

        stderr: StdioCollector {
            onStreamFinished: root.openError = text.trim()
        }
        onExited: root.refresh()
    }

    Process {
        id: tests

        command: ["interview", "run"]
        stdout: StdioCollector {
            onStreamFinished: root.testOutput = text
        }
        onExited: code => root.testExit = code
    }

    Process {
        id: logProc

        command: ["interview", "log", "--json", "--days", "400"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.log = JSON.parse(text);
                } catch (e) {}
            }
        }
    }

    FileView {
        id: currentFile

        path: `${root.stateDir}/current.json`
        printErrors: false
        onLoaded: {
            try {
                const next = JSON.parse(text());
                const changed = root.current?.phase !== next.phase || root.current?.id !== next.id;
                root.current = next;
                if (changed)
                    root.refresh();
            } catch (e) {}
        }
        onLoadFailed: {
            if (root.current !== null) {
                root.current = null;
                root.refresh();
            }
        }
    }

    FileView {
        id: lockdownFile

        path: `${root.runtimeDir}/lockdown/active.json`
        printErrors: false
        onLoaded: {
            try {
                root.lockdown = JSON.parse(text());
            } catch (e) {}
        }
        onLoadFailed: root.lockdown = null
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.now = Date.now() / 1000;
            currentFile.reload();
            lockdownFile.reload();
        }
    }

    IdleMonitor {
        id: presence

        timeout: 120
        respectInhibitors: false
    }

    Process {
        id: autoStart

        command: ["interview", "auto"]
        onExited: currentFile.reload()
    }

    Timer {
        interval: 30000
        running: !presence.isIdle && !root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!autoStart.running)
                autoStart.running = true;
        }
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
