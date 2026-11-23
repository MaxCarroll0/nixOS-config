import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

ColumnLayout {
    id: root

    required property var session
    property bool expanded: false
    property int index: 0

    readonly property var cases: session.bench_cases ?? []
    readonly property var versions: (session.versions ?? []).filter(v => (v.cases ?? []).length > 0)
    readonly property var current: cases[Math.min(index, cases.length - 1)] ?? null
    readonly property var labels: {
        const l = {};
        for (const c of cases)
            l[c.case] = c.label;
        return l;
    }
    readonly property real ratioTop: {
        let t = 10;
        for (const v of versions)
            t = Math.max(t, v.tail?.worst ?? 0);
        return t;
    }
    readonly property real scaleFloor: 1e-6
    readonly property real scaleTop: {
        let t = scaleFloor * 10;
        for (const c of cases)
            t = Math.max(t, 4 * c.limit);
        for (const v of versions)
            for (const c of v.cases)
                t = Math.max(t, c.seconds ?? 0);
        return t;
    }

    function position(s: real): real {
        return Math.log(Math.max(s, scaleFloor) / scaleFloor) / Math.log(scaleTop / scaleFloor);
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

    visible: cases.length > 0 && versions.length > 0
    spacing: Tokens.spacing.extraSmall

    RowLayout {
        Layout.fillWidth: true
        spacing: 0

        IconButton {
            type: IconButton.Text
            icon: root.expanded ? "expand_less" : "bar_chart"
            onClicked: root.expanded = !root.expanded
        }

        StyledText {
            Layout.fillWidth: true
            text: !root.expanded ? `Tails: slowdown vs fastest per case, 1x to ${root.ratio(root.ratioTop)}` : root.current ? `case ${root.current.case} · ${root.current.label} · limit ${root.current.limit}s` : ""
            elide: Text.ElideRight
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
        }

        IconButton {
            visible: root.expanded
            type: IconButton.Text
            icon: "chevron_left"
            disabled: root.index <= 0
            onClicked: root.index = Math.max(0, root.index - 1)
        }

        IconButton {
            visible: root.expanded
            type: IconButton.Text
            icon: "chevron_right"
            disabled: root.index >= root.cases.length - 1
            onClicked: root.index = Math.min(root.cases.length - 1, root.index + 1)
        }
    }

    Repeater {
        model: root.expanded ? [] : root.versions

        RowLayout {
            id: tailRow

            required property var modelData
            readonly property var tail: modelData.tail ?? null

            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            StyledText {
                Layout.preferredWidth: 84
                text: tailRow.modelData.name
                elide: Text.ElideRight
                font: Tokens.font.body.small
            }

            Item {
                id: strip

                Layout.fillWidth: true
                implicitHeight: 10

                StyledRect {
                    anchors.fill: parent
                    radius: Tokens.rounding.small
                    color: Colours.palette.m3surfaceContainerHighest
                }

                Rectangle {
                    x: strip.width * root.ratioPosition(2) - 1
                    width: 1
                    height: strip.height
                    color: Colours.palette.m3outlineVariant
                }

                Repeater {
                    model: tailRow.modelData.cases.filter(c => c.ratio !== null && c.ratio !== undefined)

                    Rectangle {
                        required property var modelData
                        readonly property bool worst: !!tailRow.tail && modelData.ratio >= tailRow.tail.worst

                        x: Math.max(0, Math.min(strip.width - width, strip.width * root.ratioPosition(modelData.ratio) - width / 2))
                        y: worst ? -2 : 1
                        width: 2
                        height: worst ? strip.height + 4 : strip.height - 2
                        color: modelData.ratio > 2 ? Colours.palette.m3tertiary : Colours.palette.m3primary
                        opacity: worst ? 1 : 0.7
                    }
                }
            }

            StyledText {
                Layout.preferredWidth: 44
                horizontalAlignment: Text.AlignRight
                text: tailRow.tail ? root.ratio(tailRow.tail.median) : ""
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.mono.small
            }

            StyledText {
                Layout.preferredWidth: 88
                horizontalAlignment: Text.AlignRight
                text: tailRow.tail ? `${root.ratio(tailRow.tail.worst)} c${tailRow.tail.worst_case}` : "untimed"
                color: tailRow.tail && tailRow.tail.worst > 2 ? Colours.palette.m3tertiary : Colours.palette.m3onSurfaceVariant
                font: Tokens.font.mono.small
            }
        }
    }

    StyledText {
        visible: !root.expanded
        Layout.fillWidth: true
        text: {
            const seen = [];
            for (const v of root.versions)
                if (v.tail && v.tail.worst > 2 && !seen.includes(v.tail.worst_case))
                    seen.push(v.tail.worst_case);
            seen.sort((a, b) => a - b);
            return ["median · worst", ...seen.map(c => `c${c} ${root.labels[c] ?? ""}`)].join("   ");
        }
        wrapMode: Text.WordWrap
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    Repeater {
        model: root.expanded && root.current ? root.versions : []

        RowLayout {
            id: versionRow

            required property var modelData
            readonly property var result: modelData.cases[root.current.case] ?? null
            readonly property bool ran: !!result && result.status !== "not run"
            readonly property bool wrong: !!result && (result.status === "wrong" || result.status === "raised")

            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            StyledText {
                Layout.preferredWidth: 84
                text: versionRow.modelData.name
                elide: Text.ElideRight
                font: Tokens.font.body.small
            }

            Item {
                id: track

                Layout.fillWidth: true
                implicitHeight: 10

                StyledRect {
                    anchors.fill: parent
                    radius: Tokens.rounding.small
                    color: Colours.palette.m3surfaceContainerHighest
                }

                StyledRect {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: versionRow.ran ? Math.max(2, track.width * root.position(versionRow.result.seconds ?? 0)) : 0
                    radius: Tokens.rounding.small
                    color: versionRow.wrong ? Colours.palette.m3error : versionRow.result?.met ? Colours.palette.m3primary : Colours.palette.m3tertiary
                }

                Rectangle {
                    x: track.width * root.position(root.current.limit) - 1
                    y: -2
                    width: 2
                    height: track.height + 4
                    color: Colours.palette.m3outline
                }
            }

            StyledText {
                Layout.preferredWidth: 104
                horizontalAlignment: Text.AlignRight
                text: {
                    const r = versionRow.result;
                    if (!r || r.status === "not run")
                        return "not run";
                    if (r.status === "killed")
                        return "too slow";
                    if (versionRow.wrong)
                        return r.status;
                    return (r.ratio ?? 1) >= 1.05 ? `${root.seconds(r.seconds)} ${root.ratio(r.ratio)}` : root.seconds(r.seconds);
                }
                color: versionRow.wrong ? Colours.palette.m3error : versionRow.result?.met ? Colours.palette.m3onSurfaceVariant : Colours.palette.m3tertiary
                font: Tokens.font.mono.small
            }
        }
    }
}
