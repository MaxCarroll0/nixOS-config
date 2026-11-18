import QtQuick

Item {
    id: root

    property string live: "http://pi:9090"
    property string history: "http://pi/fleet-history"
    property string repo: "https://github.com/MaxCarroll0/nixOS-config"
    readonly property real liveRetention: 7 * 86400 - 3600
    readonly property var hosts: ["pi", "laptop", "desktopnew"]

    property var range: [Date.now() / 1000 - 86400, Date.now() / 1000]
    property var anchor: null
    property real smoothing: 600
    property bool active: true

    readonly property real now: clock.now
    readonly property real at: anchor === null ? now : anchor
    readonly property bool following: anchor === null

    property var rows: []
    property var slice: ({
            nodes: [],
            edges: [],
            builds: [],
            pressure: ({}),
            psi: ({}),
            deploys: ({})
        })
    property bool reachable: true
    property string error: ""
    property int pending: 0

    QtObject {
        id: clock

        property real now: Date.now() / 1000
    }

    Timer {
        interval: 5000
        repeat: true
        running: root.active
        triggeredOnStart: true
        onTriggered: {
            const previous = clock.now;
            clock.now = Date.now() / 1000;
            if (root.following)
                root.fetchSlice();
            if (root.range[1] >= previous - 30)
                root.range = [root.range[0] + clock.now - previous, clock.now];
            else if (!root.rows.length)
                root.fetchRows();
        }
    }

    Timer {
        id: sliceDebounce

        interval: 120
        onTriggered: root.fetchSlice()
    }

    Timer {
        id: rowsDebounce

        interval: 200
        onTriggered: root.fetchRows()
    }

    onAnchorChanged: {
        const [from, to] = range;
        const span = to - from;
        const target = anchor ?? now;
        if (target - smoothing < from || target > to) {
            const end = Math.min(now, target + span / 2);
            range = [end - span, end];
        }
        sliceDebounce.restart();
    }
    onSmoothingChanged: sliceDebounce.restart()
    onRangeChanged: rowsDebounce.restart()

    function archived(from: real): bool {
        return from < root.now - root.liveRetention;
    }

    function series(name: string, archive: bool): string {
        const archiveName = {
            "ts:peer_online": "ts:peer_online:1h",
            "ts:peer_direct": "ts:peer_direct:1h",
            "ts:peer_rx_bytes": "ts:peer_rx_bytes:1h",
            "ts:peer_tx_bytes": "ts:peer_tx_bytes:1h",
            "host:up": "host:up:1h",
            "load:pressure_ratio": "load:pressure_ratio:1h",
            "psi:cpu_waiting": "psi:cpu_waiting:1h",
            "psi:io_stalled": "psi:io_stalled:1h",
            "psi:memory_stalled": "psi:memory_stalled:1h",
            "nix_derivation_builds_total": "nix:builds_total:1h_max",
            "fleet_system_info": "fleet:system_info:1h_max",
            "fleet_system_activated_seconds": "fleet:activated_seconds:1h_max",
            "fleet_deploy_seconds": "fleet:deploy_seconds:1h_max"
        };
        return archive ? archiveName[name] : name;
    }

    function duration(seconds: real): string {
        return `${Math.max(1, Math.round(seconds))}s`;
    }

    function request(base: string, path: string, params: var, done: var): void {
        const query = Object.keys(params).map(key => `${key}=${encodeURIComponent(params[key])}`).join("&");
        const xhr = new XMLHttpRequest();
        root.pending++;
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE || !root)
                return;
            root.pending--;
            if (xhr.status !== 200) {
                root.reachable = false;
                root.error = xhr.status ? `${xhr.status} ${path}` : "pi unreachable";
                done([]);
                return;
            }
            root.reachable = true;
            root.error = "";
            try {
                done(JSON.parse(xhr.responseText).data.result);
            } catch (e) {
                done([]);
            }
        };
        xhr.open("GET", `${base}/api/v1/${path}?${query}`);
        xhr.send();
    }

    function instant(archive: bool, expr: string, at: real, done: var): void {
        request(archive ? root.history : root.live, "query", {
            query: expr,
            time: at.toFixed(3)
        }, done);
    }

    function ranged(archive: bool, expr: string, from: real, to: real, step: real, done: var): void {
        request(archive ? root.history : root.live, "query_range", {
            query: expr,
            start: from.toFixed(3),
            end: to.toFixed(3),
            step: root.duration(step)
        }, done);
    }

    function gather(jobs: var, finish: var): void {
        const results = {};
        let left = Object.keys(jobs).length;
        for (const key in jobs)
            jobs[key](result => {
                results[key] = result;
                if (--left === 0)
                    finish(results);
            });
    }

    property int rowsGeneration: 0

    function fetchRows(): void {
        const [from, to] = root.range;
        const archive = root.archived(from);
        const step = Math.max(archive ? 3600 : 1, (to - from) / 288);
        const window = root.duration(step);
        const s = name => root.series(name, archive);
        const generation = ++root.rowsGeneration;
        const span = (expr, done) => root.ranged(archive, expr, from, to, step, done);
        root.gather({
            up: done => span(`avg_over_time(${s("host:up")}[${window}])`, done),
            online: done => span(`max by (peer, peer_os) (avg_over_time(${s("ts:peer_online")}[${window}]))`, done),
            direct: done => span(`max by (peer) (avg_over_time(${s("ts:peer_direct")}[${window}]))`, done),
            traffic: done => span(`sum by (peer) (avg_over_time(${s("ts:peer_rx_bytes")}[${window}]) + avg_over_time(${s("ts:peer_tx_bytes")}[${window}]))`, done)
        }, results => {
            if (generation === root.rowsGeneration)
                root.rows = root.shapeRows(results, from, to, step);
        });
    }

    function valuesOf(result: var, from: real, step: real, count: int): var {
        const out = new Array(count).fill(NaN);
        for (const [at, value] of result.values ?? []) {
            const index = Math.round((at - from) / step);
            if (index >= 0 && index < count)
                out[index] = parseFloat(value);
        }
        return out;
    }

    function shapeRows(results: var, from: real, to: real, step: real): var {
        const count = Math.floor((to - from) / step) + 1;
        const byName = {};
        const row = (name, os) => {
            if (!byName[name])
                byName[name] = {
                    name: name,
                    os: os,
                    host: root.hosts.includes(name),
                    online: new Array(count).fill(NaN),
                    direct: new Array(count).fill(NaN),
                    traffic: new Array(count).fill(NaN)
                };
            return byName[name];
        };
        for (const result of results.up.filter(result => root.hosts.includes(result.metric.instance)))
            row(result.metric.instance, "linux").online = root.valuesOf(result, from, step, count);
        for (const result of results.online) {
            const name = result.metric.peer;
            const existing = byName[name];
            const values = root.valuesOf(result, from, step, count);
            const target = row(name, result.metric.peer_os ?? "");
            if (!existing || !existing.host)
                target.online = values;
        }
        for (const result of results.direct)
            row(result.metric.peer, "").direct = root.valuesOf(result, from, step, count);
        for (const result of results.traffic)
            row(result.metric.peer, "").traffic = root.valuesOf(result, from, step, count);
        const order = name => {
            const host = root.hosts.indexOf(name);
            return host >= 0 ? `0${host}` : `1${byName[name].os}${name}`;
        };
        return Object.keys(byName).sort((a, b) => order(a).localeCompare(order(b))).map(name => Object.assign(byName[name], {
                from: from,
                step: step
            }));
    }

    property int sliceGeneration: 0

    function fetchSlice(): void {
        const at = root.at;
        const smoothing = Math.max(60, root.smoothing);
        const archive = root.archived(at - smoothing);
        const window = root.duration(archive ? Math.max(3600, smoothing) : smoothing);
        const lookback = archive ? "2h" : "5m";
        const s = name => root.series(name, archive);
        const generation = ++root.sliceGeneration;
        const point = (expr, done) => root.instant(archive, expr, at, done);
        root.gather({
            up: done => point(`avg_over_time(${s("host:up")}[${window}])`, done),
            online: done => point(`max_over_time(${s("ts:peer_online")}[${window}])`, done),
            direct: done => point(`avg_over_time(${s("ts:peer_direct")}[${window}])`, done),
            tx: done => point(`avg_over_time(${s("ts:peer_tx_bytes")}[${window}])`, done),
            rx: done => point(`avg_over_time(${s("ts:peer_rx_bytes")}[${window}])`, done),
            builds: done => point(`sum by (instance, builder) (increase(${s("nix_derivation_builds_total")}[${window}]))`, done),
            psiCpu: done => point(`avg_over_time(${s("psi:cpu_waiting")}[${window}])`, done),
            psiIo: done => point(`avg_over_time(${s("psi:io_stalled")}[${window}])`, done),
            psiMemory: done => point(`avg_over_time(${s("psi:memory_stalled")}[${window}])`, done),
            pressure: done => root.ranged(archive, s("load:pressure_ratio"), at - smoothing, at, Math.max(archive ? 3600 : 1, smoothing / 48), done),
            rev: done => point(`last_over_time(${s("fleet_system_info")}[${lookback}])`, done),
            activated: done => point(`last_over_time(${s("fleet_system_activated_seconds")}[${lookback}])`, done),
            deploy: done => point(`last_over_time(${s("fleet_deploy_seconds")}[${archive ? "30d" : "7d"}])`, done)
        }, results => {
            if (generation === root.sliceGeneration)
                root.slice = root.shapeSlice(results, at - smoothing, at);
        });
    }

    function value(result: var): real {
        return parseFloat(result.value?.[1] ?? "NaN");
    }

    function shapeSlice(results: var, from: real, to: real): var {
        const nodes = {};
        const node = (name, os) => {
            if (!nodes[name])
                nodes[name] = {
                    name: name,
                    os: os || "",
                    host: root.hosts.includes(name),
                    up: 0
                };
            if (os && !nodes[name].os)
                nodes[name].os = os;
            return nodes[name];
        };
        for (const name of root.hosts)
            node(name, "linux");
        for (const result of results.up.filter(result => root.hosts.includes(result.metric.instance)))
            node(result.metric.instance, "linux").up = root.value(result);
        for (const result of results.online) {
            const peer = node(result.metric.peer, result.metric.peer_os);
            if (!peer.host)
                peer.up = Math.max(peer.up, root.value(result));
        }

        const edges = {};
        const edge = (a, b) => {
            const key = [a, b].sort().join("\u001f");
            if (!edges[key]) {
                const [first, second] = key.split("\u001f");
                edges[key] = {
                    a: first,
                    b: second,
                    ab: 0,
                    ba: 0,
                    direct: NaN,
                    relay: ""
                };
            }
            return edges[key];
        };
        const flow = (from, to, rate) => {
            if (!isFinite(rate))
                return;
            const item = edge(from, to);
            if (item.a === from)
                item.ab = Math.max(item.ab, rate);
            else
                item.ba = Math.max(item.ba, rate);
        };
        for (const result of results.tx) {
            node(result.metric.peer, result.metric.peer_os);
            flow(result.metric.instance, result.metric.peer, root.value(result));
        }
        for (const result of results.rx) {
            node(result.metric.peer, result.metric.peer_os);
            flow(result.metric.peer, result.metric.instance, root.value(result));
        }
        for (const result of results.direct) {
            const item = edge(result.metric.instance, result.metric.peer);
            const direct = root.value(result);
            item.direct = isFinite(item.direct) ? Math.max(item.direct, direct) : direct;
            if (result.metric.relay)
                item.relay = result.metric.relay;
        }
        for (const result of results.online) {
            const item = edge(result.metric.instance, result.metric.peer);
            item.online = Math.max(item.online ?? 0, root.value(result));
        }

        const builds = [];
        for (const result of results.builds) {
            const count = Math.round(root.value(result));
            if (count > 0)
                builds.push({
                    origin: result.metric.instance,
                    builder: result.metric.builder === "local" ? result.metric.instance : result.metric.builder,
                    count: count
                });
        }

        const pressure = {};
        for (const result of results.pressure)
            pressure[result.metric.instance] = (result.values ?? []).map(([at, value]) => ({
                        at: at,
                        value: parseFloat(value)
                    }));

        const psi = {};
        const psiOf = name => psi[name] ?? (psi[name] = {
                cpu: 0,
                io: 0,
                memory: 0
            });
        for (const result of results.psiCpu)
            psiOf(result.metric.instance).cpu = root.value(result);
        for (const result of results.psiIo)
            psiOf(result.metric.instance).io = root.value(result);
        for (const result of results.psiMemory)
            psiOf(result.metric.instance).memory = root.value(result);

        const deploys = {};
        for (const result of results.rev)
            deploys[result.metric.instance] = {
                rev: (result.metric.rev ?? "unknown").replace(/-dirty$/, ""),
                dirty: (result.metric.rev ?? "").endsWith("-dirty"),
                at: NaN,
                branch: "",
                snapshot: false,
                recorded: false
            };
        for (const result of results.activated)
            if (deploys[result.metric.instance])
                deploys[result.metric.instance].at = root.value(result);
        for (const result of results.deploy) {
            const deploy = deploys[result.metric.instance];
            if (deploy && deploy.rev === result.metric.rev)
                Object.assign(deploy, {
                    at: root.value(result),
                    branch: result.metric.branch,
                    snapshot: result.metric.snapshot === "1",
                    recorded: true
                });
        }

        return {
            from: from,
            to: to,
            nodes: Object.values(nodes),
            edges: Object.values(edges).filter(item => nodes[item.a] && nodes[item.b]),
            builds: builds,
            pressure: pressure,
            psi: psi,
            deploys: deploys
        };
    }

    function deployUrl(deploy: var): string {
        if (!deploy || deploy.rev === "unknown")
            return "";
        if (deploy.recorded && !deploy.snapshot && deploy.branch && deploy.branch !== "detached")
            return `${root.repo}/tree/${deploy.branch}`;
        return `${root.repo}/commit/${deploy.rev}`;
    }

    function ago(seconds: real): string {
        const age = Math.max(0, root.now - seconds);
        if (age < 90)
            return "just now";
        if (age < 5400)
            return `${Math.round(age / 60)} min ago`;
        if (age < 2 * 86400)
            return `${Math.round(age / 3600)} hours ago`;
        return `${Math.round(age / 86400)} days ago`;
    }

    function stamp(seconds: real): string {
        const age = root.now - seconds;
        const format = age < 6 * 86400 ? "ddd HH:mm" : age < 300 * 86400 ? "MM/dd HH:mm" : "yyyy/MM/dd HH:mm";
        return Qt.formatDateTime(new Date(seconds * 1000), format);
    }

    function when(seconds: real): string {
        if (!isFinite(seconds))
            return "";
        return root.following ? root.ago(seconds) : root.stamp(seconds);
    }

    function rate(bytes: real): string {
        const units = ["B/s", "KB/s", "MB/s", "GB/s"];
        let value = bytes;
        let unit = 0;
        while (value >= 1000 && unit < units.length - 1) {
            value /= 1000;
            unit++;
        }
        return `${value < 10 && unit ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
    }

    function axisLabel(seconds: real, span: real): string {
        const format = span > 300 * 86400 ? "yyyy/MM/dd" : span > 6 * 86400 ? "MM/dd" : span > 2 * 86400 ? "ddd HH:mm" : "HH:mm";
        return Qt.formatDateTime(new Date(seconds * 1000), format);
    }
}
