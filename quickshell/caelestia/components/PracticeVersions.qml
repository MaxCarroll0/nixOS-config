import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

GridLayout {
    id: root

    required property var session

    function seconds(s: real): string {
        return s < 1 ? `${Math.round(s * 1000)}ms` : `${s.toFixed(2)}s`;
    }

    visible: (session.versions ?? []).length > 0
    columns: 4
    columnSpacing: Tokens.spacing.small
    rowSpacing: 0

    Repeater {
        model: {
            const cells = [];
            for (const v of root.session.versions ?? []) {
                const benched = v.total > 0;
                const correctness = v.correctness;
                const performance = v.performance;
                cells.push({
                    text: v.name,
                    tone: "",
                    mono: false,
                    fill: true
                }, {
                    text: correctness === "unknown" ? "?" : correctness,
                    tone: correctness === "wrong" ? "error" : "",
                    mono: true,
                    fill: false
                }, {
                    text: performance === "unknown" ? "-" : !benched ? "slow" : performance === "met" ? `${v.met}/${v.total}` : `slow ${v.met}/${v.total}`,
                    tone: performance === "met" ? "primary" : performance === "slow" ? "tertiary" : "",
                    mono: true,
                    fill: false
                }, {
                    text: benched && performance !== "unknown" ? root.seconds(v.time ?? v.slowest ?? 0) : "",
                    tone: "",
                    mono: true,
                    fill: false
                });
            }
            return cells;
        }

        StyledText {
            required property var modelData

            Layout.fillWidth: modelData.fill
            Layout.alignment: modelData.fill ? Qt.AlignLeft : Qt.AlignRight
            text: modelData.text
            elide: Text.ElideRight
            color: modelData.tone === "error" ? Colours.palette.m3error : modelData.tone === "primary" ? Colours.palette.m3primary : modelData.tone === "tertiary" ? Colours.palette.m3tertiary : Colours.palette.m3onSurfaceVariant
            font: modelData.mono ? Tokens.font.mono.small : Tokens.font.body.small
        }
    }
}
