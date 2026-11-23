import QtQuick
import QtQuick.Layouts
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
        return `slowdown vs fastest, 1x to ${ratio(ratioTop)} · long marks: median, max`;
    }

    visible: versions.length > 0
    spacing: 6

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

            StyledText {
                Layout.preferredWidth: 76
                text: row.modelData.name
                elide: Text.ElideRight
                color: row.modelData.correctness === "wrong" ? Colours.palette.m3error : Colours.palette.m3onSurface
                font: Tokens.font.body.small
            }

            Item {
                id: strip

                readonly property real usable: width - 2

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
                implicitHeight: 12

                StyledRect {
                    anchors.fill: parent
                    anchors.topMargin: 1
                    anchors.bottomMargin: 1
                    radius: Tokens.rounding.small
                    color: Colours.palette.m3surfaceContainerHighest
                }

                Rectangle {
                    x: strip.usable * root.ratioPosition(2)
                    width: 1
                    height: strip.height
                    color: Colours.palette.m3outlineVariant
                }

                Repeater {
                    model: row.modelData.cases ?? []

                    Rectangle {
                        required property var modelData
                        required property int index
                        readonly property real at: root.tickPosition(modelData)
                        readonly property bool lit: row.selected === index
                        readonly property int reach: index === row.worstCase ? 4 : index === row.medianCase ? 2 : -3
                        readonly property int shown: lit ? Math.max(reach, 1) : reach

                        visible: at >= 0
                        z: lit ? 3 : reach > 0 ? 2 : 1
                        x: strip.usable * Math.max(0, at) - (lit ? 1 : 0)
                        y: -shown
                        width: lit ? 4 : 2
                        height: strip.height + 2 * shown
                        radius: lit ? 1 : 0
                        color: lit ? Colours.palette.m3onSurface : root.tickColour(modelData)
                        opacity: lit ? 1 : root.picking ? 0.3 : reach > 0 ? 1 : 0.75
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.topMargin: -4
                    anchors.bottomMargin: -4
                    hoverEnabled: true
                    onExited: {
                        root.hovered = -1;
                        root.role = "";
                    }
                    onPositionChanged: mouse => {
                        const inside = mouse.y >= 4 && mouse.y <= 4 + strip.height;
                        if (inside) {
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

            StyledText {
                Layout.preferredWidth: 72
                horizontalAlignment: Text.AlignRight
                text: !root.picking ? root.summary(row.modelData) : row.selected >= 0 ? root.caseText(row.selectedResult) : ""
                elide: Text.ElideLeft
                color: {
                    const r = row.selectedResult;
                    if (root.picking)
                        return root.failed(r) ? Colours.palette.m3error : r && !r.met ? Colours.palette.m3tertiary : Colours.palette.m3onSurface;
                    if (row.modelData.correctness === "wrong")
                        return Colours.palette.m3error;
                    return row.modelData.performance === "slow" ? Colours.palette.m3tertiary : Colours.palette.m3onSurfaceVariant;
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
