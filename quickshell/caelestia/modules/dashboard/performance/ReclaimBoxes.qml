import QtQuick
import "boxes.js" as Boxes

Canvas {
    id: root

    property var spans: []
    property color color: "white"
    property real lineWidth: 2
    property real outset: 0
    readonly property real minBox: 2 * root.lineWidth + 3

    readonly property var merged: Boxes.merge(root.spans, root.minBox)

    function edge(ctx: var, from: real, to: real, y: real, notches: var): void {
        let at = from;
        for (const notch of notches) {
            const cut = notch - root.lineWidth / 2;
            if (cut > at)
                ctx.fillRect(at, y, cut - at, root.lineWidth);
            at = Math.max(at, notch + root.lineWidth / 2);
        }
        if (to > at)
            ctx.fillRect(at, y, to - at, root.lineWidth);
    }

    onMergedChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        ctx.fillStyle = root.color;
        const line = root.lineWidth;
        for (const span of root.merged) {
            if (span.w < root.minBox) {
                ctx.fillRect(Math.round(span.x + span.w / 2 - line / 2), 0, line, height);
                continue;
            }
            ctx.fillRect(span.x, 0, line, height);
            ctx.fillRect(span.x + span.w - line, 0, line, height);
            root.edge(ctx, span.x + line, span.x + span.w - line, 0, span.notches);
            root.edge(ctx, span.x + line, span.x + span.w - line, height - line, span.notches);
        }
    }
}
