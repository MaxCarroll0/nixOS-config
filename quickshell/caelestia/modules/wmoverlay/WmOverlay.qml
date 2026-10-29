pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Caelestia.Config
import qs.components
import qs.services

Scope {
    id: root

    readonly property bool active: WmState.selection.length > 0 || WmState.aceLabels.length > 0
    readonly property var boxes: Hyprland.toplevels.values.filter(t => WmState.selection.includes(`0x${t.address}`))
    property int rounding: 0

    function request(): void {
        Hyprland.refreshToplevels();
        settle.restart();
    }

    Connections {
        target: WmState

        function onSelectionChanged(): void {
            root.request();
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (root.active && ["movewindow", "movewindowv2", "openwindow", "closewindow", "changefloatingmode", "activewindowv2", "workspacev2", "fullscreen", "custom"].includes(event.name))
                root.request();
        }
    }

    Process {
        running: true
        command: ["hyprctl", "getoption", "decoration:rounding", "-j"]
        stdout: StdioCollector {
            onStreamFinished: root.rounding = JSON.parse(text).int ?? 0
        }
    }

    Timer {
        id: settle

        interval: 120
        onTriggered: Hyprland.refreshToplevels()
    }

    Timer {
        interval: 250
        repeat: true
        running: WmState.selection.length > 0
        onTriggered: root.request()
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property ShellScreen modelData

            screen: modelData
            visible: root.active
            color: "transparent"
            anchors.top: true
            anchors.bottom: true
            anchors.left: true
            anchors.right: true
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "caelestia-wmoverlay"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region {}

            Repeater {
                model: root.boxes

                Shape {
                    id: outline

                    required property var modelData
                    readonly property var ipc: modelData.lastIpcObject
                    readonly property real inset: -4
                    readonly property bool focused: Hyprland.activeToplevel?.address === modelData.address

                    visible: ipc?.at !== undefined
                    x: (ipc?.at?.[0] ?? 0) - win.modelData.x + inset
                    y: (ipc?.at?.[1] ?? 0) - win.modelData.y + inset
                    width: (ipc?.size?.[0] ?? 0) - inset * 2
                    height: (ipc?.size?.[1] ?? 0) - inset * 2
                    preferredRendererType: Shape.CurveRenderer

                    ShapePath {
                        strokeColor: outline.focused ? Colours.palette.m3primary : Colours.palette.m3tertiary
                        strokeWidth: 3
                        strokeStyle: ShapePath.DashLine
                        dashPattern: [1, 2]
                        capStyle: ShapePath.RoundCap
                        fillColor: "transparent"

                        PathRectangle {
                            width: outline.width
                            height: outline.height
                            radius: root.rounding > 0 ? root.rounding - outline.inset : 0
                        }
                    }
                }
            }

            Repeater {
                model: WmState.aceLabels

                StyledRect {
                    required property var modelData

                    x: modelData.x - win.modelData.x + Tokens.padding.medium
                    y: modelData.y - win.modelData.y + Tokens.padding.medium
                    implicitWidth: Math.max(implicitHeight, key.implicitWidth + Tokens.padding.medium * 2)
                    implicitHeight: key.implicitHeight + Tokens.padding.small * 2
                    radius: Tokens.rounding.full
                    color: Colours.palette.m3tertiary

                    StyledText {
                        id: key

                        anchors.centerIn: parent
                        text: parent.modelData.key
                        font: Tokens.font.mono.builders.large.weight(Font.Bold).build()
                        color: Colours.palette.m3onTertiary
                    }
                }
            }
        }
    }
}
