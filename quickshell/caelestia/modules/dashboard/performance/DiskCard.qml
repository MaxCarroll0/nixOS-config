pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

StyledRect {
    id: root

    readonly property color accent: Colours.palette.m3secondary
    readonly property var head: ledger.head
    readonly property var shownSegments: ledger.segments.filter(segment => segment.bytes > 0).concat([{ key: "free", label: "free", color: "transparent", bytes: ledger.free, free: true }])

    color: Colours.tPalette.m3surfaceContainer
    radius: Tokens.rounding.medium

    implicitWidth: layout.implicitWidth + Tokens.padding.extraLarge * 2
    implicitHeight: layout.implicitHeight + Tokens.padding.large * 2

    DiskLedgerModel {
        id: ledger
    }

    ColumnLayout {
        id: layout

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Tokens.padding.extraLarge
        spacing: Tokens.spacing.small

        RowLayout {
            spacing: Tokens.spacing.small

            MaterialIcon {
                text: "storage"
                fill: 1
                color: root.accent
                fontStyle: Tokens.font.icon.medium
            }

            StyledText {
                text: "Disk"
                font: Tokens.font.title.medium
            }

            Item {
                Layout.fillWidth: true
            }

            Row {
                visible: ledger.collecting
                spacing: Tokens.spacing.extraSmall

                MaterialIcon {
                    id: spinner

                    anchors.verticalCenter: parent.verticalCenter
                    text: "autorenew"
                    color: Colours.palette.m3tertiary
                    fontStyle: Tokens.font.icon.medium

                    RotationAnimation on rotation {
                        from: 0
                        to: 360
                        duration: 1600
                        loops: Animation.Infinite
                        running: ledger.collecting
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ledger.collectingText
                    font: Tokens.font.body.medium
                    color: Colours.palette.m3tertiary
                }
            }

            StyledText {
                text: ledger.loaded ? `${ledger.gib(ledger.free)} free` : "no ledger yet"
                font: Tokens.font.title.medium
                color: ledger.deficit > 0 ? Colours.palette.m3error : Colours.palette.m3onSurface
            }

            StyledText {
                visible: ledger.loaded
                text: `of ${ledger.gib(ledger.diskTotal)}`
                font: Tokens.font.body.medium
                color: Colours.palette.m3onSurfaceVariant
            }
        }

        DiskBar {
            id: bar

            Layout.fillWidth: true
            Layout.preferredHeight: 22
            Layout.bottomMargin: 12
            model: ledger
        }

        Flow {
            Layout.fillWidth: true
            spacing: Tokens.spacing.medium

            Repeater {
                model: root.shownSegments.length

                delegate: Item {
                    id: legend

                    required property int index
                    readonly property var modelData: root.shownSegments[index] ?? ({})

                    implicitWidth: legendRow.implicitWidth
                    implicitHeight: legendRow.implicitHeight

                    readonly property bool lit: bar.hovered === legend.modelData.key

                    opacity: bar.hovered === "" || legend.lit ? 1 : 0.5

                    Row {
                        id: legendRow

                        spacing: Tokens.spacing.extraSmall

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        implicitWidth: legend.lit ? 10 : 8
                        implicitHeight: implicitWidth
                        radius: 2
                        color: legend.modelData.color
                        border.width: legend.lit && !legend.modelData.free ? 1 : 0
                        border.color: Colours.palette.m3onSurface

                        Outline {
                            visible: legend.modelData.free === true
                            hatched: true
                            lineWidth: 1
                            color: ledger.hatchColor
                        }
                    }

                    StyledText {
                        text: `${legend.modelData.label} ${ledger.gib(legend.modelData.bytes)}`
                        font: legend.lit ? Tokens.font.body.builders.small.weight(Font.DemiBold).build() : Tokens.font.body.small
                        color: legend.lit ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                    }

                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: bar.hovered = legend.modelData.key
                        onExited: if (bar.hovered === legend.modelData.key) bar.hovered = ""
                    }
                }
            }
        }

        Flow {
            id: facts

            Layout.fillWidth: true
            visible: ledger.loaded
            spacing: Tokens.spacing.medium

            Repeater {
                model: {
                    const out = [[ledger.live ? "live" : Qt.formatDateTime(ledger.updated, "HH:mm"), ""]];
                    if (ledger.collecting)
                        out.push(["collecting", ledger.collectingStage]);
                    if (ledger.deficit > 0)
                        out.push(["to target", ledger.gib(ledger.deficit)]);
                    else if (root.head)
                        out.push(["next", `${root.head.label} ${ledger.gib(root.head.size)}, used ${ledger.ago(root.head.last_used)}`]);
                    return out;
                }

                delegate: Row {
                    id: fact

                    required property var modelData

                    spacing: Tokens.spacing.extraSmall

                    StyledText {
                        id: key

                        text: fact.modelData[0]
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    StyledText {
                        visible: fact.modelData[1] !== ""
                        width: Math.min(implicitWidth, facts.width - key.implicitWidth - fact.spacing)
                        elide: Text.ElideMiddle
                        text: fact.modelData[1]
                        font: Tokens.font.body.builders.small.weight(Font.DemiBold).build()
                        color: Colours.palette.m3onSurface
                    }
                }
            }
        }
    }
}
