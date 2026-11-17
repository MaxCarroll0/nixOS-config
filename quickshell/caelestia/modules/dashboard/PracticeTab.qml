pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

Item {
    id: root

    property date month: {
        const d = new Date();
        return new Date(d.getFullYear(), d.getMonth(), 1);
    }
    property string selected: Practice.log.today || Practice.dateKey(new Date())
    readonly property var selectedDay: Practice.day(selected)
    readonly property var cells: {
        const first = new Date(month.getFullYear(), month.getMonth(), 1);
        const offset = (first.getDay() + 6) % 7;
        const out = [];
        for (let i = 0; i < 42; i++) {
            const d = new Date(first);
            d.setDate(1 - offset + i);
            out.push({
                key: Practice.dateKey(d),
                date: d.getDate(),
                inMonth: d.getMonth() === month.getMonth(),
                weekend: d.getDay() === 0 || d.getDay() === 6
            });
        }
        return out;
    }
    readonly property var monthStats: {
        let seconds = 0, completed = 0, days = 0;
        for (const c of cells) {
            const d = Practice.day(c.key);
            if (!c.inMonth || !d)
                continue;
            seconds += d.total;
            completed += d.completed;
            if (d.completed >= Practice.required)
                days++;
        }
        return {
            seconds,
            completed,
            days
        };
    }
    readonly property var langTotals: Practice.totals()
    readonly property real maxLang: Math.max(1, ...langTotals.map(t => t.coding + t.learning + t.review))

    implicitWidth: 1000
    implicitHeight: layout.implicitHeight

    Component.onCompleted: Practice.refresh()

    function shiftMonth(delta: int): void {
        month = new Date(month.getFullYear(), month.getMonth() + delta, 1);
    }

    function heat(seconds: real): color {
        if (seconds <= 0)
            return Colours.palette.m3surfaceContainer;
        return Qt.alpha(Colours.palette.m3primary, Math.min(1, 0.2 + seconds / 9000));
    }

    Process {
        id: opener
    }

    RowLayout {
        id: layout

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Tokens.spacing.large

        ColumnLayout {
            Layout.preferredWidth: 540
            Layout.alignment: Qt.AlignTop
            spacing: Tokens.spacing.medium

            RowLayout {
                Layout.fillWidth: true

                IconButton {
                    icon: "chevron_left"
                    type: IconButton.Text
                    onClicked: root.shiftMonth(-1)
                }

                StyledText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.month.toLocaleDateString(Qt.locale(), "MMMM yyyy")
                    font: Tokens.font.body.builders.large.weight(Font.Medium).build()
                }

                IconButton {
                    icon: "chevron_right"
                    type: IconButton.Text
                    onClicked: root.shiftMonth(1)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                Stat {
                    icon: "local_fire_department"
                    value: `${Practice.streak()}`
                    label: "day streak"
                }
                Stat {
                    icon: "schedule"
                    value: Practice.hours(root.monthStats.seconds)
                    label: "this month"
                }
                Stat {
                    icon: "task_alt"
                    value: `${root.monthStats.completed}`
                    label: "interviews"
                }
                Stat {
                    icon: "event_available"
                    value: `${root.monthStats.days}`
                    label: "days unlocked"
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 7
                rowSpacing: 6
                columnSpacing: 6

                Repeater {
                    model: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

                    StyledText {
                        required property string modelData

                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: modelData
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.small
                    }
                }

                Repeater {
                    model: root.cells

                    StyledRect {
                        id: cell

                        required property var modelData
                        readonly property var day: Practice.day(modelData.key)
                        readonly property bool isSelected: modelData.key === root.selected
                        readonly property bool isToday: modelData.key === Practice.log.today

                        Layout.fillWidth: true
                        implicitHeight: 64
                        radius: Tokens.rounding.medium
                        opacity: modelData.inMonth ? 1 : 0.35
                        color: root.heat(day?.total ?? 0)
                        border.width: isSelected ? 2 : isToday ? 1 : 0
                        border.color: isSelected ? Colours.palette.m3onSurface : Colours.palette.m3primary

                        StyledText {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.margins: Tokens.padding.small
                            text: cell.modelData.date
                            color: cell.modelData.weekend ? Colours.palette.m3outline : Colours.palette.m3onSurface
                            font: Tokens.font.body.small
                        }

                        StyledText {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: Tokens.padding.small
                            visible: (cell.day?.total ?? 0) > 0
                            text: Practice.hours(cell.day?.total ?? 0)
                            font: Tokens.font.mono.small
                        }

                        Row {
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.margins: Tokens.padding.small
                            spacing: 3

                            Repeater {
                                model: (cell.day?.sessions ?? []).filter(s => s.complete)

                                Rectangle {
                                    required property var modelData

                                    width: 8
                                    height: 8
                                    radius: 4
                                    color: Practice.langColours[modelData.lang] ?? Colours.palette.m3primary
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selected = cell.modelData.key
                        }
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Tokens.spacing.medium

            StyledText {
                text: new Date(`${root.selected}T12:00:00`).toLocaleDateString(Qt.locale(), "dddd d MMMM")
                font: Tokens.font.body.builders.large.weight(Font.Medium).build()
            }

            StyledText {
                text: root.selectedDay ? `${Practice.hours(root.selectedDay.total)} total · ${root.selectedDay.completed} of ${Practice.required} required interviews` : "No practice logged"
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            Row {
                Layout.fillWidth: true
                visible: (root.selectedDay?.total ?? 0) > 0
                height: 14

                Repeater {
                    model: [
                        {
                            key: "coding",
                            colour: Colours.palette.m3primary
                        },
                        {
                            key: "learning",
                            colour: Colours.palette.m3tertiary
                        },
                        {
                            key: "tutor",
                            colour: Colours.palette.m3tertiaryContainer
                        },
                        {
                            key: "review",
                            colour: Colours.palette.m3secondary
                        }
                    ]

                    Rectangle {
                        required property var modelData

                        width: parent.width * (root.selectedDay?.[modelData.key] ?? 0) / Math.max(1, root.selectedDay?.total ?? 1)
                        height: parent.height
                        color: modelData.colour
                    }
                }
            }

            Flow {
                Layout.fillWidth: true
                visible: (root.selectedDay?.total ?? 0) > 0
                spacing: Tokens.spacing.medium

                Repeater {
                    model: [["coding", "Coding"], ["learning", "Learning (paused)"], ["tutor", "Tutor"], ["review", "Review"]]

                    StyledText {
                        required property var modelData

                        text: `${modelData[1]} ${Practice.hours(root.selectedDay?.[modelData[0]] ?? 0)}`
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.small
                    }
                }
            }

            Repeater {
                model: root.selectedDay?.sessions ?? []

                StyledRect {
                    id: session

                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: sessionRow.implicitHeight + Tokens.padding.medium * 2
                    radius: Tokens.rounding.medium
                    color: hover.containsMouse && modelData.complete ? Colours.palette.m3surfaceContainerHighest : Colours.palette.m3surfaceContainerHigh

                    RowLayout {
                        id: sessionRow

                        anchors.fill: parent
                        anchors.margins: Tokens.padding.medium
                        spacing: Tokens.spacing.medium

                        StyledRect {
                            implicitWidth: langLabel.implicitWidth + Tokens.padding.medium * 2
                            implicitHeight: langLabel.implicitHeight + Tokens.padding.extraSmall * 2
                            radius: Tokens.rounding.full
                            color: Practice.langColours[session.modelData.lang] ?? Colours.palette.m3primary

                            StyledText {
                                id: langLabel

                                anchors.centerIn: parent
                                text: Practice.langNames[session.modelData.lang] ?? session.modelData.lang
                                color: "#111111"
                                font: Tokens.font.body.builders.small.weight(Font.Medium).build()
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            StyledText {
                                Layout.fillWidth: true
                                text: session.modelData.problem
                                elide: Text.ElideRight
                            }

                            StyledText {
                                text: `coding ${Practice.hours(session.modelData.coding)} · learning ${Practice.hours(session.modelData.learning)} · review ${Practice.hours(session.modelData.review)}`
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.body.small
                            }
                        }

                        MaterialIcon {
                            text: session.modelData.live ? "radio_button_checked" : !session.modelData.complete ? "pending" : session.modelData.hidden_tests === "pass" ? "verified" : session.modelData.hidden_tests === "fail" ? "bug_report" : "task_alt"
                            color: session.modelData.hidden_tests === "fail" ? Colours.palette.m3error : Colours.palette.m3primary
                        }
                    }

                    MouseArea {
                        id: hover

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: session.modelData.complete ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (!session.modelData.complete)
                                return;
                            opener.command = ["emacsclient", "-c", "-n", session.modelData.review_md];
                            opener.running = true;
                        }
                    }
                }
            }

            StyledText {
                Layout.topMargin: Tokens.spacing.large
                text: "All time by language"
                font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
            }

            Repeater {
                model: root.langTotals

                RowLayout {
                    id: langRow

                    required property var modelData
                    readonly property real total: modelData.coding + modelData.learning + modelData.review

                    Layout.fillWidth: true
                    spacing: Tokens.spacing.medium

                    StyledText {
                        Layout.preferredWidth: 60
                        text: Practice.langNames[langRow.modelData.lang] ?? langRow.modelData.lang
                        font: Tokens.font.body.small
                    }

                    Item {
                        Layout.fillWidth: true
                        implicitHeight: 10

                        Rectangle {
                            width: parent.width * langRow.total / root.maxLang
                            height: parent.height
                            radius: 5
                            color: Practice.langColours[langRow.modelData.lang] ?? Colours.palette.m3primary
                        }
                    }

                    StyledText {
                        Layout.preferredWidth: 130
                        horizontalAlignment: Text.AlignRight
                        text: `${Practice.hours(langRow.total)} · ${langRow.modelData.completed} done`
                        font: Tokens.font.mono.small
                    }
                }
            }

            StyledText {
                visible: root.langTotals.length === 0
                text: "No interviews yet. They appear here once the first one starts."
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }
        }
    }

    component Stat: StyledRect {
        id: stat

        property string icon
        property string value
        property string label

        Layout.fillWidth: true
        implicitHeight: statCol.implicitHeight + Tokens.padding.medium * 2
        radius: Tokens.rounding.medium
        color: Colours.palette.m3surfaceContainerHigh

        ColumnLayout {
            id: statCol

            anchors.centerIn: parent
            spacing: 0

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Tokens.spacing.extraSmall

                MaterialIcon {
                    text: stat.icon
                    color: Colours.palette.m3primary
                }

                StyledText {
                    text: stat.value
                    font: Tokens.font.mono.builders.large.weight(Font.Medium).build()
                }
            }

            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: stat.label
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }
        }
    }
}
