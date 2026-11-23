pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.components.controls
import qs.services
import qs.modules.nexus.common

Item {
    id: root

    signal done

    property var draft: null
    readonly property var weekdays: Practice.settingsDoc?.weekdays ?? ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    readonly property var difficulties: Practice.settingsDoc?.difficulties ?? ["easy", "easy-medium", "medium", "medium-hard", "hard"]
    readonly property int enabledTracks: (draft?.tracks ?? []).filter(t => t.enabled).length
    readonly property bool dirty: !!draft && JSON.stringify(draft) !== JSON.stringify(Practice.settings)
    readonly property real maxFormHeight: Screen.height - 260

    implicitWidth: 1040
    implicitHeight: Math.min(form.implicitHeight, maxFormHeight) + footer.implicitHeight + Tokens.spacing.large

    function copy(value: var): var {
        return JSON.parse(JSON.stringify(value));
    }

    function revert(): void {
        draft = Practice.settings ? copy(Practice.settings) : null;
    }

    function set(key: string, value: var): void {
        const next = copy(draft);
        next[key] = value;
        draft = next;
    }

    function setTrack(index: int, key: string, value: var): void {
        const tracks = copy(draft.tracks);
        tracks[index][key] = value;
        set("tracks", tracks);
    }

    function setTrackLength(index: int, coding: var): void {
        const tracks = copy(draft.tracks);
        tracks[index].coding_minutes = coding;
        set("tracks", tracks);
    }

    function toggleIn(list: var, item: var): var {
        return list.includes(item) ? list.filter(x => x !== item) : [...list, item];
    }

    function addTrack(): void {
        const names = draft.tracks.map(t => t.name);
        let n = draft.tracks.length + 1;
        while (names.includes(`track${n}`))
            n++;
        set("tracks", [...copy(draft.tracks), {
                name: `track${n}`,
                langs: [],
                context: "",
                difficulty: "easy-medium",
                enabled: true,
                coding_minutes: null,
                syntax_notes: false
            }]);
    }

    function removeTrack(index: int): void {
        const tracks = copy(draft.tracks);
        tracks.splice(index, 1);
        set("tracks", tracks);
    }

    function langName(id: string): string {
        return Practice.langNames[id] ?? id;
    }

    Component.onCompleted: {
        Practice.refresh();
        revert();
    }

    Connections {
        target: Practice

        function onSettingsDocChanged(): void {
            if (!root.dirty || !root.draft)
                root.revert();
        }

        function onSettingsSavedChanged(): void {
            password.text = "";
            root.revert();
        }
    }

    StyledText {
        visible: !root.draft
        text: "Loading settings…"
        color: Colours.palette.m3onSurfaceVariant
    }

    StyledFlickable {
        id: flick

        visible: !!root.draft
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Math.min(form.implicitHeight, root.maxFormHeight)
        contentHeight: form.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        StyledScrollBar.vertical: StyledScrollBar {
            flickable: flick
        }

        RowLayout {
            id: form

            width: flick.width - Tokens.padding.large
            spacing: Tokens.spacing.large * 2

            ColumnLayout {
                Layout.preferredWidth: 430
                Layout.maximumWidth: 430
                Layout.alignment: Qt.AlignTop
                spacing: Tokens.spacing.extraSmall / 2

                SectionHeader {
                    first: true
                    text: "Schedule"
                }

                ConnectedRect {
                    first: true
                    Layout.fillWidth: true
                    implicitHeight: daysCol.implicitHeight + Tokens.padding.medium * 2

                    ColumnLayout {
                        id: daysCol

                        anchors.fill: parent
                        anchors.margins: Tokens.padding.medium
                        anchors.leftMargin: Tokens.padding.largeIncreased
                        anchors.rightMargin: Tokens.padding.largeIncreased
                        spacing: Tokens.spacing.small

                        RowLayout {
                            Layout.fillWidth: true

                            StyledText {
                                Layout.fillWidth: true
                                text: "Interview days"
                                font: Tokens.font.body.small
                            }

                            StyledText {
                                text: {
                                    const n = root.draft?.days?.length ?? 0;
                                    return n ? `${n} a week` : "none: interviews off";
                                }
                                color: (root.draft?.days?.length ?? 0) ? Colours.palette.m3outline : Colours.palette.m3error
                                font: Tokens.font.label.small
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.spacing.extraSmall

                            Repeater {
                                model: root.weekdays

                                DayToggle {
                                    required property string modelData

                                    Layout.fillWidth: true
                                    text: modelData
                                    selected: (root.draft?.days ?? []).includes(modelData)
                                    onClicked: root.set("days", root.weekdays.filter(d => d === modelData ? !selected : root.draft.days.includes(d)))
                                }
                            }
                        }
                    }
                }

                TextFieldRow {
                    label: "Starts at"
                    subtext: "When lockdown and auto start begin"
                    smallField: true
                    placeholderText: "HH:MM"
                    value: root.draft?.start ?? ""
                    validate: /^([01]\d|2[0-3]):[0-5]\d$/
                    errorText: "Use HH:MM, such as 05:00"
                    field.isError: !field.valid
                    onValueEdited: v => root.set("start", v)
                }

                TextFieldRow {
                    label: "First day"
                    subtext: "Empty means already in force"
                    smallField: true
                    field.Layout.preferredWidth: 140
                    placeholderText: "YYYY-MM-DD"
                    value: root.draft?.from ?? ""
                    validate: /^\d{4}-\d{2}-\d{2}$/
                    errorText: "Use YYYY-MM-DD, or leave empty"
                    field.isError: !field.valid
                    onValueEdited: v => root.set("from", v)
                }

                ToggleRow {
                    text: "Start automatically"
                    subtext: "When you are at the keyboard"
                    checked: root.draft?.auto_start ?? true
                    onToggled: root.set("auto_start", checked)
                }

                ToggleRow {
                    last: true
                    text: "Lockdown"
                    subtext: "Apps and root blocked until done"
                    checked: root.draft?.lockdown ?? true
                    onToggled: root.set("lockdown", checked)
                }

                SectionHeader {
                    text: "Timing"
                }

                StepperRow {
                    first: true
                    label: "Questions required"
                    subtext: `Of ${root.enabledTracks} offered a day`
                    from: 1
                    to: Math.max(1, root.enabledTracks)
                    value: root.draft?.required_per_day ?? 2
                    onMoved: v => root.set("required_per_day", Math.round(v))
                }

                StepperRow {
                    label: "Coding"
                    subtext: "Minutes, pauses excluded"
                    from: 5
                    to: 240
                    stepSize: 5
                    value: root.draft?.coding_minutes ?? 45
                    onMoved: v => root.set("coding_minutes", Math.round(v))
                }

                StepperRow {
                    label: "Break"
                    subtext: "Minutes between interviews"
                    from: 0
                    to: 240
                    stepSize: 5
                    value: root.draft?.break_minutes ?? 5
                    onMoved: v => root.set("break_minutes", Math.round(v))
                }

                StepperRow {
                    last: true
                    label: "Snooze"
                    subtext: "Minutes after pressing Later"
                    from: 1
                    to: 240
                    stepSize: 5
                    value: root.draft?.snooze_minutes ?? 10
                    onMoved: v => root.set("snooze_minutes", Math.round(v))
                }

                SectionHeader {
                    text: "Question style"
                }

                ConnectedRect {
                    first: true
                    Layout.fillWidth: true
                    implicitHeight: styleCol.implicitHeight + Tokens.padding.medium * 2

                    ColumnLayout {
                        id: styleCol

                        anchors.fill: parent
                        anchors.margins: Tokens.padding.medium
                        anchors.leftMargin: Tokens.padding.largeIncreased
                        anchors.rightMargin: Tokens.padding.largeIncreased
                        spacing: Tokens.spacing.small

                        RowLabel {
                            text: "Style and theme"
                            subtext: "Plain language for the agent that writes problems; each track's context adds to it"
                        }

                        Area {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 104
                            placeholder: "e.g. LeetCode-style classics, or practical parsing and data wrangling"
                            text: root.draft?.context ?? ""
                            onEdited: value => root.set("context", value)
                        }
                    }
                }

                ConnectedRect {
                    last: true
                    Layout.fillWidth: true
                    implicitHeight: rulesCol.implicitHeight + Tokens.padding.medium * 2

                    ColumnLayout {
                        id: rulesCol

                        anchors.fill: parent
                        anchors.margins: Tokens.padding.medium
                        anchors.leftMargin: Tokens.padding.largeIncreased
                        anchors.rightMargin: Tokens.padding.largeIncreased
                        spacing: Tokens.spacing.small

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.spacing.small

                            MaterialIcon {
                                text: "lock"
                                color: Colours.palette.m3outline
                            }

                            RowLabel {
                                text: "Always applies"
                                subtext: "Fixed rules every problem meets, whatever the style"
                            }
                        }

                        Repeater {
                            model: Practice.settingsDoc?.rules ?? []

                            RowLayout {
                                id: rule

                                required property string modelData

                                Layout.fillWidth: true
                                spacing: Tokens.spacing.small

                                MaterialIcon {
                                    Layout.alignment: Qt.AlignTop
                                    text: "check"
                                    color: Colours.palette.m3primary
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: rule.modelData
                                    wrapMode: Text.Wrap
                                    color: Colours.palette.m3onSurfaceVariant
                                    font: Tokens.font.label.medium
                                }
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: Tokens.spacing.extraSmall / 2

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: Tokens.spacing.extraSmall

                    SectionHeader {
                        first: true
                        Layout.bottomMargin: 0
                        text: `Tracks · ${root.enabledTracks} of ${root.draft?.tracks.length ?? 0} enabled, one question each per interview day`
                    }

                    IconTextButton {
                        icon: "add"
                        text: "Add track"
                        type: IconTextButton.Tonal
                        disabled: (root.draft?.tracks.length ?? 0) >= 12
                        onClicked: root.addTrack()
                    }
                }

                Repeater {
                    model: root.draft?.tracks.length ?? 0

                    ColumnLayout {
                        id: card

                        required property int index
                        readonly property var track: root.draft.tracks[index] ?? ({})
                        readonly property var langs: track.langs ?? []
                        readonly property color accent: langs.length ? (Practice.langColours[langs[0]] ?? Colours.palette.m3primary) : Colours.palette.m3outline
                        readonly property bool customLength: track.coding_minutes != null
                        property bool pickingLangs: langs.length === 0

                        Layout.fillWidth: true
                        Layout.topMargin: index > 0 ? Tokens.spacing.large : 0
                        spacing: Tokens.spacing.extraSmall / 2
                        opacity: track.enabled ? 1 : 0.55

                        ConnectedRect {
                            first: true
                            Layout.fillWidth: true
                            implicitHeight: head.implicitHeight + Tokens.padding.medium * 2

                            RowLayout {
                                id: head

                                anchors.fill: parent
                                anchors.margins: Tokens.padding.medium
                                anchors.leftMargin: Tokens.padding.largeIncreased
                                spacing: Tokens.spacing.medium

                                StyledRect {
                                    implicitWidth: 6
                                    Layout.fillHeight: true
                                    radius: Tokens.rounding.full
                                    color: card.accent
                                }

                                StyledTextField {
                                    Layout.preferredWidth: 200
                                    verticalPadding: Tokens.padding.small
                                    placeholderText: "Track name"
                                    text: card.track.name ?? ""
                                    validate: /^[a-z][a-z0-9-]{0,23}$/
                                    emptyIsValid: false
                                    isError: !valid
                                    onTextEdited: root.setTrack(card.index, "name", text)
                                }

                                Item {
                                    Layout.fillWidth: true
                                }

                                StyledSwitch {
                                    checked: card.track.enabled ?? true
                                    onToggled: root.setTrack(card.index, "enabled", checked)
                                }

                                IconButton {
                                    icon: "delete"
                                    type: IconButton.Text
                                    disabled: root.draft.tracks.length <= 1
                                    onClicked: root.removeTrack(card.index)
                                }
                            }
                        }

                        ConnectedRect {
                            Layout.fillWidth: true
                            implicitHeight: langCol.implicitHeight + Tokens.padding.medium * 2

                            ColumnLayout {
                                id: langCol

                                anchors.fill: parent
                                anchors.margins: Tokens.padding.medium
                                anchors.leftMargin: Tokens.padding.largeIncreased
                                anchors.rightMargin: Tokens.padding.largeIncreased
                                spacing: Tokens.spacing.small

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tokens.spacing.medium

                                    RowLabel {
                                        text: "Languages"
                                        subtext: card.langs.length > 1 ? "Rotates in this order, one per interview day" : "Pick one, or several to rotate"
                                    }

                                    Row {
                                        visible: !card.pickingLangs
                                        spacing: Tokens.spacing.extraSmall

                                        Repeater {
                                            model: card.langs

                                            Chip {
                                                required property string modelData

                                                text: root.langName(modelData)
                                                accent: Practice.langColours[modelData] ?? ""
                                                selected: true
                                                onClicked: card.pickingLangs = true
                                            }
                                        }
                                    }

                                    IconButton {
                                        icon: card.pickingLangs ? "expand_less" : "edit"
                                        type: IconButton.Text
                                        onClicked: card.pickingLangs = !card.pickingLangs
                                    }
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    visible: card.pickingLangs
                                    spacing: Tokens.spacing.extraSmall

                                    Repeater {
                                        model: Practice.languages

                                        Chip {
                                            required property var modelData

                                            text: {
                                                const at = card.langs.indexOf(modelData.id);
                                                return at >= 0 && card.langs.length > 1 ? `${at + 1}  ${modelData.name}` : modelData.name;
                                            }
                                            accent: modelData.colour
                                            selected: card.langs.includes(modelData.id)
                                            onClicked: root.setTrack(card.index, "langs", root.toggleIn(card.langs, modelData.id))
                                        }
                                    }
                                }
                            }
                        }

                        ConnectedRect {
                            Layout.fillWidth: true
                            implicitHeight: diffRow.implicitHeight + Tokens.padding.medium * 2

                            RowLayout {
                                id: diffRow

                                anchors.fill: parent
                                anchors.margins: Tokens.padding.medium
                                anchors.leftMargin: Tokens.padding.largeIncreased
                                anchors.rightMargin: Tokens.padding.largeIncreased
                                spacing: Tokens.spacing.medium

                                RowLabel {
                                    text: "Difficulty"
                                }

                                Segmented {
                                    options: root.difficulties
                                    current: card.track.difficulty ?? "easy-medium"
                                    onPicked: value => root.setTrack(card.index, "difficulty", value)
                                }
                            }
                        }

                        ConnectedRect {
                            Layout.fillWidth: true
                            implicitHeight: notesRow.implicitHeight + Tokens.padding.medium * 2

                            RowLayout {
                                id: notesRow

                                anchors.fill: parent
                                anchors.margins: Tokens.padding.medium
                                anchors.leftMargin: Tokens.padding.largeIncreased
                                anchors.rightMargin: Tokens.padding.largeIncreased
                                spacing: Tokens.spacing.medium

                                RowLabel {
                                    text: "Syntax notes"
                                    subtext: "Prompts introduce new syntax in a line or two, never the approach"
                                }

                                Item {
                                    Layout.fillWidth: true
                                }

                                StyledSwitch {
                                    checked: card.track.syntax_notes ?? false
                                    onToggled: root.setTrack(card.index, "syntax_notes", checked)
                                }
                            }
                        }

                        ConnectedRect {
                            Layout.fillWidth: true
                            implicitHeight: lenRow.implicitHeight + Tokens.padding.medium * 2

                            RowLayout {
                                id: lenRow

                                anchors.fill: parent
                                anchors.margins: Tokens.padding.medium
                                anchors.leftMargin: Tokens.padding.largeIncreased
                                anchors.rightMargin: Tokens.padding.largeIncreased
                                spacing: Tokens.spacing.medium

                                RowLabel {
                                    text: "Length"
                                    subtext: card.customLength ? "Minutes for this track" : `Default: ${root.draft?.coding_minutes ?? 45} min coding`
                                }

                                StyledText {
                                    visible: card.customLength
                                    text: "coding"
                                    color: Colours.palette.m3outline
                                    font: Tokens.font.label.small
                                }

                                StyledSpinBox {
                                    visible: card.customLength
                                    from: 5
                                    to: 240
                                    stepSize: 5
                                    value: card.track.coding_minutes ?? root.draft?.coding_minutes ?? 45
                                    cLayer: 2
                                    onValueModified: root.setTrackLength(card.index, Math.round(value))
                                }

                                Segmented {
                                    options: ["default", "custom"]
                                    current: card.customLength ? "custom" : "default"
                                    onPicked: value => value === "custom" ? root.setTrackLength(card.index, root.draft.coding_minutes) : root.setTrackLength(card.index, null)
                                }
                            }
                        }

                        ConnectedRect {
                            last: true
                            Layout.fillWidth: true
                            implicitHeight: ctxCol.implicitHeight + Tokens.padding.medium * 2

                            ColumnLayout {
                                id: ctxCol

                                anchors.fill: parent
                                anchors.margins: Tokens.padding.medium
                                anchors.leftMargin: Tokens.padding.largeIncreased
                                anchors.rightMargin: Tokens.padding.largeIncreased
                                spacing: Tokens.spacing.small

                                RowLabel {
                                    text: "Context"
                                    subtext: "Added to the question style for this track only"
                                }

                                Area {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 64
                                    placeholder: "e.g. graphs only, or teach the language as we go"
                                    text: card.track.context ?? ""
                                    onEdited: value => root.setTrack(card.index, "context", value)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    StyledRect {
        id: footer

        visible: !!root.draft
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        implicitHeight: footerRow.implicitHeight + Tokens.padding.medium * 2
        radius: Tokens.rounding.extraLarge
        color: Colours.tPalette.m3surfaceContainer

        RowLayout {
            id: footerRow

            anchors.fill: parent
            anchors.margins: Tokens.padding.medium
            anchors.leftMargin: Tokens.padding.largeIncreased
            spacing: Tokens.spacing.medium

            MaterialIcon {
                text: Practice.settingsFailed ? "error" : root.dirty ? "edit_note" : Practice.settingsDoc?.customised ? "tune" : "check_circle"
                color: Practice.settingsFailed ? Colours.palette.m3error : root.dirty ? Colours.palette.m3primary : Colours.palette.m3outline
            }

            StyledText {
                Layout.fillWidth: true
                text: Practice.settingsMessage || (root.dirty ? "Unsaved changes" : Practice.settingsDoc?.customised ? "Customised settings in use" : "Using the nix defaults")
                color: Practice.settingsFailed ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                elide: Text.ElideRight
                font: Tokens.font.body.small
            }

            TextButton {
                text: "Defaults"
                type: TextButton.Text
                onClicked: root.draft = root.copy(Practice.settingsDoc.defaults)
            }

            TextButton {
                text: "Revert"
                type: TextButton.Text
                disabled: !root.dirty
                onClicked: root.revert()
            }

            StyledTextField {
                id: password

                Layout.preferredWidth: 230
                verticalPadding: Tokens.padding.small
                placeholderText: "Lockdown password"
                leadingIcon: "key"
                echoMode: TextInput.Password
                onAccepted: save.clicked()
            }

            TextButton {
                id: save

                text: Practice.settingsBusy ? "Saving…" : "Save"
                disabled: !root.dirty || !password.text || Practice.settingsBusy
                onClicked: {
                    if (!disabled)
                        Practice.saveSettings(password.text, root.draft);
                }
            }

            TextButton {
                text: "Close"
                type: TextButton.Tonal
                onClicked: root.done()
            }
        }
    }

    component RowLabel: ColumnLayout {
        id: rowLabel

        property string text
        property string subtext

        Layout.fillWidth: true
        spacing: 0

        StyledText {
            Layout.fillWidth: true
            text: rowLabel.text
            font: Tokens.font.body.small
            elide: Text.ElideRight
        }

        StyledText {
            Layout.fillWidth: true
            visible: !!rowLabel.subtext
            text: rowLabel.subtext
            color: Colours.palette.m3outline
            font: Tokens.font.label.small
            wrapMode: Text.Wrap
        }
    }

    component DayToggle: StyledRect {
        id: day

        property string text
        property bool selected
        signal clicked

        implicitHeight: 34
        radius: Tokens.rounding.full
        color: selected ? Colours.palette.m3primary : dayMouse.containsMouse ? Colours.palette.m3surfaceContainerHighest : Colours.palette.m3surfaceContainerHigh

        StyledText {
            anchors.centerIn: parent
            text: day.text
            color: day.selected ? Colours.palette.m3onPrimary : Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.medium
        }

        MouseArea {
            id: dayMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: day.clicked()
        }
    }

    component Segmented: StyledRect {
        id: seg

        property var options: []
        property string current
        signal picked(string value)

        implicitWidth: segRow.implicitWidth + 4
        implicitHeight: segRow.implicitHeight + 4
        radius: Tokens.rounding.full
        color: Colours.palette.m3surfaceContainerHigh

        Row {
            id: segRow

            anchors.centerIn: parent
            spacing: 2

            Repeater {
                model: seg.options

                StyledRect {
                    id: opt

                    required property string modelData
                    readonly property bool on: seg.current === modelData

                    implicitWidth: optText.implicitWidth + Tokens.padding.large * 2
                    implicitHeight: optText.implicitHeight + Tokens.padding.small * 2
                    radius: Tokens.rounding.full
                    color: on ? Colours.palette.m3secondaryContainer : optMouse.containsMouse ? Colours.palette.m3surfaceContainerHighest : "transparent"

                    StyledText {
                        id: optText

                        anchors.centerIn: parent
                        text: opt.modelData
                        color: opt.on ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.medium
                    }

                    MouseArea {
                        id: optMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: seg.picked(opt.modelData)
                    }
                }
            }
        }
    }

    component Chip: StyledRect {
        id: chip

        property string text
        property bool selected
        property string accent
        signal clicked

        implicitWidth: chipText.implicitWidth + Tokens.padding.medium * 2
        implicitHeight: chipText.implicitHeight + Tokens.padding.extraSmall * 2
        radius: Tokens.rounding.full
        color: selected ? (accent || Colours.palette.m3primary) : chipMouse.containsMouse ? Colours.palette.m3surfaceContainerHighest : "transparent"
        border.width: selected ? 0 : 1
        border.color: Colours.palette.m3outlineVariant

        StyledText {
            id: chipText

            anchors.centerIn: parent
            text: chip.text
            color: chip.selected ? (chip.accent ? "#111111" : Colours.palette.m3onPrimary) : Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.medium
        }

        MouseArea {
            id: chipMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    component Area: StyledRect {
        id: area

        property alias text: edit.text
        property string placeholder
        signal edited(string value)

        radius: Tokens.rounding.medium
        color: Colours.palette.m3surfaceContainerHigh
        border.width: edit.activeFocus ? 2 : 0
        border.color: Colours.palette.m3primary

        StyledFlickable {
            id: areaFlick

            anchors.fill: parent
            anchors.margins: Tokens.padding.medium
            contentHeight: edit.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            TextEdit {
                id: edit

                width: areaFlick.width
                wrapMode: TextEdit.Wrap
                color: Colours.palette.m3onSurface
                selectionColor: Qt.alpha(Colours.palette.m3primary, 0.4)
                selectByMouse: true
                font: Tokens.font.body.small
                onTextChanged: {
                    if (activeFocus)
                        area.edited(text);
                }
                onCursorRectangleChanged: {
                    if (cursorRectangle.y + cursorRectangle.height > areaFlick.contentY + areaFlick.height)
                        areaFlick.contentY = cursorRectangle.y + cursorRectangle.height - areaFlick.height;
                    else if (cursorRectangle.y < areaFlick.contentY)
                        areaFlick.contentY = cursorRectangle.y;
                }
            }
        }

        StyledText {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Tokens.padding.medium
            visible: !edit.text && !edit.activeFocus
            text: area.placeholder
            color: Colours.palette.m3outline
            wrapMode: Text.Wrap
            font: Tokens.font.body.small
        }
    }
}
