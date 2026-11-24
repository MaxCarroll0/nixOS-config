import QtQuick
import qs.services

Canvas {
    id: root

    property var graph: null

    visible: graph !== null
    implicitWidth: 240
    implicitHeight: visible ? 64 : 0
    onGraphChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        const graph = root.graph;
        if (!graph)
            return;
        const scale = graph.log ? value => Math.log10(1 + Math.max(0, value) / 100) : value => Math.max(0, value);
        const series = Array.from(graph.series);
        const raw = series.reduce((all, item) => all.concat(Array.from(item.values).filter(isFinite)), []);
        const peakRaw = raw.length ? Math.max(...raw) : 0;
        const peak = Math.max(graph.log ? 1 : 0.01, scale(peakRaw));
        const top = 12;
        const bottom = height - 12;
        const count = Math.max(...series.map(item => item.values.length), 2);
        const xOf = index => width * index / (count - 1);
        const yOf = value => bottom - (bottom - top) * scale(value) / peak;

        ctx.fillStyle = Qt.alpha(Colours.palette.m3onSurface, 0.05);
        ctx.fillRect(0, top, width, bottom - top);
        for (const item of series) {
            ctx.beginPath();
            let open = false;
            Array.from(item.values).forEach((value, index) => {
                if (!isFinite(value)) {
                    open = false;
                    return;
                }
                if (open)
                    ctx.lineTo(xOf(index), yOf(value));
                else
                    ctx.moveTo(xOf(index), yOf(value));
                open = true;
            });
            ctx.strokeStyle = item.colour;
            ctx.lineWidth = 1.5;
            ctx.lineJoin = "round";
            ctx.stroke();
        }

        ctx.font = "9px sans-serif";
        ctx.fillStyle = Colours.palette.m3onSurfaceVariant;
        ctx.textBaseline = "bottom";
        ctx.textAlign = "left";
        ctx.fillText(`peak ${graph.format(peakRaw)}${graph.log ? ", log" : ""}`, 0, top - 1);
        ctx.textBaseline = "top";
        ctx.fillText(`-${graph.span}`, 0, bottom + 1);
        ctx.textAlign = "right";
        ctx.fillText("now", width, bottom + 1);
    }

    Connections {
        target: Colours
        function onPaletteChanged(): void {
            root.requestPaint();
        }
    }
}
