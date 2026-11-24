pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property FleetModel fleet
    readonly property real labelWidth: 120
    readonly property real rowHeight: 18
    readonly property real axisHeight: 18
    readonly property real plotLeft: labelWidth
    readonly property real plotWidth: width - labelWidth - 4
    readonly property var span: fleet.range
    readonly property real windowFrom: fleet.committed - fleet.smoothing
    readonly property real windowTo: fleet.committed

    property var pointer: null
    readonly property var hovered: {
        if (!pointer || pointer.x < plotLeft || pointer.x > plotLeft + plotWidth)
            return null;
        const row = fleet.rows[Math.floor(pointer.y / rowHeight)];
        if (!row)
            return null;
        const at = atOf(pointer.x);
        const index = Math.round((at - row.from) / row.step);
        return {
            row: row,
            at: row.from + index * row.step,
            online: row.online[index] ?? NaN,
            direct: row.direct[index] ?? NaN,
            traffic: row.traffic[index] ?? NaN
        };
    }

    implicitHeight: Math.max(1, fleet.rows.length) * rowHeight + axisHeight

    function describe(hovered: var): var {
        if (!hovered)
            return [];
        const fleet = root.fleet;
        const lines = [[fleet.displayName(hovered.row.name), ""], [`${fleet.stamp(hovered.at)}, ${fleet.span(hovered.row.step)} bin`, ""]];
        if (!isFinite(hovered.online))
            lines.push(["no data", ""]);
        else if (hovered.online < 0.05)
            lines.push(["offline", fleet.colours.offline]);
        else {
            const relayed = isFinite(hovered.direct) && hovered.direct < 0.5;
            lines.push([`${relayed ? "relayed" : "direct"}, online ${fleet.percent(hovered.online)}`, relayed ? fleet.colours.relayed : fleet.colours.direct]);
        }
        if (isFinite(hovered.traffic))
            lines.push([`traffic ${fleet.rate(hovered.traffic)}`, ""]);
        return lines;
    }

    function xOf(at: real): real {
        const [from, to] = root.span;
        return root.plotLeft + root.plotWidth * (at - from) / Math.max(1, to - from);
    }

    function atOf(px: real): real {
        const [from, to] = root.span;
        return from + (to - from) * Math.max(0, Math.min(1, (px - root.plotLeft) / root.plotWidth));
    }

    function setRange(from: real, to: real): void {
        const length = Math.max(300, to - from);
        const end = Math.min(root.fleet.now, from + length);
        root.fleet.range = [end - length, end];
    }

    function zoomAround(at: real, factor: real): void {
        const [from, to] = root.span;
        const length = Math.min(400 * 86400, Math.max(300, (to - from) * factor));
        const ratio = (at - from) / Math.max(1, to - from);
        root.setRange(at - ratio * length, at - ratio * length + length);
    }

    function panBy(fraction: real): void {
        const [from, to] = root.span;
        const shift = (to - from) * fraction;
        root.setRange(from + shift, to + shift);
    }

    function setAnchor(at: real): void {
        root.fleet.anchor = at >= root.fleet.now - Math.max(30, (root.span[1] - root.span[0]) / 400) ? null : at;
    }

    Connections {
        target: root.fleet
        function onRowsChanged(): void {
            canvas.requestPaint();
        }
        function onAnchorChanged(): void {
            canvas.requestPaint();
        }
        function onPreviewChanged(): void {
            canvas.requestPaint();
        }
        function onSmoothingChanged(): void {
            canvas.requestPaint();
        }
        function onNowChanged(): void {
            canvas.requestPaint();
        }
    }

    Canvas {
        id: canvas

        anchors.fill: parent
        onWidthChanged: requestPaint()

        property real selectFrom: -1
        property real selectTo: -1
        onSelectToChanged: requestPaint()

        function stateColour(online: real, direct: real): var {
            const colours = root.fleet.colours;
            if (online < 0.05)
                return colours.offline;
            return Qt.alpha(isFinite(direct) && direct < 0.5 ? colours.relayed : colours.direct, 0.45 + 0.55 * online);
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const rows = root.fleet.rows;
            ctx.font = "11px sans-serif";
            ctx.textBaseline = "middle";
            rows.forEach((row, index) => {
                const top = index * root.rowHeight;
                ctx.fillStyle = row.host ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant;
                ctx.textAlign = "right";
                let name = root.fleet.displayName(row.name);
                while (name.length > 4 && ctx.measureText(name).width > root.labelWidth - 12)
                    name = name.slice(0, -2) + "…";
                ctx.fillText(name.replace(/…+/, "…"), root.labelWidth - 8, top + root.rowHeight / 2);
                const count = row.online.length;
                for (let i = 0; i < count; i++) {
                    const online = row.online[i];
                    if (!isFinite(online))
                        continue;
                    ctx.fillStyle = canvas.stateColour(online, row.direct[i]);
                    const at = row.from + i * row.step;
                    const left = Math.max(root.plotLeft, Math.round(root.xOf(at - row.step / 2)));
                    const right = Math.min(root.plotLeft + root.plotWidth, Math.round(root.xOf(at + row.step / 2)));
                    if (right <= left)
                        continue;
                    if (online < 0.05)
                        ctx.fillRect(left, top + root.rowHeight / 2 - 2, right - left, 4);
                    else
                        ctx.fillRect(left, top + 2, right - left, root.rowHeight - 4);
                }
                const traffic = row.traffic.map(value => isFinite(value) ? Math.log10(1 + value / 100) : NaN);
                const peak = Math.max(1, ...traffic.filter(isFinite));
                ctx.beginPath();
                let open = false;
                traffic.forEach((value, i) => {
                    if (!isFinite(value)) {
                        open = false;
                        return;
                    }
                    const x = root.xOf(row.from + i * row.step);
                    const y = top + root.rowHeight - 3 - (root.rowHeight - 6) * value / peak;
                    if (open)
                        ctx.lineTo(x, y);
                    else
                        ctx.moveTo(x, y);
                    open = true;
                });
                ctx.lineJoin = "round";
                ctx.strokeStyle = Qt.alpha(Colours.palette.m3surfaceContainer, 0.85);
                ctx.lineWidth = 3.5;
                ctx.stroke();
                ctx.strokeStyle = Colours.palette.m3onSurface;
                ctx.lineWidth = 1.5;
                ctx.stroke();
            });

            const [from, to] = root.span;
            const axisTop = rows.length * root.rowHeight;
            ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
            ctx.textAlign = "center";
            for (let i = 0; i <= 6; i++) {
                const at = from + (to - from) * i / 6;
                const x = root.xOf(at);
                ctx.fillRect(x, axisTop, 1, 4);
                ctx.textAlign = i === 0 ? "left" : i === 6 ? "right" : "center";
                ctx.fillText(root.fleet.axisLabel(at, to - from), x, axisTop + 11);
            }

            const left = Math.max(root.plotLeft, root.xOf(root.windowFrom));
            const right = Math.max(left + 2, root.xOf(root.windowTo));
            ctx.fillStyle = Qt.alpha(Colours.palette.m3onSurface, 0.14);
            ctx.fillRect(left, 0, right - left, axisTop);
            ctx.fillStyle = Colours.palette.m3onSurface;
            ctx.fillRect(left, 0, 2, axisTop);
            ctx.fillRect(right - 2, 0, 2, axisTop);

            const preview = root.fleet.preview;
            if (preview !== null) {
                const previewLeft = Math.max(root.plotLeft, root.xOf(preview - root.fleet.smoothing));
                const previewRight = Math.max(previewLeft + 1, root.xOf(preview));
                ctx.fillStyle = Qt.alpha(Colours.palette.m3primary, 0.12);
                ctx.fillRect(previewLeft, 0, previewRight - previewLeft, axisTop);
                ctx.fillStyle = Qt.alpha(Colours.palette.m3primary, 0.7);
                ctx.fillRect(previewRight - 1, 0, 1, axisTop);
            }

            if (canvas.selectFrom >= 0 && canvas.selectTo >= 0) {
                ctx.fillStyle = Qt.alpha(Colours.palette.m3onSurface, 0.18);
                ctx.fillRect(Math.min(canvas.selectFrom, canvas.selectTo), 0, Math.abs(canvas.selectTo - canvas.selectFrom), axisTop);
            }
        }
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton

        property string mode: ""
        property real pressX: 0
        property real pressAt: 0
        property real pressAnchor: 0
        property real pressSmoothing: 0

        readonly property real windowLeft: root.xOf(root.windowFrom)
        readonly property real windowRight: root.xOf(root.windowTo)

        cursorShape: {
            if (mouse.mode === "select")
                return Qt.CrossCursor;
            if (mouseX < root.plotLeft)
                return Qt.ArrowCursor;
            if (Math.abs(mouseX - windowLeft) < 6 || Math.abs(mouseX - windowRight) < 6)
                return Qt.SizeHorCursor;
            if (mouseX > windowLeft && mouseX < windowRight)
                return pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor;
            return Qt.PointingHandCursor;
        }

        onPressed: event => {
            mouse.pressX = event.x;
            mouse.pressAt = root.atOf(event.x);
            root.fleet.preview = null;
            mouse.pressAnchor = root.fleet.committed;
            mouse.pressSmoothing = root.fleet.smoothing;
            if (Math.abs(event.x - windowLeft) < 6)
                mouse.mode = "from";
            else if (Math.abs(event.x - windowRight) < 6)
                mouse.mode = "to";
            else if (event.x > windowLeft && event.x < windowRight)
                mouse.mode = "move";
            else
                mouse.mode = "click";
        }

        onExited: {
            root.pointer = null;
            root.fleet.preview = null;
        }
        onPositionChanged: event => {
            root.pointer = Qt.point(event.x, event.y);
            if (!pressed) {
                const inPlot = event.x >= root.plotLeft && event.x <= root.plotLeft + root.plotWidth && event.y < root.fleet.rows.length * root.rowHeight;
                const at = root.atOf(event.x);
                root.fleet.preview = inPlot && Math.abs(at - root.fleet.committed) > (root.span[1] - root.span[0]) / 400 ? Math.min(root.fleet.now, at) : null;
                return;
            }
            const at = root.atOf(event.x);
            const start = mouse.pressAnchor - mouse.pressSmoothing;
            if (mouse.mode === "from")
                root.fleet.smoothing = Math.max(60, mouse.pressAnchor - at);
            else if (mouse.mode === "to") {
                const end = Math.max(start + 60, at);
                root.setAnchor(end);
                root.fleet.smoothing = end - start;
            } else if (mouse.mode === "move")
                root.setAnchor(Math.min(root.fleet.now, mouse.pressAnchor + at - mouse.pressAt));
            else if ((mouse.mode === "click" && Math.abs(event.x - mouse.pressX) > 6) || mouse.mode === "select") {
                mouse.mode = "select";
                canvas.selectFrom = mouse.pressX;
                canvas.selectTo = event.x;
            }
        }

        onReleased: event => {
            if (mouse.mode === "click")
                root.setAnchor(root.atOf(event.x));
            else if (mouse.mode === "select") {
                const a = root.atOf(canvas.selectFrom);
                const b = root.atOf(canvas.selectTo);
                canvas.selectFrom = -1;
                canvas.selectTo = -1;
                root.setRange(Math.min(a, b), Math.max(a, b));
            }
            mouse.mode = "";
        }

        onDoubleClicked: {
            root.fleet.anchor = null;
            root.setRange(root.fleet.now - 86400, root.fleet.now);
        }

        onWheel: wheel => {
            const dx = wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.angleDelta.x / 4;
            const dy = wheel.angleDelta.y;
            if (dx !== 0 || (wheel.modifiers & Qt.ShiftModifier))
                root.panBy(-(dx !== 0 ? dx : dy / 4) / Math.max(1, root.plotWidth));
            else if (dy !== 0)
                root.zoomAround(root.atOf(wheel.x), dy > 0 ? 0.8 : 1.25);
        }
    }

    Rectangle {
        visible: root.hovered !== null
        x: root.pointer ? Math.round(root.pointer.x) : 0
        y: 0
        width: 1
        height: root.fleet.rows.length * root.rowHeight
        color: Colours.palette.m3onSurface
    }

    FleetTooltip {
        at: root.pointer ?? Qt.point(0, 0)
        boundsWidth: root.width
        boundsHeight: root.height
        lines: root.describe(root.hovered)
    }
}
