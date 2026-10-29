pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.components.images
import qs.services

Item {
    id: root

    readonly property var modes: [
        {
            name: "light",
            title: "Light",
            icon: "light_mode"
        },
        {
            name: "dusk",
            title: "Dusk",
            icon: "wb_twilight"
        },
        {
            name: "dark",
            title: "Dark",
            icon: "dark_mode"
        }
    ]
    readonly property int perRow: 5
    readonly property real thumbWidth: 168
    readonly property real thumbHeight: thumbWidth / 16 * 9

    property string mode
    property var wallpapers: []

    function refresh(): void {
        classes.running = true;
    }

    function choose(path: string): void {
        Quickshell.execDetached(["wallpaper-theme", "set", path]);
    }

    implicitWidth: layout.implicitWidth
    implicitHeight: layout.implicitHeight

    Component.onCompleted: refresh()
    onVisibleChanged: if (visible)
        refresh()

    Process {
        id: classes

        command: ["wallpaper-theme", "classes"]
        stdout: StdioCollector {
            onStreamFinished: {
                const parsed = JSON.parse(text);
                root.mode = parsed.mode;
                root.wallpapers = parsed.wallpapers;
            }
        }
    }

    ColumnLayout {
        id: layout

        anchors.fill: parent
        spacing: Tokens.spacing.medium

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            StyledText {
                Layout.leftMargin: Tokens.padding.small
                Layout.fillWidth: true
                text: root.mode ? `Now ${root.mode}` : ""
                font: Tokens.font.label.small
                color: Colours.palette.m3outline
            }

            IconButton {
                type: IconButton.Tonal
                icon: "visibility"
                isRound: true
                onClicked: {
                    ShellState.forActive().dashboard = false;
                    Quickshell.execDetached(["hyprctl", "dispatch", "function() wm.view() end"]);
                }
            }

            IconButton {
                type: IconButton.Tonal
                icon: "shuffle"
                isRound: true
                onClicked: Quickshell.execDetached(["wallpaper-theme", "next"])
            }
        }

        Repeater {
            model: root.modes

            StyledRect {
                id: section

                required property var modelData
                readonly property var entries: root.wallpapers.filter(w => w.class === modelData.name)

                Layout.fillWidth: true
                visible: entries.length > 0
                implicitWidth: body.implicitWidth + Tokens.padding.large * 2
                implicitHeight: body.implicitHeight + Tokens.padding.large * 2
                radius: Tokens.rounding.large
                color: Colours.tPalette.m3surfaceContainer

                ColumnLayout {
                    id: body

                    anchors.fill: parent
                    anchors.margins: Tokens.padding.large
                    spacing: Tokens.spacing.small

                    RowLayout {
                        spacing: Tokens.spacing.small

                        MaterialIcon {
                            text: section.modelData.icon
                            color: section.modelData.name === root.mode ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                        }

                        StyledText {
                            text: section.modelData.title
                            font: Tokens.font.title.small
                            color: section.modelData.name === root.mode ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                        }
                    }

                    GridLayout {
                        columns: root.perRow
                        rowSpacing: Tokens.spacing.small
                        columnSpacing: Tokens.spacing.small

                        Repeater {
                            model: section.entries

                            Item {
                                id: thumb

                                required property var modelData
                                readonly property bool current: modelData.path === Wallpapers.actualCurrent

                                implicitWidth: root.thumbWidth
                                implicitHeight: root.thumbHeight

                                ClipRect {
                                    anchors.fill: parent
                                    radius: Tokens.rounding.medium
                                    color: Colours.tPalette.m3surfaceContainerHigh

                                    FadeImage {
                                        anchors.fill: parent
                                        source: thumb.modelData.path
                                    }
                                }

                                StyledRect {
                                    anchors.fill: parent
                                    radius: Tokens.rounding.medium
                                    color: "transparent"
                                    border.width: thumb.current ? 3 : 0
                                    border.color: Colours.palette.m3primary
                                }

                                StateLayer {
                                    radius: Tokens.rounding.medium
                                    onClicked: root.choose(thumb.modelData.path)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
