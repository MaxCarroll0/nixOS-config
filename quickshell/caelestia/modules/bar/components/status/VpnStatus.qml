import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property color colour

    implicitWidth: Vpn.present ? icon.implicitWidth : 0
    implicitHeight: Vpn.present ? icon.implicitHeight : 0
    visible: Vpn.present

    MaterialIcon {
        id: icon

        anchors.centerIn: parent
        animate: true
        text: Vpn.busy ? "sync" : !Vpn.enabled ? "lock_open" : Vpn.up ? "vpn_lock" : "vpn_key_off"
        color: Vpn.busy || (Vpn.enabled && Vpn.up) ? root.colour : Colours.palette.m3error

        RotationAnimator on rotation {
            running: Vpn.busy !== ""
            from: 0
            to: -360
            duration: 1200
            loops: Animation.Infinite
            onRunningChanged: if (!running)
                icon.rotation = 0
        }
    }
}
