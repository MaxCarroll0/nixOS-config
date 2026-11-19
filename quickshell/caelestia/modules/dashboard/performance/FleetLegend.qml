pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Grid {
    id: root

    property var entries: []

    columnSpacing: Tokens.spacing.medium
    rowSpacing: 2
    flow: Grid.TopToBottom
    verticalItemAlignment: Grid.AlignVCenter

    component Glyph: Canvas {
        id: glyph

        required property string kind

        implicitWidth: 22
        implicitHeight: 12

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const w = width;
            const h = height;
            const p = Colours.palette;
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
                ctx.fillStyle = Qt.alpha(colour, 0.55);
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
            switch (glyph.kind) {
            case "outline":
                ctx.strokeStyle = p.m3onSurfaceVariant;
                ctx.fillStyle = Qt.alpha(p.m3onSurfaceVariant, 0.18);
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
                line([2, 3], Qt.alpha(p.m3outline, 0.9), 1);
                break;
            case "cpu":
                petal(p.m3primary);
                break;
            case "io":
                petal(p.m3tertiary);
                break;
            case "memory":
                petal(p.m3error);
                break;
            case "direct":
                line([], Qt.alpha(p.m3onSurfaceVariant, 0.8), 2);
                break;
            case "relayed":
                line([4, 3], Qt.alpha(p.m3onSurfaceVariant, 0.8), 2);
                break;
            case "down":
                line([1, 4], Qt.alpha(p.m3outline, 0.8), 1.5);
                break;
            case "traffic":
                ctx.fillStyle = p.m3onSurfaceVariant;
                [4, 11, 18].forEach((x, i) => {
                    ctx.globalAlpha = 0.4 + 0.3 * i;
                    ctx.beginPath();
                    ctx.arc(x, h / 2, 2, 0, Math.PI * 2);
                    ctx.fill();
                });
                break;
            case "builds":
                ctx.fillStyle = p.m3tertiaryContainer;
                ctx.beginPath();
                ctx.roundedRect(1, 1, w - 2, h - 2, 5, 5);
                ctx.fill();
                ctx.fillStyle = p.m3onTertiaryContainer;
                ctx.font = "bold 8px sans-serif";
                ctx.textAlign = "center";
                ctx.textBaseline = "middle";
                ctx.fillText("⚙", w / 2, h / 2);
                break;
            case "barDirect":
                bar(Qt.alpha(p.m3primary, 0.6));
                break;
            case "barRelayed":
                bar(Qt.alpha(p.m3tertiary, 0.7));
                break;
            case "barDown":
                bar(Qt.alpha(p.m3error, 0.55));
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
