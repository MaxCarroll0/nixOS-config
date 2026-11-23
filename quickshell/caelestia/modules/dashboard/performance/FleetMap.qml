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
    readonly property var colours: fleet.colours
    readonly property real legendWidth: 160
    readonly property real coreRadius: 14
    readonly property real pressureScale: 22
    readonly property real pressureClamp: 2
    readonly property real bloomExtent: coreRadius + pressureScale * pressureClamp
    readonly property real hostRow: 124
    readonly property real peerRow: height - 50
    readonly property real dotSpacing: 26
    readonly property real dotSpeed: 36
    property real clock: 0
    property var pointer: null
    property var lanes: []
    property var badges: []
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
        return Math.max(1, Math.min(8, 1 + 1.5 * Math.log10(rate / 1000)));
    }

    function edgeState(edge: var): string {
        if (!((root.nodeByName[edge.a]?.up ?? 0) > 0 && (root.nodeByName[edge.b]?.up ?? 0) > 0))
            return "hidden";
        if ((edge.online ?? 1) <= 0)
            return "offline";
        return isFinite(edge.direct) && edge.direct < 0.5 ? "relayed" : "direct";
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

    function rebuild(): void {
        const lanes = [];
        const badges = [];
        for (const edge of root.slice.edges) {
            const shape = root.curve(edge);
            if (!shape || root.edgeState(edge) === "hidden" || root.edgeState(edge) === "offline")
                continue;
            for (const [rate, forward] of [[edge.ab, true], [edge.ba, false]]) {
                if (!(rate >= 100))
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
                const cum = [0];
                for (let i = 1; i < points.length; i++)
                    cum.push(cum[i - 1] + Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y));
                const u = forward ? 0.3 : 0.7;
                const base = root.along(shape, u, side);
                const out = root.along(shape, u, side + Math.sign(side) * (width / 2 + 6));
                lanes.push({
                    edge: edge,
                    forward: forward,
                    rate: rate,
                    width: width,
                    points: points,
                    cum: cum,
                    length: cum[cum.length - 1] ?? 0,
                    label: out,
                    normal: Qt.point(out.x - base.x, out.y - base.y)
                });
            }
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
                    at: Qt.point(origin.x + reach, origin.y - reach)
                });
                continue;
            }
            const edge = root.slice.edges.find(item => (item.a === build.origin && item.b === build.builder) || (item.b === build.origin && item.a === build.builder));
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
    }

    function hit(p: var): var {
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

    function describe(hovered: var): var {
        if (!hovered)
            return [];
        const fleet = root.fleet;
        const window = `last ${fleet.span(fleet.smoothing)}`;
        const item = hovered.item;
        if (hovered.kind === "build")
            return item.origin === item.builder ? [[`${item.origin}: ${item.count} local builds`, ""], [window, ""]] : [[`${item.origin} → ${item.builder}`, ""], [`${item.count} builds sent to ${item.builder}`, ""], [window, ""]];
        if (hovered.kind === "edge") {
            const state = root.edgeState(item);
            const path = state === "offline" ? "unreachable" : state === "relayed" ? `relayed via DERP ${item.relay || "?"}` : "direct";
            return [[`${fleet.displayName(item.a)} ⇄ ${fleet.displayName(item.b)}`, ""], [path, root.colours[state]], [`${fleet.displayName(item.a)} → ${fleet.displayName(item.b)}  ${fleet.rate(item.ab)}`, ""], [`${fleet.displayName(item.b)} → ${fleet.displayName(item.a)}  ${fleet.rate(item.ba)}`, ""], [window, ""]];
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
        lines.push([item.up > 0 ? `online ${fleet.percent(item.up)} of ${window}` : `offline for ${window}`, item.up > 0 ? "" : root.colours.offline]);
        if (item.host) {
            const values = (root.slice.pressure[name] ?? []).map(sample => sample.value).filter(isFinite);
            if (values.length) {
                const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
                lines.push([`load per core  avg ${mean.toFixed(2)}, peak ${Math.max(...values).toFixed(2)}`, ""]);
            }
            const psi = root.slice.psi[name];
            if (psi) {
                lines.push([`cpu stall ${fleet.percent(psi.cpu)}`, root.colours.cpu]);
                lines.push([`io stall ${fleet.percent(psi.io)}`, root.colours.io]);
                lines.push([`memory stall ${fleet.percent(psi.memory)}`, root.colours.memory]);
            }
        }
        lines.push([`sends ${fleet.rate(sent)}, receives ${fleet.rate(received)}`, ""]);
        return lines;
    }

    onSliceChanged: Qt.callLater(rebuild)
    onPositionsChanged: Qt.callLater(rebuild)
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
        interval: 33
        repeat: true
        running: root.visible && root.lanes.length > 0
        onTriggered: root.clock += interval / 1000
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
            if (lane.points.length < 2)
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
            if (lane.rate < 1000)
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
            const text = root.fleet.rate(lane.rate);
            ctx.lineWidth = 3;
            ctx.strokeStyle = Colours.palette.m3surfaceContainer;
            ctx.strokeText(text, lane.label.x, lane.label.y);
            ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
            ctx.fillText(text, lane.label.x, lane.label.y);
        }

        function drawBloom(ctx: var, name: string, centre: var): void {
            const r0 = root.coreRadius;
            const psi = root.slice.psi[name] ?? {
                cpu: 0,
                io: 0,
                memory: 0
            };
            const samples = (root.slice.pressure[name] ?? []).filter(sample => isFinite(sample.value));
            if (samples.length >= 2) {
                const [from, to] = [root.slice.from, root.slice.to];
                const points = samples.map(sample => {
                    const angle = -Math.PI / 2 + 2 * Math.PI * (sample.at - from) / Math.max(1, to - from);
                    const radius = r0 + root.pressureScale * Math.min(root.pressureClamp, sample.value);
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
                ctx.fillStyle = Qt.alpha(Colours.palette.m3onSurface, 0.07);
                ctx.fill();
                ctx.strokeStyle = Qt.alpha(Colours.palette.m3onSurface, 0.75);
                ctx.lineWidth = 1.5;
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

            for (const [key, angle] of [["cpu", -Math.PI / 2], ["io", Math.PI / 6], ["memory", 5 * Math.PI / 6]]) {
                const ratio = psi[key] ?? 0;
                if (!(ratio > 0.001))
                    continue;
                const length = r0 + 40 * Math.sqrt(Math.min(1, ratio));
                const spread = 0.4;
                ctx.beginPath();
                ctx.moveTo(centre.x, centre.y);
                ctx.quadraticCurveTo(centre.x + Math.cos(angle - spread) * length * 1.15, centre.y + Math.sin(angle - spread) * length * 1.15, centre.x + Math.cos(angle) * length, centre.y + Math.sin(angle) * length);
                ctx.quadraticCurveTo(centre.x + Math.cos(angle + spread) * length * 1.15, centre.y + Math.sin(angle + spread) * length * 1.15, centre.x, centre.y);
                ctx.fillStyle = Qt.alpha(root.colours[key], 0.7);
                ctx.fill();
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

        function pointAt(lane: var, s: real): var {
            let i = 1;
            while (i < lane.cum.length - 1 && lane.cum[i] < s)
                i++;
            const span = Math.max(1e-6, lane.cum[i] - lane.cum[i - 1]);
            const t = Math.max(0, Math.min(1, (s - lane.cum[i - 1]) / span));
            const a = lane.points[i - 1];
            const b = lane.points[i];
            return Qt.point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.fillStyle = Colours.palette.m3onSurface;
            const offset = (root.clock * root.dotSpeed) % root.dotSpacing;
            for (const lane of root.lanes) {
                if (lane.points.length < 2)
                    continue;
                const radius = Math.max(1.6, lane.width / 2 + 0.4);
                for (let s = offset; s < lane.length; s += root.dotSpacing) {
                    const point = flow.pointAt(lane, s);
                    ctx.beginPath();
                    ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
                    ctx.fill();
                }
            }
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
    }
}
