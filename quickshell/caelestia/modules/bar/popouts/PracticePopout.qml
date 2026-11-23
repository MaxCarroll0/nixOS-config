pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

ColumnLayout {
    id: root

    readonly property var cur: Practice.current
    readonly property var days: {
        const out = [];
        const start = new Date();
        start.setDate(start.getDate() - start.getDay() - 7 * 5);
        for (let i = 0; i < 42; i++) {
            const day = new Date(start);
            day.setDate(start.getDate() + i);
            out.push(Practice.dateKey(day));
        }
        return out;
    }

    width: 340
    spacing: Tokens.spacing.small

    Component.onCompleted: Practice.refresh()

    StyledText {
        Layout.topMargin: Tokens.padding.medium
        text: "Interview practice"
        font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
    }

    StyledText {
        Layout.fillWidth: true
        text: {
            const base = `${Practice.completedToday}/${Practice.required} today, ${Practice.hours(Practice.todaySeconds)} practised`;
            const done = Practice.unreviewed > 0 ? `${base}. Fill in the blank review.org before the next interview` : base;
            if (!Practice.locked)
                return done;
            return `${done}. Locked: ${Practice.lockdown.message || Practice.lockdown.profile}`;
        }
        color: Practice.locked ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
        wrapMode: Text.WordWrap
    }

    StyledRect {
        Layout.fillWidth: true
        Layout.topMargin: Tokens.spacing.small
        visible: Practice.active
        implicitHeight: phaseBox.implicitHeight + Tokens.padding.medium * 2
        radius: Tokens.rounding.medium
        color: Colours.palette.m3surfaceContainerHigh

        ColumnLayout {
            id: phaseBox

            anchors.fill: parent
            anchors.margins: Tokens.padding.medium
            spacing: Tokens.spacing.extraSmall

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    Layout.fillWidth: true
                    text: root.cur ? `${Practice.langNames[root.cur.lang] ?? root.cur.lang} · ${root.cur.problem}` : ""
                    elide: Text.ElideRight
                    font: Tokens.font.body.builders.small.weight(Font.Medium).build()
                }

                StyledText {
                    text: Practice.phase.toUpperCase()
                    color: Practice.phase === "paused" ? Colours.palette.m3tertiary : Practice.reviewing ? Colours.palette.m3secondary : Colours.palette.m3primary
                    font: Tokens.font.mono.small
                }
            }

            StyledText {
                text: Practice.clock(Practice.left)
                color: Practice.phase === "coding" && Practice.codingLeft < 300 ? Colours.palette.m3error : Colours.palette.m3onSurface
                font: Tokens.font.mono.builders.large.weight(Font.Medium).build()
            }

            StyledProgressBar {
                Layout.fillWidth: true
                visible: !Practice.reviewing
                value: root.cur && root.cur.coding_budget > 0 ? 1 - Practice.left / root.cur.coding_budget : 0
            }

            StyledText {
                Layout.fillWidth: true
                text: Practice.phase === "review" ? "Submission frozen; reviewing with the interviewer, no time limit. End interview when you are done." : Practice.phase === "paused" ? "Clock stopped. The tutor window is up; SUPER+F5 resumes." : `Paused ${Practice.hours(root.cur?.pause_seconds ?? 0)} so far. ${Practice.finishApproved ? "Finishing early is allowed." : "Finish early: pass interview submit-tests, or ask the interviewer."}`
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        visible: Practice.phase === "coding" || Practice.phase === "paused"
        spacing: Tokens.spacing.small

        IconTextButton {
            Layout.fillWidth: true
            icon: Practice.phase === "paused" ? "play_arrow" : "pause"
            text: Practice.phase === "paused" ? "Resume" : "Pause"
            inactiveColour: Colours.palette.m3primaryContainer
            inactiveOnColour: Colours.palette.m3onPrimaryContainer
            verticalPadding: Tokens.padding.extraSmall
            onClicked: Practice.toggle()
        }

        IconTextButton {
            Layout.fillWidth: true
            visible: Practice.finishApproved
            icon: "flag"
            text: "Finish early"
            inactiveColour: Colours.palette.m3secondaryContainer
            inactiveOnColour: Colours.palette.m3onSecondaryContainer
            verticalPadding: Tokens.padding.extraSmall
            onClicked: Practice.finishEarly()
        }
    }

    IconTextButton {
        Layout.fillWidth: true
        visible: Practice.reviewing
        icon: "done_all"
        text: "End interview"
        inactiveColour: Colours.palette.m3secondaryContainer
        inactiveOnColour: Colours.palette.m3onSecondaryContainer
        verticalPadding: Tokens.padding.extraSmall
        onClicked: Practice.endInterview()
    }

    IconTextButton {
        Layout.fillWidth: true
        visible: !Practice.active
        icon: "play_arrow"
        text: "Start next interview"
        inactiveColour: Colours.palette.m3primaryContainer
        inactiveOnColour: Colours.palette.m3onPrimaryContainer
        verticalPadding: Tokens.padding.extraSmall
        onClicked: Practice.startNext()
    }

    IconTextButton {
        Layout.fillWidth: true
        visible: Practice.active
        icon: Practice.testing ? "hourglass_top" : "play_circle"
        text: Practice.testing ? "Running tests" : "Run visible tests"
        disabled: Practice.testing
        inactiveColour: Colours.palette.m3tertiaryContainer
        inactiveOnColour: Colours.palette.m3onTertiaryContainer
        verticalPadding: Tokens.padding.extraSmall
        onClicked: Practice.runTests()
    }

    StyledRect {
        Layout.fillWidth: true
        visible: Practice.testOutput !== "" && Practice.active
        implicitHeight: Math.min(220, output.implicitHeight + Tokens.padding.small * 2)
        radius: Tokens.rounding.small
        color: Colours.palette.m3surfaceContainerLow
        border.width: 1
        border.color: Practice.testExit === 0 ? Colours.palette.m3primary : Colours.palette.m3error
        clip: true

        Flickable {
            anchors.fill: parent
            anchors.margins: Tokens.padding.small
            contentHeight: output.implicitHeight
            contentY: Math.max(0, contentHeight - height)

            StyledText {
                id: output

                width: parent.width
                text: Practice.testOutput.split("\n").slice(-60).join("\n")
                wrapMode: Text.WrapAnywhere
                font: Tokens.font.mono.small
            }
        }
    }

    Repeater {
        model: (Practice.today?.sessions ?? []).filter(s => s.complete)

        ColumnLayout {
            id: todaySession

            required property var modelData

            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.small
            spacing: Tokens.spacing.extraSmall

            StyledText {
                Layout.fillWidth: true
                text: `${Practice.langNames[todaySession.modelData.lang] ?? todaySession.modelData.lang} · ${todaySession.modelData.problem}`
                elide: Text.ElideRight
                font: Tokens.font.body.small
            }

            PracticeVersions {
                Layout.fillWidth: true
                session: todaySession.modelData
            }

            PracticeCaseBars {
                Layout.fillWidth: true
                session: todaySession.modelData
            }

            PracticeSessionActions {
                Layout.fillWidth: true
                session: todaySession.modelData
            }
        }
    }

    StyledText {
        Layout.fillWidth: true
        visible: Practice.openError !== ""
        text: Practice.openError
        color: Colours.palette.m3error
        font: Tokens.font.body.small
        wrapMode: Text.WordWrap
    }

    StyledText {
        Layout.topMargin: Tokens.spacing.medium
        text: `Last six weeks · streak ${Practice.streak()} days`
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 7
        rowSpacing: 4
        columnSpacing: 4

        Repeater {
            model: root.days

            StyledRect {
                required property string modelData
                readonly property var day: Practice.day(modelData)
                readonly property real minutes: (day?.total ?? 0) / 60

                Layout.fillWidth: true
                implicitHeight: 22
                radius: Tokens.rounding.small
                color: minutes <= 0 ? Colours.palette.m3surfaceContainerHigh : Qt.alpha(Colours.palette.m3primary, Math.min(1, 0.25 + minutes / 160))
                border.width: modelData === Practice.log.today ? 2 : 0
                border.color: Colours.palette.m3onSurface

                StyledText {
                    anchors.centerIn: parent
                    visible: (parent.day?.completed ?? 0) > 0
                    text: parent.day?.completed ?? ""
                    color: Colours.palette.m3onPrimary
                    font: Tokens.font.mono.small
                }
            }
        }
    }

    StyledText {
        Layout.bottomMargin: Tokens.padding.small
        text: "Full calendar: dashboard, Practice tab"
        color: Colours.palette.m3outline
        font: Tokens.font.body.small
    }
}
