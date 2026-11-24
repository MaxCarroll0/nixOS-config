pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property FleetModel fleet
    readonly property var slice: fleet.slice
    readonly property var current: fleet.current
    readonly property var graphs: fleet.graphs
    readonly property var colours: fleet.colours
    readonly property real legendWidth: 160
    readonly property real coreRadius: 14
    readonly property real pressureScale: 22
    readonly property real pressureClamp: 2
    readonly property real bloomExtent: coreRadius + pressureScale * pressureClamp
    readonly property real blobRadius: 9
    readonly property real blobRim: bloomExtent + 9
    readonly property real hostRow: 136
    readonly property real tunnelTop: 22
    readonly property real peerRow: height - 50
    readonly property real dotSpacing: 26
    property real clock: 0
    property var pointer: null
    property var lanes: []
    property var badges: []
    property var tunnels: []
    property var eased: ({})
    property var phases: ({})
    property var blobs: ({})
    property var paths: ({})
    readonly property var hovered: pointer ? hit(pointer) : null

    readonly property var positions: {
        const out = {};
        const left = root.legendWidth;
        const span = width - left;
        const cx = left + span / 2;
        out.pi = Qt.point(cx, root.hostRow);
        fleet.hosts.filter(name => name !== "pi").forEach((name, index) => {
            const side = index % 2 === 0 ? -1 : 1;
            out[name] = Qt.point(cx + side * (Math.floor(index / 2) + 1) * span * 0.34, root.hostRow);
        });
        const peers = slice.nodes.filter(node => !node.host).sort((a, b) => (a.os + a.name).localeCompare(b.os + b.name));
        peers.forEach((node, index) => {
            const spread = peers.length === 1 ? 0.5 : index / (peers.length - 1);
            out[node.name] = Qt.point(left + span * (0.24 + 0.52 * spread), root.peerRow);
        });
        return out;
    }

    readonly property var nodeByName: {
        const out = {};
        for (const node of slice.nodes)
            out[node.name] = node;
        return out;
    }

    function laneWidth(rate: real): real {
        return Math.max(1, Math.min(8, 1 + 1.5 * Math.log10(Math.max(1, rate) / 1000)));
    }

    function dotSpeed(rate: real): real {
        return rate < 100 ? 0 : Math.min(200, 12 + 34 * Math.log10(rate / 100));
    }

    function edgeState(edge: var): string {
        if (!((root.nodeByName[edge.a]?.up ?? 0) > 0 && (root.nodeByName[edge.b]?.up ?? 0) > 0) && !root.liveEdge(edge))
            return "hidden";
        if ((edge.online ?? 1) <= 0)
            return "offline";
        return isFinite(edge.direct) && edge.direct < 0.5 ? "relayed" : "direct";
    }

    function liveEdge(edge: var): bool {
        const now = root.current.edges[edge.key];
        return root.current.live && !!now && (now.ab >= 100 || now.ba >= 100);
    }

    function liveRate(lane: var): real {
        if (!root.current.live)
            return lane.rate;
        if (lane.tunnel) {
            const now = root.current.tunnels[lane.tunnel.key];
            return now ? (lane.forward ? now.tx : now.rx) : 0;
        }
        const now = root.current.edges[lane.edge.key];
        return now ? (lane.forward ? now.ab : now.ba) : 0;
    }

    function clearance(name: string): real {
        return root.nodeByName[name]?.host ? root.bloomExtent : 16;
    }

    function segmentDistance(p: var, a: var, b: var): real {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / Math.max(1, dx * dx + dy * dy)));
        return Math.hypot(p.x - a.x - t * dx, p.y - a.y - t * dy);
    }

    function curve(edge: var): var {
        const a = root.positions[edge.a];
        const b = root.positions[edge.b];
        if (!a || !b)
            return null;
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const length = Math.max(1, Math.hypot(dx, dy));
        let nx = -dy / length;
        let ny = dx / length;
        if (ny > 0 || (ny === 0 && nx > 0)) {
            nx = -nx;
            ny = -ny;
        }
        const blocked = Object.keys(root.positions).some(name => name !== edge.a && name !== edge.b && root.segmentDistance(root.positions[name], a, b) < root.clearance(name));
        const bend = blocked ? 2 * (root.bloomExtent + 20) : Math.min(30, length * 0.08);
        return {
            a: a,
            b: b,
            c: Qt.point((a.x + b.x) / 2 + nx * bend, (a.y + b.y) / 2 + ny * bend)
        };
    }

    function along(shape: var, u: real, side: real): var {
        const v = 1 - u;
        const x = v * v * shape.a.x + 2 * v * u * shape.c.x + u * u * shape.b.x;
        const y = v * v * shape.a.y + 2 * v * u * shape.c.y + u * u * shape.b.y;
        if (!side)
            return Qt.point(x, y);
        const tx = 2 * v * (shape.c.x - shape.a.x) + 2 * u * (shape.b.x - shape.c.x);
        const ty = 2 * v * (shape.c.y - shape.a.y) + 2 * u * (shape.b.y - shape.c.y);
        const length = Math.max(1e-6, Math.hypot(tx, ty));
        return Qt.point(x - ty / length * side, y + tx / length * side);
    }

    function polyline(points: var): var {
        const cum = [0];
        for (let i = 1; i < points.length; i++)
            cum.push(cum[i - 1] + Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y));
        return {
            points: points,
            cum: cum,
            length: cum[cum.length - 1] ?? 0
        };
    }

    function pointAt(line: var, s: real): var {
        if (line.points.length < 2)
            return line.points[0] ?? Qt.point(0, 0);
        let i = 1;
        while (i < line.cum.length - 1 && line.cum[i] < s)
            i++;
        const span = Math.max(1e-6, line.cum[i] - line.cum[i - 1]);
        const t = Math.max(0, Math.min(1, (s - line.cum[i - 1]) / span));
        const a = line.points[i - 1];
        const b = line.points[i];
        return Qt.point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
    }

    function edgeBetween(a: string, b: string): var {
        return root.slice.edges.find(item => (item.a === a && item.b === b) || (item.a === b && item.b === a)) ?? null;
    }

    function blobPath(origin: string, builder: string): var {
        const key = `${origin}\u001f${builder}`;
        if (root.paths[key])
            return root.paths[key];
        const from = root.positions[origin];
        const to = root.positions[builder];
        if (!from || !to)
            return null;
        const edge = root.edgeBetween(origin, builder);
        const shape = edge ? root.curve(edge) : {
            a: from,
            b: to,
            c: Qt.point((from.x + to.x) / 2, (from.y + to.y) / 2)
        };
        const points = [];
        for (let i = 0; i <= 64; i++) {
            const u = edge && edge.a !== origin ? 1 - i / 64 : i / 64;
            const point = root.along(shape, u, 0);
            if (Math.hypot(point.x - from.x, point.y - from.y) > root.coreRadius + 6 && Math.hypot(point.x - to.x, point.y - to.y) > root.blobRim)
                points.push(point);
        }
        const line = root.polyline(points);
        root.paths[key] = line;
        return line;
    }

    function rebuild(): void {
        const lanes = [];
        const badges = [];
        const tunnels = [];
        root.paths = {};
        for (const edge of root.slice.edges) {
            const shape = root.curve(edge);
            const state = root.edgeState(edge);
            if (!shape || state === "hidden" || state === "offline")
                continue;
            const now = root.current.edges[edge.key];
            for (const [rate, forward] of [[edge.ab, true], [edge.ba, false]]) {
                const live = root.current.live ? (now ? (forward ? now.ab : now.ba) : 0) : rate;
                if (!(rate >= 100) && !(live >= 100))
                    continue;
                const width = root.laneWidth(rate);
                const side = (forward ? 1 : -1) * (1.5 + width / 2);
                const clipA = root.nodeByName[edge.a]?.host ? root.coreRadius + 2 : 7;
                const clipB = root.nodeByName[edge.b]?.host ? root.coreRadius + 2 : 7;
                let points = [];
                for (let i = 0; i <= 64; i++) {
                    const point = root.along(shape, i / 64, side);
                    if (Math.hypot(point.x - shape.a.x, point.y - shape.a.y) > clipA && Math.hypot(point.x - shape.b.x, point.y - shape.b.y) > clipB)
                        points.push(point);
                }
                if (!forward)
                    points = points.reverse();
                const u = forward ? 0.3 : 0.7;
                const base = root.along(shape, u, side);
                const out = root.along(shape, u, side + Math.sign(side) * (width / 2 + 6));
                lanes.push(Object.assign(root.polyline(points), {
                    key: `${edge.key}\u001f${forward}`,
                    edge: edge,
                    forward: forward,
                    rate: rate,
                    width: width,
                    label: out,
                    normal: Qt.point(out.x - base.x, out.y - base.y)
                }));
            }
        }

        const centre = root.positions.pi;
        for (const host of root.fleet.hosts) {
            const origin = root.positions[host];
            const list = (root.slice.tunnels ?? []).filter(tunnel => tunnel.host === host).sort((a, b) => a.iface.localeCompare(b.iface));
            if (!origin || !centre)
                continue;
            list.forEach((tunnel, index) => {
                const tilt = Math.sign(origin.x - centre.x) * 0.3;
                const angle = -Math.PI / 2 + tilt + (index - (list.length - 1) / 2) * 0.42;
                const dx = Math.cos(angle);
                const dy = Math.sin(angle);
                const start = Qt.point(origin.x + dx * (root.bloomExtent + 4), origin.y + dy * (root.bloomExtent + 4));
                const reach = Math.max(24, (start.y - root.tunnelTop) / Math.max(0.2, -dy));
                const end = Qt.point(start.x + dx * reach, start.y + dy * reach);
                const live = root.current.tunnels[tunnel.key] ?? {
                    tx: 0,
                    rx: 0
                };
                const txWidth = root.laneWidth(Math.max(tunnel.tx, 1));
                const rxWidth = root.laneWidth(Math.max(tunnel.rx, 1));
                const width = txWidth + rxWidth + 10;
                const nx = -dy;
                const ny = dx;
                const offset = width / 4;
                tunnels.push({
                    tunnel: tunnel,
                    start: start,
                    end: end,
                    width: width,
                    colour: tunnel.country ? root.fleet.countryColour(tunnel.country) : Colours.palette.m3onSurfaceVariant
                });
                for (const [rate, forward, laneWidth] of [[tunnel.tx, true, txWidth], [tunnel.rx, false, rxWidth]]) {
                    const sign = forward ? 1 : -1;
                    const a = Qt.point(start.x + nx * offset * sign, start.y + ny * offset * sign);
                    const b = Qt.point(end.x + nx * offset * sign, end.y + ny * offset * sign);
                    lanes.push(Object.assign(root.polyline(forward ? [a, b] : [b, a]), {
                        key: `${tunnel.key}\u001f${forward}`,
                        tunnel: tunnel,
                        forward: forward,
                        rate: rate,
                        width: laneWidth,
                        label: null
                    }));
                }
            });
        }

        for (const build of root.slice.builds) {
            const origin = root.positions[build.origin];
            if (!origin)
                continue;
            const local = build.origin === build.builder;
            const text = `⚙ ${build.count}`;
            const width = text.length * 6.5 + 12;
            if (local) {
                const reach = root.bloomExtent * 0.78;
                badges.push({
                    build: build,
                    text: text,
                    width: width,
                    at: Qt.point(origin.x + reach, origin.y + reach)
                });
                continue;
            }
            const edge = root.edgeBetween(build.origin, build.builder);
            const shape = edge ? root.curve(edge) : null;
            if (!shape)
                continue;
            const forward = edge.a === build.origin;
            const at = root.along(shape, 0.5, 0);
            const ahead = root.along(shape, forward ? 0.5 + 0.06 : 0.5 - 0.06, 0);
            badges.push({
                build: build,
                text: text,
                width: width,
                at: at,
                angle: Math.atan2(ahead.y - at.y, ahead.x - at.x)
            });
        }
        root.lanes = lanes;
        root.badges = badges;
        root.tunnels = tunnels;
    }

    function syncBlobs(): void {
        if (!root.current.live) {
            root.blobs = {};
            return;
        }
        const seen = new Set();
        for (const build of root.current.builds) {
            seen.add(build.key);
            let blob = root.blobs[build.key];
            if (!blob)
                blob = root.blobs[build.key] = {
                    key: build.key,
                    phase: build.phase,
                    changedAt: root.clock - 10,
                    shown: build.progress,
                    missingSince: -1,
                    last: null
                };
            if (blob.phase !== build.phase) {
                blob.phase = build.phase;
                blob.changedAt = root.clock;
                if (build.phase === "download")
                    blob.shown = 0;
            }
            blob.build = build;
            blob.missingSince = -1;
        }
        for (const key of Object.keys(root.blobs)) {
            if (seen.has(key))
                continue;
            const blob = root.blobs[key];
            if (blob.missingSince < 0)
                blob.missingSince = root.clock;
            if (root.clock - blob.missingSince < 3)
                continue;
            if (blob.phase !== "done" && blob.phase !== "failed") {
                blob.phase = "done";
                blob.changedAt = root.clock;
            }
            if (root.clock - blob.changedAt > 3)
                delete root.blobs[key];
        }
    }

    function tick(dt: real): void {
        const blend = 1 - Math.exp(-dt / 0.3);
        for (const lane of root.lanes) {
            const target = root.liveRate(lane);
            const value = root.eased[lane.key] ?? target;
            const next = value + (target - value) * blend;
            root.eased[lane.key] = next;
            root.phases[lane.key] = ((root.phases[lane.key] ?? Math.random() * root.dotSpacing) + root.dotSpeed(next) * dt) % root.dotSpacing;
        }
        const follow = 1 - Math.exp(-dt / 0.4);
        for (const blob of Object.values(root.blobs)) {
            const target = blob.phase === "done" ? 1 : blob.build.progress;
            blob.shown += (target - blob.shown) * follow;
        }
        root.clock += dt;
    }

    function slots(): var {
        const groups = {};
        for (const blob of Object.values(root.blobs)) {
            const build = blob.build;
            const local = build.origin === build.builder;
            if (!local && blob.phase !== "build")
                continue;
            const group = local ? `local\u001f${build.origin}` : build.builder;
            (groups[group] = groups[group] ?? []).push(blob.key);
        }
        const out = {};
        for (const keys of Object.values(groups))
            keys.sort().forEach((key, index) => out[key] = index - (keys.length - 1) / 2);
        return out;
    }

    function blobPlace(blob: var, slot: real): var {
        const build = blob.build;
        const origin = root.positions[build.origin];
        if (!origin)
            return null;
        const around = (centre, angle) => Qt.point(centre.x + Math.cos(angle) * root.blobRim, centre.y + Math.sin(angle) * root.blobRim);
        if (build.origin === build.builder)
            return around(origin, -Math.PI / 4 + slot * 0.38);
        const builder = root.positions[build.builder];
        const path = root.blobPath(build.origin, build.builder);
        if (!builder || !path || path.points.length < 2)
            return null;
        switch (blob.phase) {
        case "upload":
            return root.pointAt(path, blob.shown * path.length);
        case "build":
            {
                const end = path.points[path.points.length - 1];
                return around(builder, Math.atan2(end.y - builder.y, end.x - builder.x) + slot * 0.38);
            }
        case "download":
            return root.pointAt(path, (1 - blob.shown) * path.length);
        case "done":
            return path.points[0];
        default:
            return blob.last ?? path.points[0];
        }
    }

    function hit(p: var): var {
        for (const blob of Object.values(root.blobs))
            if (blob.last && Math.hypot(p.x - blob.last.x, p.y - blob.last.y) <= root.blobRadius + 3)
                return {
                    kind: "blob",
                    item: blob
                };
        for (const badge of root.badges)
            if (Math.abs(p.x - badge.at.x) <= badge.width / 2 + 2 && Math.abs(p.y - badge.at.y) <= 10)
                return {
                    kind: "build",
                    item: badge.build
                };
        for (const node of root.slice.nodes) {
            const centre = root.positions[node.name];
            if (centre && Math.hypot(p.x - centre.x, p.y - centre.y) <= (node.host ? root.coreRadius + 12 : 10))
                return {
                    kind: "node",
                    item: node
                };
        }
        for (const sheath of root.tunnels)
            if (root.segmentDistance(p, sheath.start, sheath.end) <= sheath.width / 2 + 2 || Math.hypot(p.x - sheath.end.x, p.y - (sheath.end.y - 8)) < 24)
                return {
                    kind: "tunnel",
                    item: sheath.tunnel
                };
        let best = null;
        let bestDistance = 9;
        for (const edge of root.slice.edges) {
            const shape = root.curve(edge);
            if (!shape || root.edgeState(edge) === "hidden")
                continue;
            for (let u = 0.04; u <= 0.96; u += 0.02) {
                const point = root.along(shape, u, 0);
                const distance = Math.hypot(point.x - p.x, point.y - p.y);
                if (distance < bestDistance) {
                    bestDistance = distance;
                    best = edge;
                }
            }
        }
        return best ? {
            kind: "edge",
            item: best
        } : null;
    }

    function nowAndAverage(now: real, average: real, format: var): string {
        return root.current.live ? `now ${format(now)}, avg ${format(average)}` : `avg ${format(average)}`;
    }

    function describe(hovered: var): var {
        if (!hovered)
            return [];
        const fleet = root.fleet;
        const window = `avg over last ${fleet.span(fleet.smoothing)}`;
        const item = hovered.item;
        const primary = Colours.palette.m3primary;
        const tertiary = Colours.palette.m3tertiary;
        if (hovered.kind === "blob") {
            const build = item.build;
            const local = build.origin === build.builder;
            const phase = {
                upload: `uploading ${fleet.percent(build.progress)}`,
                build: "building",
                download: `downloading ${fleet.percent(build.progress)}`,
                done: "done",
                failed: "failed"
            }[item.phase] ?? item.phase;
            return [[build.package || "build", ""], [local ? `local build on ${build.origin}` : `${build.origin} → ${build.builder}`, ""], [phase, item.phase === "failed" ? root.colours.offline : item.phase === "download" || item.phase === "done" ? tertiary : primary], [isFinite(build.since) ? `since ${fleet.ago(build.since)}` : "", ""]].filter(line => line[0] !== "");
        }
        if (hovered.kind === "build")
            return item.origin === item.builder ? [[`${item.origin}: ${item.count} local builds`, ""], [`last ${fleet.span(fleet.smoothing)}`, ""]] : [[`${item.origin} → ${item.builder}`, ""], [`${item.count} builds sent to ${item.builder}`, ""], [`last ${fleet.span(fleet.smoothing)}`, ""]];
        if (hovered.kind === "tunnel") {
            const now = root.current.tunnels[item.key] ?? {
                tx: 0,
                rx: 0
            };
            const country = item.country ? ` (${item.country})` : "";
            return [[`${item.host} → ${item.server || item.iface}${country}`, ""], [item.enabled > 0.5 ? `VPN on, ${item.iface}` : `VPN off, ${item.iface} bypassed`, item.country ? fleet.countryColour(item.country) : ""], [`up ${root.nowAndAverage(now.tx, item.tx, fleet.rate)}`, primary], [`down ${root.nowAndAverage(now.rx, item.rx, fleet.rate)}`, tertiary], [window, ""]];
        }
        if (hovered.kind === "edge") {
            const state = root.edgeState(item);
            const path = state === "offline" ? "unreachable" : state === "relayed" ? `relayed via DERP ${item.relay || "?"}` : "direct";
            const now = root.current.edges[item.key] ?? {
                ab: 0,
                ba: 0
            };
            const a = fleet.displayName(item.a);
            const b = fleet.displayName(item.b);
            return [[`${a} ⇄ ${b}`, ""], [path, root.colours[state]], [`${a} → ${b}  ${root.nowAndAverage(now.ab, item.ab, fleet.rate)}`, primary], [`${b} → ${a}  ${root.nowAndAverage(now.ba, item.ba, fleet.rate)}`, tertiary], [window, ""]];
        }
        const name = item.name;
        let sent = 0;
        let received = 0;
        for (const edge of root.slice.edges) {
            if (edge.a === name) {
                sent += edge.ab;
                received += edge.ba;
            } else if (edge.b === name) {
                sent += edge.ba;
                received += edge.ab;
            }
        }
        const lines = [[fleet.displayName(name), ""]];
        if (!item.host && item.os)
            lines.push([item.os, ""]);
        lines.push([item.up > 0 ? `online ${fleet.percent(item.up)} of last ${fleet.span(fleet.smoothing)}` : `offline for last ${fleet.span(fleet.smoothing)}`, item.up > 0 ? "" : root.colours.offline]);
        if (item.host) {
            const values = (root.slice.pressure[name] ?? []).map(sample => sample.value).filter(isFinite);
            if (values.length) {
                const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
                const now = root.current.load[name];
                lines.push([`load per core  ${root.nowAndAverage(now ?? NaN, mean, fleet.percent)}, peak ${fleet.percent(Math.max(...values))}`, ""]);
            }
            const psi = root.slice.psi[name];
            const live = root.current.psi[name] ?? {};
            if (psi) {
                lines.push([`cpu stall ${root.nowAndAverage(live.cpu ?? NaN, psi.cpu, fleet.percent)}`, root.colours.cpu]);
                lines.push([`io stall ${root.nowAndAverage(live.io ?? NaN, psi.io, fleet.percent)}`, root.colours.io]);
                lines.push([`memory stall ${root.nowAndAverage(live.memory ?? NaN, psi.memory, fleet.percent)}`, root.colours.memory]);
            }
        }
        lines.push([`sends ${fleet.rate(sent)}, receives ${fleet.rate(received)}, ${window}`, ""]);
        return lines;
    }

    function graphOf(hovered: var): var {
        if (!hovered)
            return null;
        const graphs = root.graphs;
        const base = {
            from: graphs.from,
            step: graphs.step,
            span: root.fleet.span(root.fleet.smoothing)
        };
        const primary = Colours.palette.m3primary;
        const tertiary = Colours.palette.m3tertiary;
        if (hovered.kind === "edge") {
            const series = graphs.edges[hovered.item.key];
            return series ? Object.assign(base, {
                log: true,
                format: root.fleet.rate,
                series: [
                    {
                        values: series.ab,
                        colour: primary
                    },
                    {
                        values: series.ba,
                        colour: tertiary
                    }
                ]
            }) : null;
        }
        if (hovered.kind === "tunnel") {
            const series = graphs.tunnels[hovered.item.key];
            return series ? Object.assign(base, {
                log: true,
                format: root.fleet.rate,
                series: [
                    {
                        values: series.tx ?? [],
                        colour: primary
                    },
                    {
                        values: series.rx ?? [],
                        colour: tertiary
                    }
                ]
            }) : null;
        }
        if (hovered.kind === "node" && hovered.item.host) {
            const series = graphs.psi[hovered.item.name];
            return series ? Object.assign(base, {
                log: false,
                format: root.fleet.percent,
                series: ["cpu", "io", "memory"].map(key => ({
                            values: series[key] ?? [],
                            colour: root.colours[key]
                        }))
            }) : null;
        }
        return null;
    }

    onSliceChanged: Qt.callLater(rebuild)
    onPositionsChanged: Qt.callLater(rebuild)
    onCurrentChanged: {
        syncBlobs();
        Qt.callLater(rebuild);
        canvas.requestPaint();
    }
    onLanesChanged: {
        canvas.requestPaint();
        flow.requestPaint();
    }
    onClockChanged: flow.requestPaint()
    onHoveredChanged: canvas.requestPaint()

    Connections {
        target: Colours
        function onPaletteChanged(): void {
            canvas.requestPaint();
            flow.requestPaint();
        }
    }

    Timer {
        property real last: 0

        interval: 33
        repeat: true
        running: root.visible && root.fleet.active
        onRunningChanged: last = Date.now()
        onTriggered: {
            const now = Date.now();
            root.tick(Math.min(0.2, Math.max(0, (now - last) / 1000)));
            last = now;
        }
    }

    Canvas {
        id: canvas

        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        function drawEdge(ctx: var, edge: var): void {
            const state = root.edgeState(edge);
            const shape = root.curve(edge);
            if (!shape || state === "hidden")
                return;
            const hovered = root.hovered?.kind === "edge" && root.hovered.item === edge;
            ctx.save();
            ctx.beginPath();
            ctx.moveTo(shape.a.x, shape.a.y);
            ctx.quadraticCurveTo(shape.c.x, shape.c.y, shape.b.x, shape.b.y);
            ctx.lineWidth = hovered ? 3 : 1.5;
            ctx.lineCap = "round";
            ctx.strokeStyle = root.colours[state];
            ctx.setLineDash(state === "offline" ? [0.5, 4] : state === "relayed" ? [6, 4] : []);
            ctx.stroke();
            ctx.restore();
        }

        function drawLane(ctx: var, lane: var): void {
            if (lane.tunnel || lane.points.length < 2)
                return;
            const hovered = root.hovered?.kind === "edge" && root.hovered.item === lane.edge;
            ctx.beginPath();
            ctx.moveTo(lane.points[0].x, lane.points[0].y);
            for (const point of lane.points.slice(1))
                ctx.lineTo(point.x, point.y);
            ctx.lineWidth = lane.width;
            ctx.lineCap = "butt";
            ctx.strokeStyle = Qt.alpha(Colours.palette.m3onSurfaceVariant, hovered ? 0.6 : 0.38);
            ctx.stroke();
        }

        function drawRate(ctx: var, lane: var): void {
            const rate = root.liveRate(lane);
            if (!lane.label || rate < 1000)
                return;
            const n = lane.normal;
            const length = Math.max(1e-6, Math.hypot(n.x, n.y));
            ctx.font = "10px sans-serif";
            if (Math.abs(n.x / length) > 0.6) {
                ctx.textAlign = n.x > 0 ? "left" : "right";
                ctx.textBaseline = "middle";
            } else {
                ctx.textAlign = "center";
                ctx.textBaseline = n.y > 0 ? "top" : "bottom";
            }
            const text = root.fleet.rate(rate);
            ctx.lineWidth = 3;
            ctx.strokeStyle = Colours.palette.m3surfaceContainer;
            ctx.strokeText(text, lane.label.x, lane.label.y);
            ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
            ctx.fillText(text, lane.label.x, lane.label.y);
        }

        function drawSheath(ctx: var, sheath: var): void {
            const on = sheath.tunnel.enabled > 0.5;
            const hovered = root.hovered?.kind === "tunnel" && root.hovered.item === sheath.tunnel;
            ctx.save();
            ctx.lineCap = "round";
            ctx.beginPath();
            ctx.moveTo(sheath.start.x, sheath.start.y);
            ctx.lineTo(sheath.end.x, sheath.end.y);
            ctx.lineWidth = sheath.width + 3;
            ctx.strokeStyle = Qt.alpha(sheath.colour, hovered ? 1 : 0.85);
            ctx.setLineDash(on ? [] : [4, 3]);
            ctx.stroke();
            ctx.setLineDash([]);
            ctx.globalCompositeOperation = "destination-out";
            ctx.lineWidth = sheath.width;
            ctx.strokeStyle = "#000000";
            ctx.stroke();
            ctx.globalCompositeOperation = "source-over";
            if (on) {
                ctx.strokeStyle = Qt.alpha(sheath.colour, 0.3);
                ctx.stroke();
            }
            ctx.restore();
            ctx.font = "bold 10px sans-serif";
            ctx.textAlign = "center";
            ctx.textBaseline = "bottom";
            const text = sheath.tunnel.server || sheath.tunnel.iface;
            const at = Qt.point(sheath.end.x, sheath.end.y - sheath.width / 2 - 3);
            ctx.lineWidth = 3;
            ctx.strokeStyle = Colours.palette.m3surfaceContainer;
            ctx.strokeText(text, at.x, at.y);
            ctx.fillStyle = on ? sheath.colour : Colours.palette.m3outline;
            ctx.fillText(text, at.x, at.y);
        }

        function petal(ctx: var, centre: var, angle: real, length: real): void {
            const spread = 0.4;
            ctx.beginPath();
            ctx.moveTo(centre.x, centre.y);
            ctx.quadraticCurveTo(centre.x + Math.cos(angle - spread) * length * 1.15, centre.y + Math.sin(angle - spread) * length * 1.15, centre.x + Math.cos(angle) * length, centre.y + Math.sin(angle) * length);
            ctx.quadraticCurveTo(centre.x + Math.cos(angle + spread) * length * 1.15, centre.y + Math.sin(angle + spread) * length * 1.15, centre.x, centre.y);
        }

        function smallLabel(ctx: var, text: string, at: var, colour: var): void {
            ctx.font = "9px sans-serif";
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            ctx.lineWidth = 3;
            ctx.strokeStyle = Colours.palette.m3surfaceContainer;
            ctx.strokeText(text, at.x, at.y);
            ctx.fillStyle = colour;
            ctx.fillText(text, at.x, at.y);
        }

        function drawBloom(ctx: var, name: string, centre: var): void {
            const r0 = root.coreRadius;
            const scale = value => r0 + root.pressureScale * Math.min(root.pressureClamp, Math.max(0, value));
            const average = root.slice.psi[name] ?? {
                cpu: 0,
                io: 0,
                memory: 0
            };
            const live = root.current.live ? (root.current.psi[name] ?? average) : average;
            const samples = (root.slice.pressure[name] ?? []).filter(sample => isFinite(sample.value));
            const loadNow = root.current.live ? root.current.load[name] : samples[samples.length - 1]?.value;

            if (isFinite(loadNow)) {
                ctx.beginPath();
                ctx.arc(centre.x, centre.y, scale(loadNow), 0, Math.PI * 2);
                ctx.fillStyle = Qt.alpha(Colours.palette.m3onSurface, 0.1);
                ctx.fill();
            }

            if (samples.length >= 2) {
                const [from, to] = [root.slice.from, root.slice.to];
                const points = samples.map(sample => {
                    const angle = -Math.PI / 2 + 2 * Math.PI * (sample.at - from) / Math.max(1, to - from);
                    const radius = scale(sample.value);
                    return Qt.point(centre.x + Math.cos(angle) * radius, centre.y + Math.sin(angle) * radius);
                });
                const mid = (a, b) => Qt.point((a.x + b.x) / 2, (a.y + b.y) / 2);
                const n = points.length;
                ctx.beginPath();
                const start = mid(points[n - 1], points[0]);
                ctx.moveTo(start.x, start.y);
                points.forEach((point, index) => {
                    const next = mid(point, points[(index + 1) % n]);
                    ctx.quadraticCurveTo(point.x, point.y, next.x, next.y);
                });
                ctx.closePath();
                ctx.strokeStyle = Qt.alpha(Colours.palette.m3onSurface, 0.4);
                ctx.lineWidth = 1;
                ctx.stroke();
            }

            ctx.save();
            ctx.setLineDash([2, 3]);
            ctx.strokeStyle = Qt.alpha(Colours.palette.m3onSurfaceVariant, 0.6);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.arc(centre.x, centre.y, r0 + root.pressureScale, 0, Math.PI * 2);
            ctx.stroke();
            ctx.restore();

            if (samples.length) {
                const mean = samples.reduce((sum, sample) => sum + sample.value, 0) / samples.length;
                const radius = scale(mean);
                ctx.beginPath();
                ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2);
                ctx.strokeStyle = Colours.palette.m3onSurface;
                ctx.lineWidth = 2.25;
                ctx.stroke();
                const angle = -Math.PI / 4;
                canvas.smallLabel(ctx, root.fleet.percent(mean), Qt.point(centre.x + Math.cos(angle) * (radius + 9), centre.y + Math.sin(angle) * (radius + 9)), Colours.palette.m3onSurface);
            }

            const length = ratio => r0 + 40 * Math.sqrt(Math.min(1, ratio));
            for (const [key, angle] of [["cpu", -Math.PI / 2], ["io", Math.PI / 6], ["memory", 5 * Math.PI / 6]]) {
                const now = live[key] ?? 0;
                if (now > 0.001) {
                    canvas.petal(ctx, centre, angle, length(now));
                    ctx.fillStyle = Qt.alpha(root.colours[key], 0.45);
                    ctx.fill();
                }
                const mean = average[key] ?? 0;
                if (mean > 0.001) {
                    canvas.petal(ctx, centre, angle, length(mean));
                    ctx.strokeStyle = root.colours[key];
                    ctx.lineWidth = 2.25;
                    ctx.stroke();
                    const reach = length(mean) + 8;
                    canvas.smallLabel(ctx, root.fleet.percent(mean), Qt.point(centre.x + Math.cos(angle) * reach, centre.y + Math.sin(angle) * reach), root.colours[key]);
                }
            }
        }

        function drawNode(ctx: var, node: var): void {
            const centre = root.positions[node.name];
            if (!centre)
                return;
            if (node.host)
                canvas.drawBloom(ctx, node.name, centre);
            const radius = node.host ? 5.5 : 4.5;
            ctx.beginPath();
            ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2);
            if (node.up > 0) {
                ctx.fillStyle = node.host ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant;
                ctx.fill();
            }
            const partial = node.up > 0 && node.up < 0.99;
            ctx.strokeStyle = node.up > 0 && !partial ? Colours.palette.m3surfaceContainer : root.colours.offline;
            ctx.lineWidth = partial || node.up <= 0 ? 2 : 1.5;
            ctx.stroke();
            if (root.hovered?.kind === "node" && root.hovered.item === node) {
                ctx.beginPath();
                ctx.arc(centre.x, centre.y, radius + 4, 0, Math.PI * 2);
                ctx.strokeStyle = Colours.palette.m3onSurface;
                ctx.lineWidth = 1.5;
                ctx.stroke();
            }
        }

        function drawBadge(ctx: var, badge: var): void {
            const at = badge.at;
            const hovered = root.hovered?.kind === "build" && root.hovered.item === badge.build;
            if (badge.angle !== undefined) {
                ctx.save();
                ctx.translate(at.x + Math.cos(badge.angle) * (badge.width / 2 + 7), at.y + Math.sin(badge.angle) * (badge.width / 2 + 7));
                ctx.rotate(badge.angle);
                ctx.fillStyle = Colours.palette.m3onSurface;
                ctx.beginPath();
                ctx.moveTo(5, 0);
                ctx.lineTo(-3, -4.5);
                ctx.lineTo(-3, 4.5);
                ctx.closePath();
                ctx.fill();
                ctx.restore();
            }
            ctx.fillStyle = Colours.palette.m3surfaceContainerHighest;
            ctx.strokeStyle = hovered ? Colours.palette.m3onSurface : Colours.palette.m3outline;
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.roundedRect(at.x - badge.width / 2, at.y - 8, badge.width, 16, 8, 8);
            ctx.fill();
            ctx.stroke();
            ctx.font = "bold 10px sans-serif";
            ctx.fillStyle = Colours.palette.m3onSurface;
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            ctx.fillText(badge.text, at.x, at.y);
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            for (const sheath of root.tunnels)
                canvas.drawSheath(ctx, sheath);
            for (const lane of root.lanes)
                canvas.drawLane(ctx, lane);
            for (const edge of root.slice.edges)
                canvas.drawEdge(ctx, edge);
            for (const node of root.slice.nodes)
                canvas.drawNode(ctx, node);
            for (const lane of root.lanes)
                canvas.drawRate(ctx, lane);
            for (const badge of root.badges)
                canvas.drawBadge(ctx, badge);
        }
    }

    Canvas {
        id: flow

        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        function drawDots(ctx: var, lane: var): void {
            const rate = root.eased[lane.key] ?? 0;
            if (rate < 100 || lane.points.length < 2)
                return;
            ctx.globalAlpha = Math.min(1, Math.log10(rate / 100) + 0.35);
            ctx.fillStyle = lane.tunnel && lane.tunnel.enabled <= 0.5 ? Colours.palette.m3outline : Colours.palette.m3onSurface;
            const radius = Math.max(1.4, root.laneWidth(rate) / 2 + 0.4);
            for (let s = root.phases[lane.key] ?? 0; s < lane.length; s += root.dotSpacing) {
                const point = root.pointAt(lane, s);
                ctx.beginPath();
                ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
                ctx.fill();
            }
            ctx.globalAlpha = 1;
        }

        function drawBlob(ctx: var, blob: var, slot: real): void {
            const place = root.blobPlace(blob, slot);
            if (!place)
                return;
            blob.last = place;
            const age = root.clock - blob.changedAt;
            const pop = Math.min(1, age / 0.6);
            const palette = Colours.palette;
            const colour = blob.phase === "failed" ? root.colours.offline : blob.phase === "download" || blob.phase === "done" ? palette.m3tertiary : palette.m3primary;
            let radius = root.blobRadius;
            let alpha = 1;
            if (blob.phase === "build")
                radius += 1.3 * Math.sin(root.clock * 5);
            if (blob.phase === "download")
                radius *= 1 + 0.6 * (1 - pop) * Math.sin(Math.PI * pop);
            if (blob.phase === "done") {
                radius *= 1 - pop;
                alpha = 1 - pop;
            }
            if (blob.phase === "failed")
                alpha = Math.max(0, 1 - age / 1.5);
            if (alpha <= 0 || radius <= 0.2) {
                if (pop >= 1)
                    return;
            }
            if (age < 0.6 && blob.phase !== "upload" && blob.phase !== "build") {
                ctx.beginPath();
                ctx.arc(place.x, place.y, root.blobRadius + 20 * pop, 0, Math.PI * 2);
                ctx.strokeStyle = Qt.alpha(colour, 1 - pop);
                ctx.lineWidth = 3 * (1 - pop) + 0.5;
                ctx.stroke();
            }
            if (radius > 0.2) {
                ctx.beginPath();
                ctx.arc(place.x, place.y, radius, 0, Math.PI * 2);
                ctx.fillStyle = Qt.alpha(colour, 0.9 * alpha);
                ctx.fill();
                ctx.strokeStyle = Qt.alpha(palette.m3surfaceContainer, alpha);
                ctx.lineWidth = 1.5;
                ctx.stroke();
                if (age < 0.5 && blob.phase !== "upload" && blob.phase !== "build") {
                    ctx.fillStyle = Qt.alpha("#ffffff", 0.9 * (1 - age / 0.5));
                    ctx.fill();
                }
            }
            if (blob.phase === "upload" || blob.phase === "download") {
                ctx.beginPath();
                ctx.arc(place.x, place.y, root.blobRadius + 3, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.max(0, Math.min(1, blob.shown)));
                ctx.strokeStyle = colour;
                ctx.lineWidth = 2;
                ctx.stroke();
            }
            if (root.hovered?.kind === "blob" && root.hovered.item === blob) {
                ctx.beginPath();
                ctx.arc(place.x, place.y, root.blobRadius + 6, 0, Math.PI * 2);
                ctx.strokeStyle = palette.m3onSurface;
                ctx.lineWidth = 1.5;
                ctx.stroke();
            }
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            for (const lane of root.lanes)
                flow.drawDots(ctx, lane);
            const slots = root.slots();
            for (const blob of Object.values(root.blobs))
                flow.drawBlob(ctx, blob, slots[blob.key] ?? 0);
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: mouse => root.pointer = Qt.point(mouse.x, mouse.y)
        onExited: root.pointer = null
        onWheel: wheel => {
            const steps = [60, 300, 600, 1800, 3600, 3 * 3600, 6 * 3600];
            const index = steps.findIndex(step => step >= root.fleet.smoothing);
            const next = wheel.angleDelta.y > 0 ? Math.max(0, index - 1) : Math.min(steps.length - 1, index + 1);
            root.fleet.smoothing = steps[next];
        }
    }

    Repeater {
        model: root.slice.nodes

        delegate: Rectangle {
            id: label

            required property var modelData
            readonly property var centre: root.positions[modelData.name] ?? Qt.point(-1000, -1000)
            readonly property var deploy: root.slice.deploys[modelData.name] ?? null

            x: centre.x - width / 2
            y: modelData.host ? centre.y + root.bloomExtent + 2 : centre.y + 8
            implicitWidth: column.implicitWidth + 12
            implicitHeight: column.implicitHeight + 4
            radius: 6
            color: Qt.alpha(Colours.palette.m3surfaceContainer, 0.9)

            ColumnLayout {
                id: column

                anchors.centerIn: parent
                spacing: 0

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.fleet.displayName(label.modelData.name)
                    font: label.modelData.host ? Tokens.font.title.small : Tokens.font.body.small
                    color: label.modelData.up > 0 ? Colours.palette.m3onSurface : Colours.palette.m3outline
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    visible: label.deploy !== null
                    readonly property string url: root.fleet.deployUrl(label.deploy)
                    text: {
                        const deploy = label.deploy;
                        if (!deploy)
                            return "";
                        const rev = deploy.rev.slice(0, 7);
                        if (!deploy.recorded)
                            return rev;
                        return deploy.snapshot ? `snapshot ${rev} on ${deploy.branch}` : `${deploy.branch} ${rev}`;
                    }
                    font: Tokens.font.body.small
                    color: url ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant

                    MouseArea {
                        id: linkArea

                        anchors.fill: parent
                        enabled: parent.url !== ""
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onClicked: Qt.openUrlExternally(parent.url)
                    }
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    visible: label.deploy !== null && isFinite(label.deploy.at)
                    text: label.deploy ? `deployed ${root.fleet.when(label.deploy.at)}` : ""
                    font: Tokens.font.label.small
                    color: Colours.palette.m3onSurfaceVariant
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    visible: label.deploy !== null && label.deploy.staged !== ""
                    text: label.deploy ? `${label.deploy.staged.slice(0, 7)} staged for boot ${root.fleet.when(label.deploy.stagedAt)}` : ""
                    font: Tokens.font.label.small
                    color: Colours.palette.m3tertiary
                }
            }
        }
    }

    FleetTooltip {
        at: root.pointer ?? Qt.point(0, 0)
        boundsWidth: root.width
        boundsHeight: root.height
        lines: root.describe(root.hovered)
        graph: root.graphOf(root.hovered)
    }
}
