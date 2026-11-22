pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Grid {
    id: root

    property var entries: []
    required property var colours

    columnSpacing: Tokens.spacing.medium
    rowSpacing: 2
    flow: Grid.TopToBottom
    verticalItemAlignment: Grid.AlignVCenter

    component Glyph: Canvas {
        id: glyph

        required property string kind
        required property var colours

        implicitWidth: 22
        implicitHeight: 12

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const w = width;
            const h = height;
            const p = Colours.palette;
            const c = glyph.colours;
            const line = (dash, colour, width) => {
                ctx.setLineDash(dash);
                ctx.strokeStyle = colour;
                ctx.lineWidth = width;
                ctx.beginPath();
                ctx.moveTo(1, h / 2);
                ctx.lineTo(w - 1, h / 2);
                ctx.stroke();
            };
            const petal = colour => {
                ctx.fillStyle = Qt.alpha(colour, 0.7);
                ctx.beginPath();
                ctx.moveTo(4, h / 2);
                ctx.quadraticCurveTo(w / 2, -2, w - 3, h / 2);
                ctx.quadraticCurveTo(w / 2, h + 2, 4, h / 2);
                ctx.fill();
            };
            const bar = colour => {
                ctx.fillStyle = colour;
                ctx.fillRect(1, 2, w - 2, h - 4);
            };
            if (glyph.kind.startsWith("lane:")) {
                const width = Math.max(1, Math.min(8, 1 + 1.5 * Math.log10(+glyph.kind.slice(5) / 1000)));
                line([], Qt.alpha(p.m3onSurfaceVariant, 0.38), width);
                ctx.fillStyle = p.m3onSurface;
                ctx.beginPath();
                ctx.arc(w / 2, h / 2, Math.max(1.6, width / 2 + 0.4), 0, Math.PI * 2);
                ctx.fill();
                return;
            }
            switch (glyph.kind) {
            case "outline":
                ctx.strokeStyle = Qt.alpha(p.m3onSurface, 0.75);
                ctx.fillStyle = Qt.alpha(p.m3onSurface, 0.07);
                ctx.lineWidth = 1.5;
                ctx.beginPath();
                ctx.moveTo(1, h - 2);
                [[5, 4], [9, 7], [13, 2], [17, 6], [21, 3]].forEach(([x, y]) => ctx.lineTo(x, y));
                ctx.lineTo(21, h - 2);
                ctx.fill();
                ctx.beginPath();
                ctx.moveTo(1, h - 2);
                [[5, 4], [9, 7], [13, 2], [17, 6], [21, 3]].forEach(([x, y]) => ctx.lineTo(x, y));
                ctx.stroke();
                break;
            case "ring":
                line([2, 3], Qt.alpha(p.m3onSurfaceVariant, 0.6), 1);
                break;
            case "cpu":
                petal(c.cpu);
                break;
            case "io":
                petal(c.io);
                break;
            case "memory":
                petal(c.memory);
                break;
            case "direct":
                line([], c.direct, 1.5);
                break;
            case "relayed":
                line([5, 3], c.relayed, 1.5);
                break;
            case "down":
                line([0.5, 3.5], c.offline, 2);
                break;
            case "builds":
                ctx.fillStyle = p.m3surfaceContainerHighest;
                ctx.strokeStyle = p.m3outline;
                ctx.beginPath();
                ctx.roundedRect(1, 1, w - 2, h - 2, 5, 5);
                ctx.fill();
                ctx.stroke();
                ctx.fillStyle = p.m3onSurface;
                ctx.font = "bold 8px sans-serif";
                ctx.textAlign = "center";
                ctx.textBaseline = "middle";
                ctx.fillText("⚙", w / 2, h / 2);
                break;
            case "barDirect":
                bar(c.direct);
                break;
            case "barRelayed":
                bar(c.relayed);
                break;
            case "barDown":
                ctx.fillStyle = c.offline;
                ctx.fillRect(1, h / 2 - 2, w - 2, 4);
                break;
            case "line":
                ctx.strokeStyle = Qt.alpha(p.m3onSurface, 0.7);
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.moveTo(1, h - 3);
                [[6, 6], [10, 8], [15, 3], [21, 5]].forEach(([x, y]) => ctx.lineTo(x, y));
                ctx.stroke();
                break;
            }
        }

        Connections {
            target: Colours
            function onPaletteChanged(): void {
                glyph.requestPaint();
            }
        }
    }

    Repeater {
        model: root.entries

        delegate: Row {
            id: entry

            required property var modelData

            spacing: 6

            Glyph {
                anchors.verticalCenter: parent.verticalCenter
                kind: entry.modelData[0]
                colours: root.colours
                visible: kind !== ""
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: entry.modelData[1]
                font: Tokens.font.label.small
                color: entry.modelData[0] === "" ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
            }
        }
    }
}
