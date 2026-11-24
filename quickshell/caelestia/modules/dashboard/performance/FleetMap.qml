pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property FleetModel fleet
    readonly property var slice: fleet.slice
    readonly property bool fresh: current.live && fleet.preview === null
    readonly property var current: fleet.current
    readonly property var graphs: fleet.graphs
    readonly property var colours: fleet.colours
    readonly property real legendWidth: 250
    readonly property real coreRadius: 14
    readonly property real pressureScale: 28
    readonly property real pressureClamp: 2
    readonly property real bloomExtent: coreRadius + pressureScale * Math.sqrt(pressureClamp)
    readonly property real stallRadius: bloomExtent + 6
    readonly property real stallGap: 0.12
    readonly property real blobRadius: 9
    readonly property real blobRim: stallRadius + 10
    readonly property real hostRow: 136
    readonly property real tunnelTop: 22
    readonly property real peerRow: height - 50
    readonly property real dotGrid: 9
    readonly property real dotSpeed: 14
    readonly property real blobTravel: 1.5
    readonly property real blobDwell: 0.6
    property real clock: 0
    property var pointer: null
    property var lanes: []
    property var badges: []
    property var tunnels: []
    property var eased: ({})
    property var phases: ({})
    property var blobs: ({})
    property var paths: ({})
    property var histories: ({})
    property var bloomShown: ({})
    property var place: ({})
    property var widths: ({})
    property var nodeFade: ({})
    property var edgeFade: ({})
    property var laneFade: ({})
    property var sheathFade: ({})
    property var badgeFade: ({})
    property var edgeLooks: ({})
    property var shownUp: ({})
    property var tunnelOn: ({})
    property var nodeNames: []
    property var nodeAlpha: ({})
    readonly property int bloomSteps: 96
    readonly property int boxColumns: 8
    readonly property int boxRows: 3
    readonly property real boxCell: 11
    readonly property real boxReach: 104
    property var boxCounts: ({})
    property var boxFade: ({})
    property var boxHeights: ({})
    readonly property var hovered: pointer ? hit(pointer) : null

    property var order: []
    property var raised: []
    property var dragging: null
    property var emitted: ({})

    function isHost(name: string): bool {
        return !!root.nodeByName[name]?.host || fleet.hosts.includes(name);
    }

    function upper(name: string): bool {
        return root.isHost(name) || root.raised.includes(name);
    }

    function arranged(defaults: var): var {
        const slots = Object.values(defaults).sort((a, b) => a.x - b.x);
        const names = Object.keys(defaults).sort((a, b) => defaults[a].x - defaults[b].x);
        const saved = names.filter(name => root.order.includes(name)).sort((a, b) => root.order.indexOf(a) - root.order.indexOf(b));
        const out = {};
        names.forEach((name, index) => out[root.order.includes(name) ? saved.shift() : name] = slots[index]);
        return out;
    }

    readonly property var positions: {
        const left = root.legendWidth;
        const span = width - left;
        const cx = left + span / 2;
        const peers = slice.nodes.filter(node => !node.host).sort((a, b) => (a.os + a.name).localeCompare(b.os + b.name)).map(node => node.name);
        const ring = ["pi"];
        fleet.hosts.filter(name => name !== "pi").forEach((name, index) => index % 2 === 0 ? ring.unshift(name) : ring.push(name));
        const row = ring.filter(name => fleet.hosts.includes(name)).concat(peers.filter(name => root.raised.includes(name)));
        const gap = span * Math.min(0.34, 0.8 / Math.max(1, row.length - 1));
        const hosts = {};
        row.forEach((name, index) => hosts[name] = Qt.point(cx + (index - (row.length - 1) / 2) * gap, root.hostRow));
        const lower = peers.filter(name => !root.raised.includes(name));
        const others = {};
        lower.forEach((name, index) => {
            const spread = lower.length === 1 ? 0.5 : index / (lower.length - 1);
            others[name] = Qt.point(left + span * (0.24 + 0.52 * spread), root.peerRow);
        });
        const out = Object.assign(root.arranged(hosts), root.arranged(others));
        if (root.dragging && out[root.dragging.name])
            out[root.dragging.name] = root.dragging.point;
        return out;
    }

    function drop(): void {
        const name = root.dragging.name;
        if (!root.isHost(name)) {
            const raise = root.dragging.point.y < (root.hostRow + root.peerRow) / 2;
            const rest = root.raised.filter(other => other !== name);
            root.raised = raise ? rest.concat([name]) : rest;
        }
        const up = root.upper(name);
        const row = Object.keys(root.positions).filter(other => root.upper(other) === up).sort((a, b) => root.positions[a].x - root.positions[b].x);
        root.order = root.order.filter(other => !row.includes(other)).concat(row);
        root.dragging = null;
        orderFile.setText(JSON.stringify({
            order: root.order,
            top: root.raised
        }));
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

    function edgeState(edge: var): string {
        if (!((root.nodeByName[edge.a]?.up ?? 0) > 0 && (root.nodeByName[edge.b]?.up ?? 0) > 0) && !root.liveEdge(edge))
            return "hidden";
        if ((edge.online ?? 1) <= 0)
            return "offline";
        return isFinite(edge.direct) && edge.direct < 0.5 ? "relayed" : "direct";
    }

    function liveEdge(edge: var): bool {
        const now = root.current.edges[edge.key];
        return root.fresh && !!now && (now.ab >= 100 || now.ba >= 100);
    }

    function liveRate(lane: var): real {
        if (!root.fresh)
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
        const a = root.place[edge.a];
        const b = root.place[edge.b];
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
        const blocked = Object.keys(root.place).some(name => name !== edge.a && name !== edge.b && root.segmentDistance(root.place[name], a, b) < root.clearance(name));
        const bend = (blocked ? 2 * (root.bloomExtent + 20) : Math.min(30, length * 0.08)) + (edge.fan ?? 0) * 16;
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
        const from = root.place[origin];
        const to = root.place[builder];
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
                const live = root.fresh ? (now ? (forward ? now.ab : now.ba) : 0) : rate;
                if (!(rate >= 100) && !(live >= 100))
                    continue;
                const key = `${edge.key}\u001f${forward}`;
                const target = root.laneWidth(rate);
                const width = root.widths[key] ?? target;
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
                    key: key,
                    edge: edge,
                    shape: shape,
                    side: side,
                    forward: forward,
                    rate: rate,
                    width: width,
                    target: target,
                    label: out,
                    normal: Qt.point(out.x - base.x, out.y - base.y)
                }));
            }
        }

        for (const owner of new Set((root.slice.tunnels ?? []).map(tunnel => tunnel.owner))) {
            const origin = root.place[owner];
            const list = root.slice.tunnels.filter(tunnel => tunnel.owner === owner).sort((a, b) => a.iface.localeCompare(b.iface));
            if (!origin)
                continue;
            const host = root.nodeByName[owner]?.host ?? false;
            const clear = host ? root.stallRadius + 8 : 10;
            list.forEach((tunnel, index) => {
                const txTarget = root.laneWidth(Math.max(tunnel.tx, 1));
                const rxTarget = root.laneWidth(Math.max(tunnel.rx, 1));
                const txWidth = root.widths[`${tunnel.key}\u001ftrue`] ?? txTarget;
                const rxWidth = root.widths[`${tunnel.key}\u001ffalse`] ?? rxTarget;
                const width = txWidth + rxWidth + 8;
                const shift = (index - (list.length - 1) / 2) * (width + 34);
                const start = Qt.point(origin.x + shift, origin.y - clear);
                const end = Qt.point(start.x, host ? root.tunnelTop : origin.y - clear - 30);
                const nx = 1;
                const ny = 0;
                const offset = width / 4;
                tunnels.push({
                    key: tunnel.key,
                    tunnel: tunnel,
                    start: start,
                    end: end,
                    width: width,
                    colour: tunnel.country ? root.fleet.countryColour(tunnel.country) : Colours.palette.m3onSurfaceVariant
                });
                for (const [rate, forward, laneWidth, target] of [[tunnel.tx, true, txWidth, txTarget], [tunnel.rx, false, rxWidth, rxTarget]]) {
                    const sign = forward ? 1 : -1;
                    const a = Qt.point(start.x + nx * offset * sign, start.y + ny * offset * sign);
                    const b = Qt.point(end.x + nx * offset * sign, end.y + ny * offset * sign);
                    lanes.push(Object.assign(root.polyline(forward ? [a, b] : [b, a]), {
                        key: `${tunnel.key}\u001f${forward}`,
                        tunnel: tunnel,
                        forward: forward,
                        rate: rate,
                        width: laneWidth,
                        target: target,
                        label: null
                    }));
                }
            });
        }

        for (const build of root.buildCounts()) {
            const origin = root.place[build.origin];
            if (!origin)
                continue;
            const local = build.origin === build.builder;
            const text = `⚙ ${build.count}`;
            const width = text.length * 6.5 + 12;
            if (local) {
                badges.push({
                    key: `${build.origin}\u001f${build.builder}`,
                    build: build,
                    text: text,
                    width: width,
                    at: Qt.point(origin.x - root.stallRadius - width / 2 - 4, origin.y - 24)
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
                key: `${build.origin}\u001f${build.builder}`,
                build: build,
                text: text,
                width: width,
                at: at,
                angle: Math.atan2(ahead.y - at.y, ahead.x - at.x)
            });
        }
        root.placeRates(lanes, badges);
        root.lanes = lanes;
        root.badges = badges;
        root.tunnels = tunnels;
    }

    function rateAt(lane: var, u: real): var {
        const base = root.along(lane.shape, u, lane.side);
        const out = root.along(lane.shape, u, lane.side + Math.sign(lane.side) * (lane.width / 2 + 6));
        const normal = Qt.point(out.x - base.x, out.y - base.y);
        const length = Math.max(1e-6, Math.hypot(normal.x, normal.y));
        return {
            label: out,
            normal: normal,
            centre: Qt.point(out.x + normal.x / length * 22, out.y + normal.y / length * 8)
        };
    }

    function placeRates(lanes: var, badges: var): void {
        const taken = badges.map(badge => ({
                    x: badge.at.x,
                    y: badge.at.y,
                    rx: badge.width / 2 + 26,
                    ry: 16
                }));
        const clashes = centre => taken.some(box => Math.abs(centre.x - box.x) < box.rx && Math.abs(centre.y - box.y) < box.ry);
        for (const lane of lanes) {
            if (!lane.label || !lane.shape)
                continue;
            const steps = [0, 0.08, -0.08, 0.16, -0.16, 0.24];
            const start = lane.forward ? 0.3 : 0.7;
            const tries = steps.map(step => root.rateAt(lane, Math.max(0.1, Math.min(0.9, start + (lane.forward ? step : -step)))));
            const chosen = tries.find(place => !clashes(place.centre)) ?? tries[0];
            lane.label = chosen.label;
            lane.normal = chosen.normal;
            taken.push({
                x: chosen.centre.x,
                y: chosen.centre.y,
                rx: 50,
                ry: 14
            });
        }
    }

    function buildCounts(): var {
        const out = {};
        for (const build of root.slice.builds)
            out[`${build.origin}\u001f${build.builder}`] = Object.assign({}, build);
        if (root.fresh) {
            const live = {};
            for (const build of root.current.builds) {
                const builder = build.builder === "local" || !build.builder ? build.origin : build.builder;
                const key = `${build.origin}\u001f${builder}`;
                (live[key] = live[key] ?? {
                        origin: build.origin,
                        builder: builder,
                        drvs: new Set()
                    }).drvs.add(build.key);
            }
            for (const key of Object.keys(live)) {
                const item = out[key] ?? (out[key] = {
                        origin: live[key].origin,
                        builder: live[key].builder,
                        count: 0
                    });
                item.count = Math.max(item.count, live[key].drvs.size);
            }
        }
        return Object.values(out);
    }

    function stage(blob: var, name: string): void {
        blob.stage = name;
        blob.stageAt = root.clock;
        blob.shown = 0;
    }

    function advance(blob: var, dt: real): void {
        const phase = blob.phase;
        if (phase === "failed") {
            if (blob.stage !== "failed")
                root.stage(blob, "failed");
            return;
        }
        if (blob.stage === "done" || blob.stage === "failed")
            return;
        if (blob.build.origin === blob.build.builder) {
            if (phase === "done")
                root.stage(blob, "done");
            return;
        }
        if (blob.stage === "upload" || blob.stage === "download") {
            const live = phase === blob.stage;
            const ahead = live ? Math.max(0, Math.min(blob.rate * Math.min(root.clock - blob.at, 1.5), 0.97 - blob.target)) : 0;
            const target = live ? blob.target + ahead : 1;
            blob.shown += Math.max(0, Math.min(target - blob.shown, dt / root.blobTravel));
            if (!live && blob.shown >= 1)
                root.stage(blob, blob.stage === "upload" ? "build" : "done");
        } else if (blob.stage === "build" && (phase === "download" || phase === "done") && root.clock - blob.stageAt > root.blobDwell)
            root.stage(blob, "download");
    }

    function syncBlobs(): void {
        if (!root.fresh) {
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
                    stage: build.origin === build.builder && build.phase !== "done" ? "build" : build.phase,
                    stageAt: root.clock - 10,
                    shown: build.phase === "done" ? 1 : build.progress,
                    target: build.progress,
                    rate: 0,
                    at: root.clock,
                    missingSince: -1,
                    last: null
                };
            if (blob.phase !== build.phase) {
                blob.phase = build.phase;
                blob.target = build.progress;
                blob.rate = 0;
                blob.at = root.clock;
            } else if (build.progress > blob.target + 1e-4) {
                const measured = (build.progress - blob.target) / Math.max(0.2, root.clock - blob.at);
                blob.rate = blob.rate > 0 ? (blob.rate + measured) / 2 : measured;
                blob.target = build.progress;
                blob.at = root.clock;
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
            if (blob.phase !== "done" && blob.phase !== "failed")
                blob.phase = "done";
            if ((blob.stage === "done" || blob.stage === "failed") && root.clock - blob.stageAt > 1)
                delete root.blobs[key];
        }
    }

    function present(store: var, items: var, keyOf: var, blend: real): bool {
        const seen = new Set();
        let changed = false;
        for (const item of items) {
            const key = keyOf(item);
            seen.add(key);
            if (store[key])
                store[key].item = item;
            else {
                store[key] = {
                    item: item,
                    alpha: 0
                };
                changed = true;
            }
        }
        for (const key of Object.keys(store)) {
            const entry = store[key];
            const target = seen.has(key) ? 1 : 0;
            if (Math.abs(target - entry.alpha) < 0.005) {
                if (entry.alpha !== target)
                    changed = true;
                entry.alpha = target;
            } else {
                entry.alpha += (target - entry.alpha) * blend;
                changed = true;
            }
            if (!target && entry.alpha <= 0) {
                delete store[key];
                changed = true;
            }
        }
        return changed;
    }

    function shown(store: var): var {
        return Object.values(store).filter(entry => entry.alpha > 0);
    }

    function settle(map: var, key: string, target: real, blend: real, epsilon: real): bool {
        const value = map[key];
        if (value === undefined || !isFinite(value) || !isFinite(target) || Math.abs(target - value) < epsilon) {
            const changed = value !== target;
            map[key] = target;
            return changed;
        }
        map[key] = value + (target - value) * blend;
        return true;
    }

    function easeScene(blend: real): void {
        let moved = false;
        const targets = root.positions;
        for (const name of Object.keys(targets)) {
            const target = targets[name];
            const now = root.place[name];
            if (!now || Math.abs(target.x - now.x) + Math.abs(target.y - now.y) < 0.2) {
                if (!now || now.x !== target.x || now.y !== target.y) {
                    root.place[name] = target;
                    moved = true;
                }
                continue;
            }
            root.place[name] = Qt.point(now.x + (target.x - now.x) * blend, now.y + (target.y - now.y) * blend);
            moved = true;
        }
        for (const entry of root.shown(root.laneFade))
            moved = root.settle(root.widths, entry.item.key, entry.item.target, blend, 0.02) || moved;

        let changed = root.present(root.nodeFade, root.slice.nodes, node => node.name, blend);
        for (const name of Object.keys(root.place))
            if (!targets[name] && !root.nodeFade[name]) {
                delete root.place[name];
                moved = true;
            }
        const names = Object.keys(root.nodeFade).sort();
        if (names.join("\u001f") !== root.nodeNames.join("\u001f"))
            root.nodeNames = names;
        for (const entry of Object.values(root.nodeFade))
            changed = root.settle(root.shownUp, entry.item.name, entry.item.up, blend, 0.005) || changed;
        if (changed) {
            const alpha = {};
            for (const name of names)
                alpha[name] = root.nodeFade[name].alpha;
            root.nodeAlpha = alpha;
            root.shownUp = Object.assign({}, root.shownUp);
        }

        changed = root.present(root.edgeFade, root.slice.edges.filter(edge => root.edgeState(edge) !== "hidden"), edge => edge.key, blend) || changed;
        for (const entry of root.shown(root.edgeFade)) {
            const state = root.edgeState(entry.item);
            const look = root.edgeLooks[entry.item.key];
            if (!look)
                root.edgeLooks[entry.item.key] = {
                    state: state === "hidden" ? "direct" : state,
                    previous: state,
                    mix: 1
                };
            else {
                if (state !== "hidden" && state !== look.state) {
                    look.previous = look.state;
                    look.state = state;
                    look.mix = 0;
                }
                if (look.mix < 1) {
                    look.mix = look.mix > 0.995 ? 1 : look.mix + (1 - look.mix) * blend;
                    changed = true;
                }
            }
        }
        const current = new Set(root.lanes.map(lane => lane.key));
        const trailing = root.shown(root.laneFade).map(entry => entry.item).filter(lane => !current.has(lane.key) && Object.values(root.emitted[lane.key] ?? {}).some(rate => rate >= 100));
        changed = root.present(root.laneFade, root.lanes.concat(trailing), lane => lane.key, blend) || changed;
        changed = root.present(root.sheathFade, root.tunnels, sheath => sheath.key, blend) || changed;
        changed = root.present(root.badgeFade, root.badges, badge => badge.key, blend) || changed;
        for (const entry of root.shown(root.sheathFade))
            changed = root.settle(root.tunnelOn, entry.item.key, entry.item.tunnel.enabled > 0.5 ? 1 : 0, blend, 0.005) || changed;

        if (moved) {
            root.place = Object.assign({}, root.place);
            root.rebuild();
        }
        if (moved || changed)
            canvas.requestPaint();
    }

    function tick(dt: real): void {
        const scrubbing = root.fleet.preview !== null;
        const blend = 1 - Math.exp(-dt / (scrubbing ? 0.02 : 0.3));
        root.easeScene(1 - Math.exp(-dt / (scrubbing ? 0.05 : 0.35)));
        const live = {};
        for (const lane of root.lanes)
            live[lane.key] = lane;
        for (const entry of root.shown(root.laneFade)) {
            const lane = live[entry.item.key] ?? entry.item;
            const target = live[lane.key] ? root.liveRate(lane) : 0;
            const value = root.eased[lane.key] ?? target;
            const next = scrubbing ? target : value + (target - value) * blend;
            root.eased[lane.key] = next;
            const travel = (root.phases[lane.key] ?? Math.random() * 1e4) + (scrubbing ? 0 : root.dotSpeed * dt);
            root.phases[lane.key] = travel;
            const fresh = !root.emitted[lane.key];
            const emitted = root.emitted[lane.key] ?? {};
            const first = Math.ceil((travel - lane.length) / root.dotGrid);
            for (const n of Object.keys(emitted))
                if (Number(n) < first)
                    delete emitted[n];
            for (let n = first; n * root.dotGrid <= travel; n++)
                if (emitted[n] === undefined || scrubbing)
                    emitted[n] = fresh && !scrubbing && root.clock > 2 ? 0 : next;
            root.emitted[lane.key] = emitted;
        }
        for (const key of Object.keys(root.emitted))
            if (!root.laneFade[key])
                delete root.emitted[key];
        const glide = 1 - Math.exp(-dt / 0.3);
        const slots = root.slots();
        const boxes = Object.keys(root.boxCounts).map(name => ({
                    key: name,
                    count: root.boxCounts[name]
                }));
        root.present(root.boxFade, boxes, box => box.key, glide);
        for (const box of boxes)
            root.settle(root.boxHeights, box.key, root.boxOf(box.key, box.count)?.height ?? 0, glide, 0.2);
        for (const blob of Object.values(root.blobs)) {
            root.advance(blob, dt);
            const place = root.blobPlace(blob, slots[blob.key] ?? 0);
            if (!place)
                continue;
            const jump = 1 - Math.exp(-dt / 0.12);
            const moving = (blob.stage === "upload" || blob.stage === "download") && root.clock - blob.stageAt > 0.5;
            blob.last = blob.last && !moving ? Qt.point(blob.last.x + (place.x - blob.last.x) * jump, blob.last.y + (place.y - blob.last.y) * jump) : place;
        }
        root.easeBlooms(1 - Math.exp(-dt / 0.9));
        root.clock += dt;
    }

    function hostStats(name: string): string {
        const live = root.fresh ? root.current.psi[name] : null;
        const psi = live ?? root.slice.psi[name] ?? {};
        const span = (colour, ratio) => `<font color="${colour}">${root.fleet.percent(ratio)}</font>`;
        const cores = root.fresh ? (root.current.cores[name] ?? []) : [];
        const parts = cores.length ? [span(Colours.palette.m3primary, cores.reduce((sum, core) => sum + core.busy, 0) / cores.length), `<font color="${Colours.palette.m3primary}">max ${root.fleet.percent(Math.max(...cores.map(core => core.busy)))}</font>`] : [span(Colours.palette.m3primary, root.histories[name]?.mean ?? NaN)];
        for (const key of ["cpu", "io", "memory"])
            if (isFinite(psi[key]))
                parts.push(span(root.colours[key], psi[key]));
        return parts.join("&nbsp;&nbsp;");
    }

    function historyOf(name: string): var {
        const samples = (root.slice.pressure[name] ?? []).filter(sample => isFinite(sample.value));
        if (!samples.length)
            return {
                values: null,
                mean: NaN,
                last: NaN
            };
        const [from, to] = [root.slice.from, root.slice.to];
        let values = null;
        if (samples.length >= 2) {
            values = [];
            let j = 0;
            for (let i = 0; i < root.bloomSteps; i++) {
                const t = from + (to - from) * i / root.bloomSteps;
                while (j < samples.length - 1 && samples[j + 1].at <= t)
                    j++;
                const a = samples[j];
                const b = samples[Math.min(samples.length - 1, j + 1)];
                const u = b.at > a.at ? Math.max(0, Math.min(1, (t - a.at) / (b.at - a.at))) : 0;
                values.push(a.value + (b.value - a.value) * u);
            }
        }
        return {
            values: values,
            mean: samples.reduce((sum, sample) => sum + sample.value, 0) / samples.length,
            last: samples[samples.length - 1].value
        };
    }

    function easeValue(shown: real, target: real, blend: real): real {
        return !isFinite(target) ? shown : isFinite(shown) ? shown + (target - shown) * blend : target;
    }

    function easeBlooms(blend: real): void {
        for (const name of root.fleet.hosts) {
            const history = root.histories[name] ?? root.historyOf(name);
            const average = root.slice.psi[name] ?? {
                cpu: 0,
                io: 0,
                memory: 0
            };
            const live = root.fresh ? (root.current.psi[name] ?? average) : average;
            const target = {
                cores: root.fresh ? (root.current.cores[name] ?? null) : null,
                load: root.fresh ? root.current.load[name] : history.last,
                mean: history.mean,
                values: history.values,
                live: live,
                average: average
            };
            const shown = root.bloomShown[name];
            if (!shown) {
                root.bloomShown[name] = {
                    cores: target.cores ? target.cores.map(core => Object.assign({}, core)) : null,
                    load: target.load,
                    mean: target.mean,
                    values: target.values ? target.values.slice() : null,
                    live: Object.assign({}, live),
                    average: Object.assign({}, average)
                };
                continue;
            }
            shown.load = root.easeValue(shown.load, target.load, blend);
            if (!target.cores || !shown.cores || shown.cores.length !== target.cores.length)
                shown.cores = target.cores ? target.cores.map(core => Object.assign({}, core)) : null;
            else
                target.cores.forEach((core, index) => {
                    shown.cores[index].busy = root.easeValue(shown.cores[index].busy, core.busy, blend);
                });
            shown.mean = root.easeValue(shown.mean, target.mean, blend);
            if (!target.values || !shown.values)
                shown.values = target.values ? target.values.slice() : null;
            else
                for (let i = 0; i < target.values.length; i++)
                    shown.values[i] = root.easeValue(shown.values[i], target.values[i], blend);
            for (const key of ["cpu", "io", "memory"]) {
                shown.live[key] = root.easeValue(shown.live[key] ?? 0, live[key] ?? 0, blend);
                shown.average[key] = root.easeValue(shown.average[key] ?? 0, average[key] ?? 0, blend);
            }
        }
    }

    function inBox(blob: var): bool {
        return blob.build.origin === blob.build.builder || blob.stage === "build";
    }

    function slots(): var {
        const groups = {};
        for (const blob of Object.values(root.blobs))
            if (root.inBox(blob) && blob.stage !== "done" && blob.stage !== "failed")
                (groups[blob.build.builder] = groups[blob.build.builder] ?? []).push(blob.key);
        const out = {};
        for (const keys of Object.values(groups))
            keys.sort().forEach((key, index) => out[key] = index);
        const counts = {};
        for (const name of Object.keys(groups))
            counts[name] = groups[name].length;
        root.boxCounts = counts;
        return out;
    }

    function boxOf(name: string, count: int): var {
        const names = Array.from(new Set(Object.keys(root.boxCounts).concat(name))).sort();
        const placed = [];
        for (const other of names) {
            const box = root.boxBase(other, other === name ? count : root.boxCounts[other]);
            if (!box)
                continue;
            for (const below of placed)
                if (below.x < box.x + box.width && box.x < below.x + below.width && below.y < box.y + box.height && box.y < below.y + below.height)
                    Object.assign(box, {
                        x: below.x,
                        y: below.y + below.height + 4
                    });
            if (other === name)
                return box;
            placed.push(box);
        }
        return null;
    }

    function boxBase(name: string, count: int): var {
        const centre = root.place[name];
        if (!centre)
            return null;
        const rows = Math.max(1, Math.min(root.boxRows, Math.ceil(count / root.boxColumns)));
        const width = root.boxColumns * root.boxCell + 10;
        const middle = root.legendWidth + (root.width - root.legendWidth) / 2;
        return {
            x: centre.x > middle - 1 ? centre.x - root.boxReach - width : centre.x + root.boxReach,
            y: centre.y + root.bloomExtent + 4,
            width: width,
            height: rows * root.boxCell + 21
        };
    }

    function boxSlot(name: string, slot: int): var {
        const box = root.boxOf(name, root.boxCounts[name] ?? 1);
        if (!box)
            return null;
        const cell = Math.min(slot, root.boxColumns * root.boxRows - 1);
        return Qt.point(box.x + 5 + (cell % root.boxColumns + 0.5) * root.boxCell, box.y + 16 + (Math.floor(cell / root.boxColumns) + 0.5) * root.boxCell);
    }

    function blobPlace(blob: var, slot: real): var {
        const build = blob.build;
        if (!root.place[build.origin])
            return null;
        if (root.inBox(blob))
            return root.boxSlot(build.builder, slot);
        const path = root.blobPath(build.origin, build.builder);
        if (!path || path.points.length < 2)
            return null;
        switch (blob.stage) {
        case "upload":
            return root.pointAt(path, blob.shown * path.length);
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
            if (blob.last && Math.abs(p.x - blob.last.x) <= 6 && Math.abs(p.y - blob.last.y) <= 6)
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
            const centre = root.place[node.name];
            if (centre && Math.hypot(p.x - centre.x, p.y - centre.y) <= (node.host ? root.coreRadius + 12 : 10))
                return {
                    kind: "node",
                    item: node
                };
        }
        for (const sheath of root.tunnels)
            if (root.segmentDistance(p, sheath.start, sheath.end) <= sheath.width / 2 + 2 || (p.x > sheath.end.x && p.x - sheath.end.x < sheath.width / 2 + 90 && Math.abs(p.y - sheath.end.y - 8) < 9))
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
        return root.fresh ? `now ${format(now)}, avg ${format(average)}` : `avg ${format(average)}`;
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
            return [[`${a} ⇄ ${b}${item.device ? ` ${item.device}` : ""}`, ""], [path, root.colours[state]], [`${a} → ${b}  ${root.nowAndAverage(now.ab, item.ab, fleet.rate)}`, primary], [`${b} → ${a}  ${root.nowAndAverage(now.ba, item.ba, fleet.rate)}`, tertiary], [window, ""]];
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
            id: `${hovered.kind}\u001f${hovered.item.key ?? hovered.item.name}`,
            from: graphs.from,
            step: graphs.step,
            span: root.fleet.span(root.fleet.smoothing)
        };
        const primary = Colours.palette.m3primary;
        const tertiary = Colours.palette.m3tertiary;
        if (hovered.kind === "edge") {
            const series = graphs.edges[hovered.item.key];
            return series ? Object.assign(base, {
                floor: 1024,
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
                floor: 1024,
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
                floor: 0.01,
                format: root.fleet.percent,
                series: ["cpu", "io", "memory"].map(key => ({
                            values: series[key] ?? [],
                            colour: root.colours[key]
                        }))
            }) : null;
        }
        return null;
    }

    onSliceChanged: {
        const histories = {};
        for (const name of root.fleet.hosts)
            histories[name] = root.historyOf(name);
        root.histories = histories;
        Qt.callLater(rebuild);
    }
    onCurrentChanged: {
        syncBlobs();
        Qt.callLater(rebuild);
        canvas.requestPaint();
    }
    onLanesChanged: {
        canvas.requestPaint();
        flow.requestPaint();
    }
    onClockChanged: {
        flow.requestPaint();
        blooms.requestPaint();
        if (root.hovered?.kind === "edge")
            overlay.requestPaint();
    }
    onHoveredChanged: {
        canvas.requestPaint();
        overlay.requestPaint();
    }

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
        id: blooms

        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            for (const name of root.fleet.hosts) {
                const centre = root.place[name];
                const shown = root.bloomShown[name];
                if (centre && shown && root.nodeByName[name])
                    canvas.drawBloom(ctx, name, centre, shown);
            }
        }
    }

    Canvas {
        id: canvas

        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        function drawEdge(ctx: var, edge: var, alpha: real): void {
            const look = root.edgeLooks[edge.key];
            const shape = root.curve(edge);
            if (!shape || !look)
                return;
            const hovered = root.hovered?.kind === "edge" && root.hovered.item === edge;
            for (const [state, weight] of [[look.previous, 1 - look.mix], [look.state, look.mix]]) {
                if (weight <= 0 || state === "hidden")
                    continue;
                ctx.save();
                ctx.globalAlpha = alpha * weight;
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
            const rate = root.eased[lane.key] ?? root.liveRate(lane);
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
            const on = root.tunnelOn[sheath.key] ?? (sheath.tunnel.enabled > 0.5 ? 1 : 0);
            const hovered = root.hovered?.kind === "tunnel" && root.hovered.item === sheath.tunnel;
            const top = Math.min(sheath.start.y, sheath.end.y);
            const height = Math.abs(sheath.end.y - sheath.start.y);
            const left = sheath.start.x - sheath.width / 2;
            ctx.save();
            ctx.fillStyle = Qt.alpha(sheath.colour, 0.22 * on);
            ctx.fillRect(left, top, sheath.width, height);
            ctx.strokeStyle = Qt.alpha(sheath.colour, hovered ? 1 : 0.4 + 0.3 * on);
            ctx.lineWidth = hovered ? 2 : 1.25;
            ctx.setLineDash(on > 0.5 ? [] : [3, 3]);
            ctx.beginPath();
            ctx.moveTo(left, sheath.start.y);
            ctx.lineTo(left, sheath.end.y);
            ctx.moveTo(left + sheath.width, sheath.start.y);
            ctx.lineTo(left + sheath.width, sheath.end.y);
            ctx.stroke();
            ctx.setLineDash([]);
            ctx.lineWidth = hovered ? 3 : 2.5;
            ctx.beginPath();
            ctx.moveTo(left - 3, sheath.end.y);
            ctx.lineTo(left + sheath.width + 3, sheath.end.y);
            ctx.stroke();
            ctx.restore();

            const text = sheath.tunnel.server || sheath.tunnel.iface;
            ctx.font = "bold 11px sans-serif";
            ctx.textAlign = "left";
            ctx.textBaseline = "middle";
            const x = left + sheath.width + 6;
            const y = sheath.end.y + 8;
            ctx.lineWidth = 3.5;
            ctx.strokeStyle = Colours.palette.m3surfaceContainer;
            ctx.strokeText(text, x, y);
            ctx.fillStyle = Qt.alpha(sheath.colour, 0.55 + 0.45 * on);
            ctx.fillText(text, x, y);
        }

        function drawBloom(ctx: var, name: string, centre: var, shown: var): void {
            const palette = Colours.palette;
            const scale = value => root.coreRadius + root.pressureScale * Math.sqrt(Math.min(root.pressureClamp, Math.max(0, value)));
            const ring = radius => {
                ctx.beginPath();
                ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2);
            };
            ring(scale(1));
            ctx.strokeStyle = Qt.alpha(palette.m3onSurface, 0.16);
            ctx.lineWidth = 1;
            ctx.stroke();

            if (shown.cores && shown.cores.length) {
                const n = shown.cores.length;
                const radiusOf = busy => root.coreRadius + (root.bloomExtent - root.coreRadius) * Math.max(0, Math.min(1, busy));
                const points = shown.cores.map((core, index) => {
                    const angle = -Math.PI / 2 + 2 * Math.PI * index / n;
                    const radius = radiusOf(core.busy);
                    return Qt.point(centre.x + Math.cos(angle) * radius, centre.y + Math.sin(angle) * radius);
                });
                const average = shown.cores.reduce((sum, core) => sum + core.busy, 0) / n;
                const mid = (a, b) => Qt.point((a.x + b.x) / 2, (a.y + b.y) / 2);
                ctx.beginPath();
                const start = mid(points[n - 1], points[0]);
                ctx.moveTo(start.x, start.y);
                points.forEach((point, index) => {
                    const next = mid(point, points[(index + 1) % n]);
                    ctx.quadraticCurveTo(point.x, point.y, next.x, next.y);
                });
                ctx.closePath();
                ctx.fillStyle = Qt.alpha(palette.m3primary, 0.1 + 0.25 * Math.max(0, Math.min(1, average)));
                ctx.fill();
                ctx.lineJoin = "round";
                ctx.strokeStyle = palette.m3primary;
                ctx.lineWidth = 2;
                ctx.stroke();
            } else if (isFinite(shown.load)) {
                ring(scale(shown.load));
                ctx.strokeStyle = palette.m3primary;
                ctx.lineWidth = 2.5;
                ctx.stroke();
            }

            const gauge = root.stallRadius;
            const fraction = ratio => Math.max(0, Math.min(1, Math.log10(Math.max(ratio, 1e-6) * 1000) / 3));
            const span = (Math.PI - 4 * root.stallGap) / 3;
            ["cpu", "io", "memory"].forEach((key, index) => {
                const from = -Math.PI + root.stallGap + index * (span + root.stallGap);
                const colour = root.colours[key];
                const arc = (a, b, width, style) => {
                    ctx.beginPath();
                    ctx.arc(centre.x, centre.y, gauge, a, b);
                    ctx.lineWidth = width;
                    ctx.strokeStyle = style;
                    ctx.stroke();
                };
                ctx.save();
                ctx.lineCap = "round";
                arc(from, from + span, 5, Qt.alpha(colour, 0.32));
                const now = shown.live[key] ?? 0;
                if (fraction(now) > 0)
                    arc(from, from + span * fraction(now), 5, colour);
                ctx.restore();
                const mean = shown.average[key] ?? 0;
                if (fraction(mean) > 0) {
                    const angle = from + span * fraction(mean);
                    ctx.beginPath();
                    ctx.moveTo(centre.x + Math.cos(angle) * (gauge - 6), centre.y + Math.sin(angle) * (gauge - 6));
                    ctx.lineTo(centre.x + Math.cos(angle) * (gauge + 6), centre.y + Math.sin(angle) * (gauge + 6));
                    ctx.strokeStyle = palette.m3surfaceContainer;
                    ctx.lineWidth = 3.5;
                    ctx.stroke();
                    ctx.strokeStyle = palette.m3onSurface;
                    ctx.lineWidth = 1.5;
                    ctx.stroke();
                }
            });
        }

        function drawNode(ctx: var, node: var, alpha: real): void {
            const centre = root.place[node.name];
            if (!centre)
                return;
            const up = Math.max(0, Math.min(1, root.shownUp[node.name] ?? node.up));
            const radius = node.host ? 5.5 : 4.5;
            ctx.save();
            ctx.globalAlpha = alpha;
            ctx.beginPath();
            ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2);
            ctx.fillStyle = Qt.alpha(node.host ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant, Math.min(1, up * 4));
            ctx.fill();
            ctx.strokeStyle = Colours.palette.m3surfaceContainer;
            ctx.lineWidth = 1.5;
            ctx.stroke();
            const broken = 1 - Math.min(1, Math.max(0, (up - 0.9) / 0.09));
            if (broken > 0) {
                ctx.strokeStyle = Qt.alpha(root.colours.offline, broken);
                ctx.lineWidth = 2;
                ctx.stroke();
            }
            ctx.restore();
            if (root.hovered?.kind === "node" && root.hovered.item === node) {
                ctx.beginPath();
                ctx.arc(centre.x, centre.y, radius + 4, 0, Math.PI * 2);
                ctx.strokeStyle = Colours.palette.m3onSurface;
                ctx.lineWidth = 1.5;
                ctx.stroke();
            }
        }

        function drawBadge(ctx: var, badge: var, alpha: real): void {
            const at = badge.at;
            ctx.save();
            ctx.globalAlpha = alpha;
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
            ctx.restore();
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const faded = (store, draw) => {
                for (const entry of root.shown(store)) {
                    ctx.globalAlpha = entry.alpha;
                    draw(entry.item, entry.alpha);
                }
                ctx.globalAlpha = 1;
            };
            faded(root.sheathFade, sheath => canvas.drawSheath(ctx, sheath));
            faded(root.laneFade, lane => canvas.drawLane(ctx, lane));
            faded(root.edgeFade, (edge, alpha) => canvas.drawEdge(ctx, edge, alpha));
            faded(root.nodeFade, (node, alpha) => canvas.drawNode(ctx, node, alpha));
            faded(root.laneFade, lane => canvas.drawRate(ctx, lane));
            faded(root.badgeFade, (badge, alpha) => canvas.drawBadge(ctx, badge, alpha));
        }
    }

    Canvas {
        id: flow

        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        function drawDots(ctx: var, lane: var, alpha: real): void {
            const emitted = root.emitted[lane.key];
            if (!emitted || lane.points.length < 2)
                return;
            ctx.fillStyle = lane.tunnel && lane.tunnel.enabled <= 0.5 ? Colours.palette.m3outline : Colours.palette.m3onSurface;
            const travel = root.phases[lane.key] ?? 0;
            for (const key of Object.keys(emitted)) {
                const rate = emitted[key];
                if (rate < 100)
                    continue;
                const n = Number(key);
                const distance = travel - n * root.dotGrid;
                if (distance < 0 || distance > lane.length)
                    continue;
                const density = Math.max(0.06, Math.min(1, Math.log10(rate / 100) / 4.5));
                const seed = Math.sin(n * 12.9898) * 43758.5453;
                const show = Math.min(1, (density - (seed - Math.floor(seed))) / 0.08);
                if (show <= 0)
                    continue;
                const radius = Math.min(5.5, 2.4 + 2 * Math.max(0, Math.log10(rate / 1e6)));
                const point = root.pointAt(lane, distance);
                ctx.globalAlpha = alpha * show * Math.min(1, Math.log10(rate / 100) + 0.35);
                ctx.beginPath();
                ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
                ctx.fill();
            }
            ctx.globalAlpha = 1;
        }

        function drawBox(ctx: var, name: string, count: int, alpha: real): void {
            const box = root.boxOf(name, count);
            if (!box)
                return;
            ctx.globalAlpha = alpha;
            ctx.beginPath();
            ctx.roundedRect(box.x, box.y, box.width, root.boxHeights[name] ?? box.height, 5, 5);
            ctx.fillStyle = Qt.alpha(Colours.palette.m3surfaceContainerHighest, 0.85);
            ctx.fill();
            ctx.strokeStyle = Qt.alpha(Colours.palette.m3outline, 0.6);
            ctx.lineWidth = 1;
            ctx.stroke();
            ctx.font = "bold 10px sans-serif";
            ctx.textAlign = "left";
            ctx.textBaseline = "middle";
            ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
            ctx.fillText(`building ${root.boxCounts[name] ?? count}`, box.x + 6, box.y + 9);
            ctx.globalAlpha = 1;
        }

        function drawBlob(ctx: var, blob: var): void {
            const place = blob.last;
            if (!place)
                return;
            const age = root.clock - blob.stageAt;
            const fade = Math.min(1, age / 0.6);
            const palette = Colours.palette;
            const colour = blob.stage === "failed" ? root.colours.offline : blob.stage === "download" || blob.stage === "done" ? palette.m3tertiary : palette.m3primary;
            const ending = blob.stage === "done" || blob.stage === "failed";
            const alpha = ending ? 1 - fade : 1;
            if (alpha <= 0)
                return;
            const half = root.inBox(blob) || ending ? 3.5 : 5.5;
            ctx.fillStyle = Qt.alpha(colour, 0.9 * alpha);
            ctx.fillRect(place.x - half, place.y - half, half * 2, half * 2);
            if (root.hovered?.kind === "blob" && root.hovered.item === blob) {
                ctx.strokeStyle = palette.m3onSurface;
                ctx.lineWidth = 1.5;
                ctx.strokeRect(place.x - half - 2, place.y - half - 2, half * 2 + 4, half * 2 + 4);
            }
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            for (const entry of root.shown(root.laneFade))
                flow.drawDots(ctx, entry.item, entry.alpha);
            for (const entry of root.shown(root.boxFade))
                flow.drawBox(ctx, entry.item.key, entry.item.count, entry.alpha);
            for (const blob of Object.values(root.blobs))
                flow.drawBlob(ctx, blob);
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
        onPressed: mouse => {
            const name = Object.keys(root.place).find(name => Math.hypot(root.place[name].x - mouse.x, root.place[name].y - mouse.y) < root.coreRadius + 10);
            if (!name) {
                mouse.accepted = false;
                return;
            }
            root.dragging = {
                name: name,
                point: Qt.point(mouse.x, mouse.y)
            };
        }
        onPositionChanged: mouse => {
            root.pointer = Qt.point(mouse.x, mouse.y);
            if (root.dragging)
                root.dragging = {
                    name: root.dragging.name,
                    point: Qt.point(mouse.x, mouse.y)
                };
        }
        onReleased: {
            if (root.dragging)
                root.drop();
        }
        onCanceled: root.dragging = null
        onExited: root.pointer = null
        onWheel: wheel => {
            const steps = [60, 300, 600, 1800, 3600, 3 * 3600, 6 * 3600];
            const index = steps.findIndex(step => step >= root.fleet.smoothing);
            const next = wheel.angleDelta.y > 0 ? Math.max(0, index - 1) : Math.min(steps.length - 1, index + 1);
            root.fleet.smoothing = steps[next];
        }
    }

    Repeater {
        model: root.nodeNames

        delegate: Rectangle {
            id: label

            required property string modelData
            readonly property var node: root.nodeByName[modelData] ?? root.nodeFade[modelData]?.item ?? ({
                    name: modelData,
                    host: false,
                    up: 0
                })
            readonly property var centre: root.place[modelData] ?? Qt.point(-1000, -1000)
            readonly property var deploy: root.slice.deploys[modelData] ?? null

            opacity: root.nodeAlpha[modelData] ?? 0
            x: centre.x - width / 2
            y: node.host ? centre.y + root.bloomExtent + 2 : centre.y + 8
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
                    text: root.fleet.displayName(label.node.name)
                    font: label.node.host ? Tokens.font.body.small : Tokens.font.label.small
                    color: Qt.tint(Colours.palette.m3outline, Qt.alpha(Colours.palette.m3onSurface, Math.min(1, (root.shownUp[label.modelData] ?? label.node.up) * 4)))
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    visible: label.node.host
                    textFormat: Text.StyledText
                    text: label.node.host ? root.hostStats(label.modelData) : ""
                    font: Tokens.font.label.small
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
                    font: Tokens.font.label.small
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

    Canvas {
        id: overlay

        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            if (root.hovered?.kind !== "edge")
                return;
            const edge = root.hovered.item;
            const entry = root.edgeFade[edge.key];
            const shape = root.curve(edge);
            if (!entry || !shape)
                return;
            const lanes = root.shown(root.laneFade).map(lane => lane.item).filter(lane => !lane.tunnel && lane.edge.key === edge.key && lane.points.length > 1);
            ctx.save();
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            ctx.strokeStyle = Colours.palette.m3surfaceContainer;
            ctx.beginPath();
            ctx.moveTo(shape.a.x, shape.a.y);
            ctx.quadraticCurveTo(shape.c.x, shape.c.y, shape.b.x, shape.b.y);
            ctx.lineWidth = 10;
            ctx.stroke();
            for (const lane of lanes) {
                ctx.beginPath();
                ctx.moveTo(lane.points[0].x, lane.points[0].y);
                for (const point of lane.points.slice(1))
                    ctx.lineTo(point.x, point.y);
                ctx.lineWidth = lane.width + 8;
                ctx.stroke();
            }
            ctx.restore();
            for (const lane of lanes)
                canvas.drawLane(ctx, lane);
            canvas.drawEdge(ctx, edge, 1);
            for (const lane of lanes)
                flow.drawDots(ctx, lane, 1);
            for (const lane of lanes)
                canvas.drawRate(ctx, lane);
        }
    }

    FileView {
        id: orderFile

        path: `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/caelestia/fleet-order.json`
        printErrors: false
        onLoaded: {
            try {
                const saved = JSON.parse(text());
                root.order = Array.isArray(saved) ? saved : saved.order ?? [];
                root.raised = Array.isArray(saved) ? [] : saved.top ?? [];
            } catch (error) {
                root.order = [];
                root.raised = [];
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
