import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Caelestia.Config
import qs.components
import qs.services

ColumnLayout {
    id: root

    required property var session
    property int hovered: -1
    property string role: ""

    readonly property var cases: session.bench_cases ?? []
    readonly property var versions: session.versions ?? []
    readonly property bool picking: hovered >= 0 || role !== ""
    readonly property real ratioTop: {
        let t = 10;
        for (const v of versions)
            for (const c of v.cases ?? [])
                if (c.status === "ok" && c.ratio)
                    t = Math.max(t, c.ratio);
        return t;
    }

    function ratioPosition(r: real): real {
        return Math.min(1, Math.log(Math.max(r, 1)) / Math.log(ratioTop));
    }

    function seconds(s: real): string {
        if (s < 1e-6)
            return "<1µs";
        if (s < 1e-3)
            return `${Math.round(s * 1e6)}µs`;
        return s < 1 ? `${(s * 1000).toFixed(s < 0.01 ? 1 : 0)}ms` : `${s.toFixed(2)}s`;
    }

    function ratio(r: real): string {
        return r < 10 ? `${r.toFixed(1)}x` : r < 1000 ? `${Math.round(r)}x` : `${Math.round(r / 1000)}kx`;
    }

    function failed(c: var): bool {
        return !!c && (c.status === "wrong" || c.status === "raised");
    }

    function tickPosition(c: var): real {
        if (!c || c.status === "not run")
            return -1;
        if (c.status === "killed" || failed(c))
            return 1;
        return c.ratio === null || c.ratio === undefined ? -1 : ratioPosition(c.ratio);
    }

    function tickColour(c: var): color {
        if (failed(c))
            return Colours.palette.m3error;
        return c.met ? Colours.palette.m3primary : Colours.palette.m3tertiary;
    }

    function worstOf(v: var): int {
        return v.tail ? v.tail.worst_case : -1;
    }

    function medianOf(v: var): int {
        if (!v.tail)
            return -1;
        let best = -1, gap = Infinity;
        (v.cases ?? []).forEach((c, i) => {
            if (c.ratio === null || c.ratio === undefined || tickPosition(c) < 0 || i === v.tail.worst_case)
                return;
            const d = Math.abs(Math.log(c.ratio / v.tail.median));
            if (d < gap) {
                best = i;
                gap = d;
            }
        });
        return best;
    }

    function chosen(v: var): int {
        if (hovered >= 0)
            return hovered;
        return role === "median" ? medianOf(v) : role === "max" ? worstOf(v) : -1;
    }

    function summary(v: var): string {
        if (!(v.total > 0))
            return v.correctness === "unknown" ? "untested" : v.correctness;
        return v.correctness === "wrong" ? "wrong" : `${v.met}/${v.total}`;
    }

    function meanText(v: var): string {
        const timed = (v.cases ?? []).filter(c => c.status === "ok" && typeof c.seconds === "number");
        return timed.length ? seconds(timed.reduce((t, c) => t + c.seconds, 0) / timed.length) : "";
    }

    function caseText(c: var): string {
        if (!c || c.status === "not run")
            return "not run";
        if (c.status === "killed")
            return "too slow";
        if (failed(c))
            return c.status;
        return seconds(c.seconds);
    }

    function caption(): string {
        if (hovered >= 0) {
            const c = cases[hovered];
            return c ? `${c.label} · limit ${seconds(c.limit)}` : "";
        }
        if (role !== "") {
            const counts = new Map();
            for (const v of versions) {
                const i = chosen(v);
                if (i >= 0)
                    counts.set(i, (counts.get(i) ?? 0) + 1);
            }
            const parts = [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([i, n]) => `${cases[i]?.label ?? i}${n > 1 ? ` ×${n}` : ""}`);
            return `${role}: ${parts.join(", ")}`;
        }
        return `slowdown vs fastest, 1x to ${ratio(ratioTop)} · time: mean · dots: median, triangles: max`;
    }

    visible: versions.length > 0
    spacing: 0

    Repeater {
        model: root.versions

        RowLayout {
            id: row

            required property var modelData
            readonly property int worstCase: root.worstOf(modelData)
            readonly property int medianCase: root.medianOf(modelData)
            readonly property int selected: root.chosen(modelData)
            readonly property var selectedResult: selected >= 0 ? (modelData.cases ?? [])[selected] ?? null : null

            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            ElidedText {
                Layout.preferredWidth: 76
                text: row.modelData.name
                elide: Text.ElideRight
                color: row.modelData.correctness === "wrong" ? Colours.palette.m3error : Colours.palette.m3onSurface
                font: Tokens.font.body.small
            }

            Item {
                id: strip

                readonly property real usable: width - 2
                readonly property int band: 12
                readonly property int bandTop: (height - band) / 2

                function nearest(x: real, only: var): int {
                    let best = -1, gap = 8;
                    const list = row.modelData.cases ?? [];
                    for (let i = 0; i < list.length; i++) {
                        if (only && !only.includes(i))
                            continue;
                        const at = root.tickPosition(list[i]);
                        if (at < 0)
                            continue;
                        const d = Math.abs(usable * at + 1 - x) - (i === row.worstCase || i === row.medianCase ? 1 : 0);
                        if (d < gap || (d === gap && i === row.selected)) {
                            best = i;
                            gap = d;
                        }
                    }
                    return best;
                }

                Layout.fillWidth: true
                implicitHeight: 28

                StyledRect {
                    y: strip.bandTop
                    width: strip.width
                    height: strip.band
                    radius: Tokens.rounding.small
                    color: Colours.palette.m3surfaceContainerHighest
                }

                Rectangle {
                    x: strip.usable * root.ratioPosition(2)
                    y: strip.bandTop
                    width: 1
                    height: strip.band
                    color: Colours.palette.m3outlineVariant
                }

                Repeater {
                    model: row.modelData.cases ?? []

                    Rectangle {
                        required property var modelData
                        required property int index
                        readonly property real at: root.tickPosition(modelData)
                        readonly property bool lit: row.selected === index
                        readonly property bool marked: index === row.worstCase || index === row.medianCase
                        readonly property int inset: lit || marked ? 0 : 3

                        visible: at >= 0
                        z: lit ? 3 : marked ? 2 : 1
                        x: strip.usable * Math.max(0, at) - (lit ? 1 : 0)
                        y: strip.bandTop + inset
                        width: lit ? 4 : 2
                        height: strip.band - 2 * inset
                        radius: lit ? 1 : 0
                        color: lit ? Colours.palette.m3onSurface : root.tickColour(modelData)
                        opacity: lit ? 1 : root.picking ? 0.3 : marked ? 1 : 0.6
                    }
                }

                Repeater {
                    model: [
                        { role: "median", top: true },
                        { role: "median", top: false },
                        { role: "max", top: true },
                        { role: "max", top: false }
                    ]

                    Item {
                        id: marker

                        required property var modelData
                        readonly property bool max: modelData.role === "max"
                        readonly property int index: max ? row.worstCase : row.medianCase
                        readonly property var result: index >= 0 ? (row.modelData.cases ?? [])[index] ?? null : null
                        readonly property real at: result ? root.tickPosition(result) : -1
                        readonly property bool active: root.role === modelData.role
                        readonly property color fill: active ? Colours.palette.m3onSurface : max ? root.tickColour(result) : Colours.palette.m3onSurfaceVariant

                        visible: at >= 0
                        z: max ? 2 : 1
                        width: max ? 9 : 5
                        height: 5
                        x: Math.max(0, Math.min(strip.width - width, strip.usable * at + 1 - width / 2))
                        y: modelData.top ? strip.bandTop - 3 - height : strip.bandTop + strip.band + 3
                        opacity: active || !root.picking ? 1 : 0.3

                        Rectangle {
                            anchors.fill: parent
                            visible: !marker.max
                            radius: width / 2
                            color: marker.fill
                        }

                        Shape {
                            anchors.fill: parent
                            visible: marker.max
                            preferredRendererType: Shape.CurveRenderer

                            ShapePath {
                                strokeWidth: -1
                                fillColor: marker.fill
                                startX: 0
                                startY: marker.modelData.top ? 0 : marker.height

                                PathLine {
                                    x: marker.width
                                    y: marker.modelData.top ? 0 : marker.height
                                }

                                PathLine {
                                    x: marker.width / 2
                                    y: marker.modelData.top ? marker.height : 0
                                }
                            }
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onExited: {
                        root.hovered = -1;
                        root.role = "";
                    }
                    onPositionChanged: mouse => {
                        if (mouse.y >= strip.bandTop - 1 && mouse.y <= strip.bandTop + strip.band + 1) {
                            root.role = "";
                            root.hovered = strip.nearest(mouse.x, null);
                            return;
                        }
                        const mark = strip.nearest(mouse.x, [row.medianCase, row.worstCase]);
                        root.hovered = -1;
                        root.role = mark < 0 ? "" : mark === row.worstCase ? "max" : "median";
                    }
                }
            }

            ElidedText {
                Layout.preferredWidth: 40
                horizontalAlignment: Text.AlignRight
                text: !root.picking ? root.summary(row.modelData) : row.selected >= 0 ? `#${row.selected}` : ""
                elide: Text.ElideLeft
                color: {
                    if (root.picking)
                        return Colours.palette.m3onSurface;
                    if (row.modelData.correctness === "wrong")
                        return Colours.palette.m3error;
                    return row.modelData.performance === "slow" ? Colours.palette.m3tertiary : Colours.palette.m3onSurfaceVariant;
                }
                font: Tokens.font.mono.small
            }

            ElidedText {
                Layout.preferredWidth: 56
                horizontalAlignment: Text.AlignRight
                text: !root.picking ? root.meanText(row.modelData) : row.selected >= 0 ? root.caseText(row.selectedResult) : ""
                elide: Text.ElideLeft
                color: {
                    const r = row.selectedResult;
                    if (root.picking)
                        return root.failed(r) ? Colours.palette.m3error : r && !r.met ? Colours.palette.m3tertiary : Colours.palette.m3onSurface;
                    return Colours.palette.m3onSurfaceVariant;
                }
                font: Tokens.font.mono.small
            }
        }
    }

    StyledText {
        Layout.fillWidth: true
        visible: root.cases.length > 0
        text: root.caption()
        wrapMode: Text.WordWrap
        color: root.picking ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }
}
