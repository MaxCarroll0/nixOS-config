pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

Scope {
    id: root

    readonly property var active: Practice.lockdown
    property string feedback: ""

    function unlock(): void {
        if (!password.text || unlocker.running)
            return;
        feedback = "";
        unlocker.command = ["lockdown", "unlock", root.active.profile];
        unlocker.running = true;
    }

    Process {
        id: unlocker

        stdinEnabled: true
        onStarted: {
            write(password.text + "\n");
            stdinEnabled = false;
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim())
                root.feedback = text.trim()
        }
        onExited: code => {
            password.text = "";
            stdinEnabled = true;
            if (code === 0)
                root.feedback = "";
        }
    }

    StyledWindow {
        name: "lockdown"

        screen: Quickshell.screens.find(s => s.name === Hypr.focusedMonitor?.name) ?? Quickshell.screens[0]
        visible: root.active !== null

        anchors.bottom: true
        anchors.left: true
        anchors.right: true
        implicitHeight: panel.implicitHeight
        exclusiveZone: implicitHeight
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

        StyledRect {
            id: panel

            anchors.fill: parent
            implicitHeight: row.implicitHeight + Tokens.padding.large * 2
            color: Colours.tPalette.m3surfaceContainer

            RowLayout {
                id: row

                anchors.fill: parent
                anchors.margins: Tokens.padding.large
                spacing: Tokens.spacing.large

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.extraSmall

                    StyledText {
                        Layout.fillWidth: true
                        text: root.active?.message || root.active?.profile || ""
                        font: Tokens.font.title.small
                        elide: Text.ElideRight
                    }

                    StyledText {
                        Layout.fillWidth: true
                        color: Colours.palette.m3onSurfaceVariant
                        elide: Text.ElideRight
                        text: {
                            const done = `${Practice.completedToday}/${Practice.required} done today`;
                            if (!Practice.active)
                                return `${done} · no interview running`;
                            return `${done} · ${Practice.phase} ${Practice.clock(Practice.left)} left`;
                        }
                    }
                }

                Repeater {
                    model: root.active?.actions ?? []

                    TextButton {
                        required property var modelData

                        type: TextButton.Tonal
                        text: modelData.label
                        onClicked: Quickshell.execDetached(modelData.command)
                    }
                }

                TextButton {
                    visible: Practice.finishApproved
                    type: TextButton.Tonal
                    text: "Finish early"
                    onClicked: Practice.finishEarly()
                }

                StyledTextField {
                    id: password

                    Layout.preferredWidth: 260
                    echoMode: TextInput.Password
                    placeholderText: "password: unlock for today"
                    isError: root.feedback !== ""
                    errorText: root.feedback
                    onAccepted: root.unlock()
                }

                TextButton {
                    type: TextButton.Filled
                    text: "Unlock"
                    enabled: password.text !== "" && !unlocker.running
                    onClicked: root.unlock()
                }
            }
        }
    }
}
