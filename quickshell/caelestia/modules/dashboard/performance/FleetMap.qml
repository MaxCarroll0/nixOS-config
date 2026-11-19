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
    readonly property real bloomRadius: 16
    readonly property real pressureScale: 26
    property real phase: 0
    property var hoverEdge: null

    readonly property var positions: {
        const out = {};
        const cx = width / 2;
        const cy = height * 0.34;
        const hosts = fleet.hosts.filter(name => name !== "pi");
        out.pi = Qt.point(cx, cy);
        hosts.forEach((name, index) => {
            const angle = Math.PI + index * Math.PI / Math.max(1, hosts.length - 1);
            out[name] = Qt.point(cx + Math.cos(angle) * width * 0.29, cy + Math.sin(angle) * height * 0.05);
        });
        const peers = slice.nodes.filter(node => !node.host).sort((a, b) => (a.os + a.name).localeCompare(b.os + b.name));
        peers.forEach((node, index) => {
            const spread = peers.length === 1 ? 0.5 : index / (peers.length - 1);
            out[node.name] = Qt.point(width * (0.18 + 0.64 * spread), height * (0.86 - 0.06 * Math.sin(Math.PI * spread)));
        });
        return out;
    }

    readonly property var nodeByName: {
        const out = {};
        for (const node of slice.nodes)
            out[node.name] = node;
        return out;
    }

    function hueOf(name: string): color {
        const psi = slice.psi[name];
        if (!psi)
            return Colours.palette.m3outline;
        const dominant = psi.memory >= psi.io && psi.memory >= psi.cpu ? "memory" : psi.io >= psi.cpu ? "io" : "cpu";
        return ({
                cpu: Colours.palette.m3primary,
                io: Colours.palette.m3tertiary,
                memory: Colours.palette.m3error
            })[dominant];
    }

    function strokeFor(rate: real): real {
        return rate > 0 ? 1 + 1.6 * Math.log10(1 + rate / 1000) : 1;
    }

    function curve(edge: var): var {
        const a = root.positions[edge.a];
        const b = root.positions[edge.b];
        if (!a || !b)
            return null;
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const length = Math.max(1, Math.hypot(dx, dy));
        const midX = (a.x + b.x) / 2;
        const midY = (a.y + b.y) / 2;
        const crowded = Object.keys(root.positions).some(name => name !== edge.a && name !== edge.b && Math.hypot(root.positions[name].x - midX, root.positions[name].y - midY) < 60);
        const bend = crowded ? Math.min(140, length * 0.2) : Math.min(40, length * 0.12);
        return {
            a: a,
            b: b,
            nx: -dy / length,
            ny: dx / length,
            control: Qt.point((a.x + b.x) / 2 - dy / length * bend, (a.y + b.y) / 2 + dx / length * bend)
        };
    }

    function along(shape: var, u: real, side: real): var {
        const v = 1 - u;
        const x = v * v * shape.a.x + 2 * v * u * shape.control.x + u * u * shape.b.x;
        const y = v * v * shape.a.y + 2 * v * u * shape.control.y + u * u * shape.b.y;
        return Qt.point(x + shape.nx * side, y + shape.ny * side);
    }

    function edgeAt(px: real, py: real): var {
        let best = null;
        let bestDistance = 10;
        for (const edge of slice.edges) {
            const shape = root.curve(edge);
            if (!shape)
                continue;
            for (let u = 0.1; u <= 0.9; u += 0.05) {
                const point = root.along(shape, u, 0);
                const distance = Math.hypot(point.x - px, point.y - py);
                if (distance < bestDistance) {
                    bestDistance = distance;
                    best = edge;
                }
            }
        }
        return best;
    }

    onSliceChanged: canvas.requestPaint()
    onPositionsChanged: canvas.requestPaint()
    onPhaseChanged: flow.requestPaint()
    onHoverEdgeChanged: canvas.requestPaint()

    Timer {
        interval: 33
        repeat: true
        running: root.visible && root.slice.edges.some(edge => edge.ab > 0 || edge.ba > 0)
        onTriggered: root.phase = (root.phase + 0.006) % 1
    }

    Canvas {
        id: canvas

        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        function drawEdge(ctx: var, edge: var): void {
            const shape = root.curve(edge);
            if (!shape)
                return;
            const online = (edge.online ?? 1) > 0 && (root.nodeByName[edge.a]?.up ?? 0) > 0 && (root.nodeByName[edge.b]?.up ?? 0) > 0;
            const relayed = isFinite(edge.direct) && edge.direct < 0.5;
            const hovered = root.hoverEdge === edge;
            ctx.save();
            ctx.beginPath();
            ctx.moveTo(shape.a.x, shape.a.y);
            ctx.quadraticCurveTo(shape.control.x, shape.control.y, shape.b.x, shape.b.y);
            ctx.lineWidth = root.strokeFor(Math.max(edge.ab, edge.ba));
            ctx.strokeStyle = online ? Qt.alpha(Colours.palette.m3onSurfaceVariant, hovered ? 0.8 : 0.45) : Qt.alpha(Colours.palette.m3outline, 0.25);
            ctx.setLineDash(!online ? [1, 5] : relayed ? [6, 4] : []);
            ctx.stroke();
            ctx.restore();
            if (relayed && online && edge.relay) {
                const mid = root.along(shape, 0.5, 0);
                ctx.fillStyle = Colours.palette.m3surfaceContainerHigh;
                ctx.strokeStyle = Colours.palette.m3outline;
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.arc(mid.x, mid.y, 9, 0, Math.PI * 2);
                ctx.fill();
                ctx.stroke();
                ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
                ctx.font = "8px sans-serif";
                ctx.textAlign = "center";
                ctx.textBaseline = "middle";
                ctx.fillText(edge.relay, mid.x, mid.y);
            }
        }

        function drawBloom(ctx: var, name: string, centre: var): void {
            const r0 = root.bloomRadius;
            const tint = root.hueOf(name);
            const psi = root.slice.psi[name] ?? {
                cpu: 0,
                io: 0,
                memory: 0
            };
            const lobes = [["cpu", -Math.PI / 2, Colours.palette.m3primary], ["io", Math.PI / 6, Colours.palette.m3tertiary], ["memory", 5 * Math.PI / 6, Colours.palette.m3error]];
            for (const [key, angle, colour] of lobes) {
                const length = r0 + 46 * Math.sqrt(Math.min(1, psi[key] ?? 0));
                const spread = 0.42;
                ctx.beginPath();
                ctx.moveTo(centre.x, centre.y);
                ctx.quadraticCurveTo(centre.x + Math.cos(angle - spread) * length * 1.15, centre.y + Math.sin(angle - spread) * length * 1.15, centre.x + Math.cos(angle) * length, centre.y + Math.sin(angle) * length);
                ctx.quadraticCurveTo(centre.x + Math.cos(angle + spread) * length * 1.15, centre.y + Math.sin(angle + spread) * length * 1.15, centre.x, centre.y);
                ctx.fillStyle = Qt.alpha(colour, 0.22);
                ctx.fill();
            }

            ctx.save();
            ctx.setLineDash([2, 3]);
            ctx.strokeStyle = Qt.alpha(Colours.palette.m3outline, 0.6);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.arc(centre.x, centre.y, r0 + root.pressureScale, 0, Math.PI * 2);
            ctx.stroke();
            ctx.restore();

            const samples = (root.slice.pressure[name] ?? []).filter(sample => isFinite(sample.value));
            if (samples.length >= 2) {
                const [from, to] = [root.slice.from, root.slice.to];
                const points = samples.map(sample => {
                    const angle = -Math.PI / 2 + 2 * Math.PI * (sample.at - from) / Math.max(1, to - from);
                    const radius = r0 + root.pressureScale * Math.min(2.2, sample.value);
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
                ctx.fillStyle = Qt.alpha(tint, 0.18);
                ctx.fill();
                ctx.strokeStyle = tint;
                ctx.lineWidth = 1.5;
                ctx.stroke();
            }
        }

        function drawNode(ctx: var, node: var): void {
            const centre = root.positions[node.name];
            if (!centre)
                return;
            if (node.host)
                canvas.drawBloom(ctx, node.name, centre);
            const radius = node.host ? 7 : 5;
            ctx.beginPath();
            ctx.arc(centre.x, centre.y, radius, 0, Math.PI * 2);
            ctx.fillStyle = node.up > 0 ? (node.host ? Colours.palette.m3onSurface : Colours.palette.m3secondary) : Colours.palette.m3surfaceContainerHigh;
            ctx.fill();
            ctx.strokeStyle = node.up > 0 && node.up < 0.99 ? Colours.palette.m3error : Colours.palette.m3outline;
            ctx.lineWidth = node.up > 0 && node.up < 0.99 ? 2 : 1;
            ctx.stroke();
        }

        function drawBuild(ctx: var, build: var): void {
            const origin = root.positions[build.origin];
            if (!origin)
                return;
            const text = build.origin === build.builder ? `⚙ ${build.count} local` : `⚙ ${build.count}`;
            let at = Qt.point(origin.x, origin.y - root.bloomRadius - root.pressureScale - 12);
            if (build.origin !== build.builder) {
                const edge = root.slice.edges.find(item => (item.a === build.origin && item.b === build.builder) || (item.b === build.origin && item.a === build.builder));
                const shape = edge ? root.curve(edge) : null;
                if (!shape)
                    return;
                const forward = edge.a === build.origin;
                at = root.along(shape, 0.5, 0);
                const ahead = root.along(shape, forward ? 0.57 : 0.43, 0);
                const angle = Math.atan2(ahead.y - at.y, ahead.x - at.x);
                ctx.save();
                ctx.translate(ahead.x, ahead.y);
                ctx.rotate(angle);
                ctx.fillStyle = Colours.palette.m3tertiary;
                ctx.beginPath();
                ctx.moveTo(5, 0);
                ctx.lineTo(-3, -4);
                ctx.lineTo(-3, 4);
                ctx.closePath();
                ctx.fill();
                ctx.restore();
            }
            ctx.font = "bold 10px sans-serif";
            const width = ctx.measureText(text).width + 10;
            ctx.fillStyle = Colours.palette.m3tertiaryContainer;
            ctx.beginPath();
            ctx.roundedRect(at.x - width / 2, at.y - 8, width, 16, 8, 8);
            ctx.fill();
            ctx.fillStyle = Colours.palette.m3onTertiaryContainer;
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            ctx.fillText(text, at.x, at.y);
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            for (const edge of root.slice.edges)
                canvas.drawEdge(ctx, edge);
            for (const node of root.slice.nodes)
                canvas.drawNode(ctx, node);
            for (const build of root.slice.builds)
                canvas.drawBuild(ctx, build);
        }
    }

    Canvas {
        id: flow

        anchors.fill: parent
        renderStrategy: Canvas.Cooperative

        function drawParticles(ctx: var, shape: var, rate: real, direction: int, tint: color): void {
            if (!(rate > 50))
                return;
            const count = Math.min(14, Math.ceil(2 * Math.log10(1 + rate / 100)));
            const speed = 0.6 + Math.log10(1 + rate / 1000) * 0.4;
            ctx.fillStyle = tint;
            for (let i = 0; i < count; i++) {
                const progress = (root.phase * speed + i / count) % 1;
                const point = root.along(shape, direction > 0 ? progress : 1 - progress, 3 * direction);
                ctx.globalAlpha = Math.sin(progress * Math.PI);
                ctx.beginPath();
                ctx.arc(point.x, point.y, 1.8, 0, Math.PI * 2);
                ctx.fill();
            }
            ctx.globalAlpha = 1;
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            for (const edge of root.slice.edges) {
                const shape = root.curve(edge);
                if (!shape)
                    continue;
                flow.drawParticles(ctx, shape, edge.ab, 1, root.hueOf(edge.a));
                flow.drawParticles(ctx, shape, edge.ba, -1, root.hueOf(edge.b));
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: mouse => root.hoverEdge = root.edgeAt(mouse.x, mouse.y)
        onExited: root.hoverEdge = null
        onWheel: wheel => {
            const steps = [60, 300, 600, 1800, 3600, 3 * 3600, 6 * 3600];
            const index = steps.findIndex(step => step >= root.fleet.smoothing);
            const next = wheel.angleDelta.y > 0 ? Math.max(0, index - 1) : Math.min(steps.length - 1, index + 1);
            root.fleet.smoothing = steps[next];
        }
    }

    StyledRect {
        visible: root.hoverEdge !== null
        readonly property var mid: root.hoverEdge && root.curve(root.hoverEdge) ? root.along(root.curve(root.hoverEdge), 0.5, 0) : Qt.point(0, 0)
        x: Math.min(root.width - width, mid.x + 12)
        y: mid.y + 12
        implicitWidth: edgeText.implicitWidth + Tokens.padding.medium * 2
        implicitHeight: edgeText.implicitHeight + Tokens.padding.small * 2
        radius: Tokens.rounding.small
        color: Colours.palette.m3surfaceContainerHighest

        StyledText {
            id: edgeText

            anchors.centerIn: parent
            font: Tokens.font.body.small
            text: {
                const edge = root.hoverEdge;
                if (!edge)
                    return "";
                const path = !isFinite(edge.direct) ? "" : edge.direct >= 0.5 ? "direct" : `relayed via ${edge.relay || "DERP"}`;
                return `${edge.a} → ${edge.b}  ${root.fleet.rate(edge.ab)}\n${edge.b} → ${edge.a}  ${root.fleet.rate(edge.ba)}${path ? "\n" + path : ""}`;
            }
        }
    }

    Repeater {
        model: root.slice.nodes

        delegate: ColumnLayout {
            id: label

            required property var modelData
            readonly property var centre: root.positions[modelData.name] ?? Qt.point(-1000, -1000)
            readonly property var deploy: root.slice.deploys[modelData.name] ?? null
            readonly property real offset: modelData.host ? root.bloomRadius + root.pressureScale + 4 : 10

            x: centre.x - width / 2
            y: modelData.name === "pi" ? centre.y + offset : modelData.host ? centre.y + offset : centre.y + 8
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
        }
    }
}
