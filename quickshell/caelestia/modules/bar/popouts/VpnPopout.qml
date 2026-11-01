pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

ColumnLayout {
    id: root

    readonly property bool locked: Vpn.busy !== ""

    width: 280
    spacing: Tokens.spacing.small

    Component.onCompleted: Vpn.refresh()

    StyledText {
        Layout.topMargin: Tokens.padding.medium
        text: "Proton VPN"
        font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
    }

    StyledText {
        Layout.fillWidth: true
        text: {
            if (!Vpn.present)
                return "No status from vpn-status";
            if (Vpn.busy)
                return `Working: ${Vpn.busy}`;
            if (Vpn.failed)
                return `Failed: ${Vpn.failed}, previous peer kept`;
            if (!Vpn.enabled)
                return "Disabled: traffic leaves in the clear";
            return Vpn.up ? "Connected" : "Tunnel down";
        }
        color: Vpn.failed || (Vpn.present && !Vpn.busy && (!Vpn.enabled || !Vpn.up)) ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
        wrapMode: Text.WordWrap
    }

    GridLayout {
        Layout.topMargin: Tokens.spacing.small
        Layout.fillWidth: true
        columns: 2
        columnSpacing: Tokens.spacing.medium
        rowSpacing: Tokens.spacing.extraSmall

        Field {
            text: "Server"
        }
        Value {
            text: Vpn.server || "unknown"
        }
        Field {
            text: "Endpoint"
        }
        Value {
            text: Vpn.endpoint || "none"
        }
        Field {
            text: "Handshake"
        }
        Value {
            text: Vpn.age(Vpn.handshakeAge)
        }
        Field {
            text: "Traffic"
        }
        Value {
            text: `↓ ${Vpn.bytes(Vpn.rx)}  ↑ ${Vpn.bytes(Vpn.tx)}`
        }
    }

    StyledText {
        Layout.topMargin: Tokens.spacing.medium
        text: "Exit country"
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    Flow {
        Layout.fillWidth: true
        spacing: Tokens.spacing.small

        Repeater {
            model: Vpn.countries

            TextButton {
                required property string modelData

                type: TextButton.Tonal
                isToggle: true
                checked: Vpn.country === modelData
                disabled: root.locked
                text: modelData
                font: Tokens.font.mono.small
                onClicked: Vpn.run(`country-${modelData}`)
            }
        }
    }

    RowLayout {
        Layout.topMargin: Tokens.spacing.medium
        Layout.fillWidth: true
        spacing: Tokens.spacing.small

        IconTextButton {
            Layout.fillWidth: true
            icon: "shuffle"
            text: "Re-pick"
            disabled: root.locked || !Vpn.enabled
            inactiveColour: Colours.palette.m3primaryContainer
            inactiveOnColour: Colours.palette.m3onPrimaryContainer
            verticalPadding: Tokens.padding.extraSmall
            onClicked: Vpn.run("repick")
        }

        IconTextButton {
            Layout.fillWidth: true
            icon: "shield"
            text: "Secure Core"
            disabled: root.locked || !Vpn.enabled
            inactiveColour: Colours.palette.m3secondaryContainer
            inactiveOnColour: Colours.palette.m3onSecondaryContainer
            verticalPadding: Tokens.padding.extraSmall
            onClicked: Vpn.run("secure-core")
        }
    }

    IconTextButton {
        Layout.fillWidth: true
        icon: Vpn.enabled ? "lock_open" : "vpn_lock"
        text: Vpn.enabled ? "Disable tunnel" : "Enable tunnel"
        disabled: root.locked
        inactiveColour: Vpn.enabled ? Colours.palette.m3errorContainer : Colours.palette.m3primary
        inactiveOnColour: Vpn.enabled ? Colours.palette.m3onErrorContainer : Colours.palette.m3onPrimary
        verticalPadding: Tokens.padding.extraSmall
        onClicked: Vpn.run(Vpn.enabled ? "disable" : "enable")
    }

    component Field: StyledText {
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    component Value: StyledText {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        font: Tokens.font.mono.small
    }
}
