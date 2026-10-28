pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.services

Scope {
    id: root

    property bool shown
    readonly property int rowsPerColumn: 8

    readonly property var entries: (WmState.mode?.entries ?? []).map(e => ({
                chord: WmState.chord(e.mods, e.key),
                desc: e.desc,
                prefix: e.prefix,
                insert: e.insert
            })).sort((a, b) => a.chord.localeCompare(b.chord))

    readonly property var path: (WmState.mode?.path ?? []).map(p => p.label ?? WmState.chord(p.mods, p.key))

    Timer {
        id: delay

        interval: 400
        onTriggered: root.shown = WmState.prefixActive
    }

    Connections {
        target: WmState

        function onSubmapChanged(): void {
            if (!WmState.prefixActive) {
                delay.stop();
                root.shown = false;
            } else if (!root.shown) {
                delay.restart();
            }
        }
    }

    StyledWindow {
        name: "whichkey"

        screen: Quickshell.screens.find(s => s.name === Hypr.focusedMonitor?.name) ?? Quickshell.screens[0]
        visible: root.shown || panel.opacity > 0

        anchors.bottom: true
        margins.bottom: Tokens.padding.large * 3
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}

        implicitWidth: panel.implicitWidth
        implicitHeight: panel.implicitHeight

        StyledRect {
            id: panel

            implicitWidth: body.implicitWidth + Tokens.padding.large * 2
            implicitHeight: body.implicitHeight + Tokens.padding.large * 2

            radius: Tokens.rounding.large
            color: Colours.tPalette.m3surfaceContainer
            border.width: 1
            border.color: Colours.palette.m3outlineVariant

            opacity: root.shown ? 1 : 0
            scale: root.shown ? 1 : 0.96

            ColumnLayout {
                id: body

                anchors.fill: parent
                anchors.margins: Tokens.padding.large
                spacing: Tokens.spacing.medium

                RowLayout {
                    spacing: Tokens.spacing.small

                    Repeater {
                        model: root.path

                        KeyCap {
                            required property string modelData

                            text: modelData
                            prominent: true
                        }
                    }

                    StyledText {
                        Layout.leftMargin: Tokens.spacing.small
                        text: WmState.mode?.title ?? ""
                        font: Tokens.font.title.small
                        color: Colours.palette.m3primary
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    StyledText {
                        Layout.leftMargin: Tokens.spacing.large
                        text: WmState.mode?.sticky ? "ESC to leave" : "ESC to cancel"
                        font: Tokens.font.label.small
                        color: Colours.palette.m3outline
                    }
                }

                GridLayout {
                    flow: GridLayout.TopToBottom
                    rows: Math.min(root.entries.length, root.rowsPerColumn)
                    rowSpacing: Tokens.spacing.extraSmall
                    columnSpacing: Tokens.spacing.large * 2

                    Repeater {
                        model: root.entries

                        RowLayout {
                            id: entry

                            required property var modelData

                            spacing: Tokens.spacing.medium

                            Item {
                                Layout.preferredWidth: 72
                                implicitHeight: cap.implicitHeight

                                KeyCap {
                                    id: cap

                                    text: entry.modelData.chord
                                }
                            }

                            StyledText {
                                Layout.preferredWidth: 220
                                text: entry.modelData.prefix ? `+${entry.modelData.desc}` : entry.modelData.desc
                                font: Tokens.font.body.small
                                color: entry.modelData.prefix ? Colours.palette.m3tertiary : Colours.palette.m3onSurfaceVariant
                                elide: Text.ElideRight
                            }

                            MaterialIcon {
                                visible: entry.modelData.insert && WmState.normal
                                text: "keyboard_return"
                                color: Colours.palette.m3outline
                                fontStyle: Tokens.font.icon.small
                            }
                        }
                    }
                }
            }

            Behavior on opacity {
                Anim {}
            }

            Behavior on scale {
                Anim {}
            }
        }
    }
}
