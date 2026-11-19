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
    readonly property real windowFrom: fleet.at - fleet.smoothing
    readonly property real windowTo: fleet.at

    implicitHeight: Math.max(1, fleet.rows.length) * rowHeight + axisHeight

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
            if (!isFinite(online))
                return null;
            if (online < 0.05)
                return Qt.alpha(Colours.palette.m3error, 0.55);
            if (isFinite(direct) && direct < 0.5)
                return Qt.alpha(Colours.palette.m3tertiary, 0.35 + 0.5 * online);
            return Qt.alpha(Colours.palette.m3primary, 0.25 + 0.5 * online);
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
                ctx.fillText(root.fleet.displayName(row.name), root.labelWidth - 8, top + root.rowHeight / 2);
                const count = row.online.length;
                for (let i = 0; i < count; i++) {
                    const colour = canvas.stateColour(row.online[i], row.direct[i]);
                    if (!colour)
                        continue;
                    ctx.fillStyle = colour;
                    const at = row.from + i * row.step;
                    const left = Math.max(root.plotLeft, Math.round(root.xOf(at - row.step / 2)));
                    const right = Math.min(root.plotLeft + root.plotWidth, Math.round(root.xOf(at + row.step / 2)));
                    if (right > left)
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
                ctx.strokeStyle = Qt.alpha(Colours.palette.m3onSurface, 0.7);
                ctx.lineWidth = 1;
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
            ctx.fillStyle = Qt.alpha(Colours.palette.m3secondary, 0.22);
            ctx.fillRect(left, 0, right - left, axisTop);
            ctx.fillStyle = Colours.palette.m3secondary;
            ctx.fillRect(left, 0, 2, axisTop);
            ctx.fillRect(right - 2, 0, 2, axisTop);

            if (canvas.selectFrom >= 0 && canvas.selectTo >= 0) {
                ctx.fillStyle = Qt.alpha(Colours.palette.m3primary, 0.18);
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
            mouse.pressAnchor = root.fleet.at;
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

        onPositionChanged: event => {
            if (!pressed)
                return;
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
}
