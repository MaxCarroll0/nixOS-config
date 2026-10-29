import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

ColumnLayout {
    id: root

    readonly property var modes: [
        {
            key: "normal",
            label: "N",
            fill: "m3onSurface",
            ink: "m3surface",
            request: `function() wm.leave_select("normal") end`
        },
        {
            key: "insert",
            label: "I",
            fill: "m3onSurface",
            ink: "m3surface",
            request: `function() wm.leave_select("reset") end`
        },
        {
            key: "select",
            label: "S",
            fill: "m3tertiary",
            ink: "m3onTertiary",
            request: `function() if hl.get_current_submap() ~= "select" then wm.select_mode() end end`
        }
    ]
    readonly property string current: WmState.select ? "select" : WmState.normal ? "normal" : "insert"
    readonly property bool open: hover.hovered

    spacing: Tokens.spacing.medium

    HoverHandler {
        id: hover
    }

    OsIcon {
        Layout.alignment: Qt.AlignHCenter
        Layout.topMargin: Tokens.padding.small
    }

    ColumnLayout {
        Layout.alignment: Qt.AlignHCenter
        spacing: Tokens.spacing.extraSmall

        Repeater {
            model: root.modes

            StyledRect {
                id: pill

                required property var modelData
                readonly property bool active: modelData.key === root.current
                readonly property bool shown: active || root.open

                Layout.alignment: Qt.AlignHCenter
                implicitWidth: Tokens.sizes.bar.innerWidth
                implicitHeight: shown ? label.implicitHeight + Tokens.padding.small * 2 : 0
                opacity: shown ? 1 : 0
                visible: implicitHeight > 0

                radius: Tokens.rounding.full
                color: active ? Colours.palette[modelData.fill] : press.containsMouse ? Colours.palette.m3surfaceContainerHighest : Colours.palette.m3surfaceContainerHigh
                border.width: active ? 2 : 1
                border.color: Colours.palette.m3outlineVariant

                StyledText {
                    id: label

                    anchors.centerIn: parent
                    text: pill.modelData.label
                    font: Tokens.font.mono.builders.small.weight(Font.Bold).build()
                    color: pill.active ? Colours.palette[pill.modelData.ink] : Colours.palette.m3onSurfaceVariant
                }

                MouseArea {
                    id: press

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (!pill.active) Hypr.dispatch(pill.modelData.request)
                }

                Behavior on implicitHeight {
                    Anim {}
                }

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }
        }
    }
}
