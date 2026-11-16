import QtQuick

Canvas {
    id: root

    property var spans: []
    property color color: "white"

    onSpansChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        if (!root.spans.length)
            return;
        ctx.beginPath();
        for (const span of root.spans)
            ctx.rect(span.x, 0, span.w, height);
        ctx.clip();
        ctx.strokeStyle = root.color;
        ctx.lineWidth = 0.9;
        ctx.globalAlpha = 0.85;
        for (let x = -height; x < width + height; x += 6) {
            ctx.beginPath();
            ctx.moveTo(x, 0);
            ctx.lineTo(x + height, height);
            ctx.stroke();
        }
    }
}
