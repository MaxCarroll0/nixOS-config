import QtQuick

Canvas {
    id: root

    property bool dashed: false
    property bool hatched: false
    property bool faint: false
    property color color: "white"
    property real lineWidth: 1.5
    property real outset: 0

    anchors.fill: parent
    anchors.margins: -outset
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onDashedChanged: requestPaint()
    onHatchedChanged: requestPaint()
    onFaintChanged: requestPaint()
    onColorChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        ctx.strokeStyle = root.color;
        ctx.fillStyle = root.color;
        ctx.lineWidth = root.lineWidth;
        if (root.hatched && width < 2 * root.lineWidth + 4) {
            ctx.globalAlpha = root.faint ? 0.3 : 0.6;
            ctx.fillRect(0, 0, width, height);
            return;
        }
        if (root.faint)
            ctx.globalAlpha = 0.7;
        if (root.dashed || root.faint)
            ctx.setLineDash([5, 4]);
        const inset = root.lineWidth / 2;
        ctx.strokeRect(inset, inset, width - root.lineWidth, height - root.lineWidth);
        if (!root.hatched)
            return;
        const edge = root.outset + root.lineWidth;
        ctx.save();
        ctx.beginPath();
        ctx.rect(edge, edge, width - 2 * edge, height - 2 * edge);
        ctx.clip();
        ctx.setLineDash([]);
        ctx.lineCap = "butt";
        ctx.lineWidth = root.faint ? 1.25 : 1.75;
        ctx.globalAlpha = root.faint ? 0.4 : 0.7;
        for (let x = -height; x < width; x += 8) {
            ctx.beginPath();
            ctx.moveTo(x, height);
            ctx.lineTo(x + height, 0);
            ctx.stroke();
        }
        ctx.restore();
    }
}
