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
    readonly property real scaleFloor: 1e-4
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

    function seconds(s: real): string {
        return s < 1 ? `${(s * 1000).toFixed(s < 0.01 ? 1 : 0)}ms` : `${s.toFixed(2)}s`;
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
            text: root.expanded && root.current ? `case ${root.current.case} · ${root.current.label} · limit ${root.current.limit}s` : `Per-case times (${root.cases.length} cases)`
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
                Layout.preferredWidth: 64
                horizontalAlignment: Text.AlignRight
                text: {
                    const r = versionRow.result;
                    if (!r || r.status === "not run")
                        return "not run";
                    if (r.status === "killed")
                        return `stop ${r.seconds.toFixed(1)}s`;
                    if (versionRow.wrong)
                        return r.status;
                    return root.seconds(r.seconds);
                }
                color: versionRow.wrong ? Colours.palette.m3error : versionRow.result?.met ? Colours.palette.m3onSurfaceVariant : Colours.palette.m3tertiary
                font: Tokens.font.mono.small
            }
        }
    }
}
