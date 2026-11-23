import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

StyledRect {
    id: root

    readonly property color accent: {
        if (Practice.phase === "paused")
            return Colours.palette.m3tertiary;
        if (Practice.reviewing)
            return Colours.palette.m3secondary;
        if (Practice.phase === "coding" && Practice.codingLeft < 300)
            return Colours.palette.m3error;
        if (Practice.phase === "coding")
            return Colours.palette.m3primary;
        return Practice.locked ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant;
    }

    implicitWidth: Tokens.sizes.bar.innerWidth
    implicitHeight: column.implicitHeight + Tokens.padding.small * 2
    radius: Tokens.rounding.full
    color: Practice.active ? Colours.palette.m3surfaceContainerHigh : "transparent"

    ColumnLayout {
        id: column

        anchors.centerIn: parent
        spacing: Tokens.spacing.extraSmall

        MaterialIcon {
            Layout.alignment: Qt.AlignHCenter
            text: Practice.phase === "paused" ? "pause_circle" : Practice.phase === "review" ? "rate_review" : Practice.phase === "records" ? "edit_note" : Practice.phase === "coding" ? "timer" : Practice.locked ? "lock_clock" : "school"
            color: root.accent
            animate: true
        }

        StyledText {
            Layout.alignment: Qt.AlignHCenter
            visible: Practice.active
            text: {
                const s = Math.max(0, Math.round(Practice.left));
                return `${Math.floor(s / 60)}\n${String(s % 60).padStart(2, "0")}`;
            }
            horizontalAlignment: Text.AlignHCenter
            lineHeight: 0.85
            color: root.accent
            font: Tokens.font.mono.builders.small.weight(Font.Medium).build()
        }

        ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 3

            Repeater {
                model: Practice.required

                StyledRect {
                    required property int index

                    Layout.alignment: Qt.AlignHCenter
                    implicitWidth: 6
                    implicitHeight: 6
                    radius: 3
                    color: index < Practice.completedToday ? Colours.palette.m3primary : Colours.palette.m3outlineVariant
                }
            }
        }
    }
}
