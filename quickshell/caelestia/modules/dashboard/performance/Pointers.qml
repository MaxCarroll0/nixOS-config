import QtQuick

Canvas {
    id: root

    property var marks: []
    property color color: "white"
    property real barHeight: 0
    property real size: 5

    onMarksChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        ctx.fillStyle = root.color;
        const top = root.size + 1;
        const bottom = top + root.barHeight + 1;
        for (const mark of root.marks) {
            const centre = mark.x + mark.w / 2;
            ctx.beginPath();
            ctx.moveTo(centre - root.size, top - root.size - 1);
            ctx.lineTo(centre + root.size, top - root.size - 1);
            ctx.lineTo(centre, top - 1);
            ctx.closePath();
            ctx.fill();
            ctx.beginPath();
            ctx.moveTo(centre - root.size, bottom + root.size);
            ctx.lineTo(centre + root.size, bottom + root.size);
            ctx.lineTo(centre, bottom);
            ctx.closePath();
            ctx.fill();
        }
    }
}
