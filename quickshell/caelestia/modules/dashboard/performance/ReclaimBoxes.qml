import QtQuick

Canvas {
    id: root

    property var spans: []
    property color color: "white"
    property real lineWidth: 2
    property real gap: 2

    readonly property var merged: {
        const sorted = root.spans.filter(span => span.w > 0).sort((a, b) => a.x - b.x);
        const out = [];
        for (const span of sorted) {
            const last = out[out.length - 1];
            if (last && span.x <= last.x + last.w + root.gap)
                last.w = Math.max(last.w, span.x + span.w - last.x);
            else
                out.push({ x: span.x, w: span.w });
        }
        return out;
    }

    onMergedChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        ctx.strokeStyle = root.color;
        ctx.fillStyle = root.color;
        ctx.lineWidth = root.lineWidth;
        const inset = root.lineWidth / 2;
        for (const span of root.merged) {
            if (span.w < 2 * root.lineWidth + 3) {
                ctx.fillRect(Math.round(span.x + span.w / 2 - root.lineWidth / 2), 0, root.lineWidth, height);
                continue;
            }
            ctx.strokeRect(span.x + inset, inset, span.w - root.lineWidth, height - root.lineWidth);
        }
    }
}
