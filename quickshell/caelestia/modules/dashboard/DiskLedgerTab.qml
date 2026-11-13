pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    property var ledger: ({})
    readonly property var store: ledger.store ?? ({})
    readonly property var files: ledger.files ?? ({})

    function sum(values: var): real {
        let total = 0;
        for (const key in values)
            total += values[key] ?? 0;
        return total;
    }

    function gib(bytes: real): string {
        return `${(bytes / 1073741824).toFixed(1)} GiB`;
    }

    readonly property var segments: [
        { label: "system", value: store.system ?? 0, color: Colours.palette.m3primary, reclaim: false },
        { label: "home", value: store.home ?? 0, color: Colours.palette.m3tertiary, reclaim: false },
        { label: "generations", value: store.generations ?? 0, color: Colours.palette.m3primaryContainer, reclaim: false },
        { label: "project tier 1", value: store.project_tier1 ?? 0, color: Colours.palette.m3outline, reclaim: true },
        { label: "project tier 2", value: store.project_tier2 ?? 0, color: Colours.palette.m3outlineVariant, reclaim: true },
        { label: "fetched", value: store.fetched ?? 0, color: Colours.palette.m3onSurfaceVariant, reclaim: true },
        { label: "garbage", value: store.garbage ?? 0, color: Colours.palette.m3onSurface, reclaim: true },
        { label: "files", value: sum(files), color: Colours.palette.m3onPrimaryContainer, reclaim: false },
        { label: "free", value: ledger.free ?? 0, color: Colours.palette.m3onSurface, reclaim: false, alpha: 0.2 }
    ]

    readonly property real total: Math.max(1, sum(segments.map(segment => segment.value)))

    FileView {
        path: `${Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"}/disk-ledger.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.ledger = JSON.parse(text());
            } catch (e) {}
        }
    }

    implicitWidth: card.implicitWidth
    implicitHeight: card.implicitHeight

    Rectangle {
        id: card

        implicitWidth: body.implicitWidth + Tokens.padding.large * 2
        implicitHeight: body.implicitHeight + Tokens.padding.large * 2

        radius: Tokens.rounding.large
        color: Colours.tPalette.m3surfaceContainer

        ColumnLayout {
            id: body

            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            spacing: Tokens.spacing.small

            StyledText {
                text: "Disk"
                font: Tokens.font.title.small
                color: Colours.palette.m3primary
            }

            Row {
                id: bar

                Layout.fillWidth: true
                Layout.preferredHeight: 22
                spacing: 0

                Repeater {
                    model: root.segments

                    delegate: Rectangle {
                        id: piece

                        required property var modelData

                        width: bar.width * piece.modelData.value / root.total
                        height: bar.height
                        color: piece.modelData.color
                        opacity: piece.modelData.alpha ?? (piece.modelData.reclaim ? 0.55 : 1)
                    }
                }
            }

            Repeater {
                model: root.segments

                delegate: RowLayout {
                    id: legend

                    required property var modelData

                    Layout.fillWidth: true
                    spacing: Tokens.spacing.small

                    Rectangle {
                        implicitWidth: 10
                        implicitHeight: 10
                        radius: 2
                        color: legend.modelData.color
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: legend.modelData.label
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    StyledText {
                        text: root.gib(legend.modelData.value)
                        font: Tokens.font.mono.small
                        color: Colours.palette.m3onSurface
                    }
                }
            }
        }
    }
}
