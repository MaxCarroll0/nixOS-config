import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components.controls
import qs.services

RowLayout {
    id: root

    required property var session

    visible: session.complete && !!session.dir
    spacing: Tokens.spacing.extraSmall

    Repeater {
        model: [
            {
                what: "prompt",
                icon: "description",
                label: "Prompt",
                shown: true
            },
            {
                what: "code",
                icon: "code",
                label: "Code",
                shown: true
            },
            {
                what: "review",
                icon: "rate_review",
                label: "Review",
                shown: !!root.session.review_md
            },
            {
                what: "revisit",
                icon: "edit_note",
                label: "Revisit",
                shown: !Practice.active
            }
        ]

        IconTextButton {
            required property var modelData

            Layout.fillWidth: true
            visible: modelData.shown
            icon: modelData.icon
            text: modelData.label
            horizontalPadding: Tokens.padding.small
            verticalPadding: Tokens.padding.extraSmall
            inactiveColour: Colours.palette.m3surfaceContainerHighest
            inactiveOnColour: Colours.palette.m3onSurface
            onClicked: Practice.openSession(root.session.dir, modelData.what)
        }
    }
}
