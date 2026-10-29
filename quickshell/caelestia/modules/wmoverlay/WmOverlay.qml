pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Caelestia.Config
import qs.components
import qs.services

Scope {
    id: root

    readonly property bool active: WmState.selection.length > 0 || WmState.aceLabels.length > 0
    property var boxes: []

    function refresh(): void {
        const wanted = WmState.selection;
        boxes = Hyprland.toplevels.values.filter(t => wanted.includes(`0x${t.address}`) && t.lastIpcObject?.at).map(t => ({
                    address: `0x${t.address}`,
                    x: t.lastIpcObject.at[0],
                    y: t.lastIpcObject.at[1],
                    w: t.lastIpcObject.size[0],
                    h: t.lastIpcObject.size[1]
                }));
    }

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

    Connections {
        target: Hyprland.toplevels

        function onValuesChanged(): void {
            root.refresh();
        }
    }

    Timer {
        id: settle

        interval: 400
        onTriggered: {
            Hyprland.refreshToplevels();
            root.refresh();
        }
    }

    Timer {
        interval: 500
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
                    readonly property real inset: -4
                    readonly property bool focused: `0x${Hyprland.activeToplevel?.address}` === modelData.address

                    x: modelData.x - win.modelData.x + inset
                    y: modelData.y - win.modelData.y + inset
                    width: modelData.w - inset * 2
                    height: modelData.h - inset * 2
                    preferredRendererType: Shape.CurveRenderer

                    ShapePath {
                        strokeColor: outline.focused ? Colours.palette.m3primary : Colours.palette.m3tertiary
                        strokeWidth: 3
                        strokeStyle: ShapePath.DashLine
                        dashPattern: [1, 2]
                        capStyle: ShapePath.RoundCap
                        fillColor: "transparent"

                        startX: 0
                        startY: 0
                        PathLine {
                            x: outline.width
                            y: 0
                        }
                        PathLine {
                            x: outline.width
                            y: outline.height
                        }
                        PathLine {
                            x: 0
                            y: outline.height
                        }
                        PathLine {
                            x: 0
                            y: 0
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
