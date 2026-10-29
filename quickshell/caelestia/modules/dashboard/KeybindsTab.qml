pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.whichkey

Item {
    id: root

    function entries(keys: var, lead: string): var {
        const digitRuns = {};
        const out = [];
        for (const name in keys) {
            const k = keys[name];
            if (k.key.startsWith("XF86") || k.key === "Print")
                continue;
            const group = k.group ?? "other";
            const sequence = (k.prefix ?? []).map(step => WmState.chord("", step));
            const lone = lead === "" && sequence.length === 0;
            const chordOf = key => [lead, ...sequence, WmState.chord(k.mods, key)].filter(part => part.length > 0).join(" ");
            if (/^[1-9]$/.test(k.key) && /[- ]\d$/.test(k.desc) && k.desc.endsWith(k.key)) {
                const desc = k.desc.slice(0, -1) + "N";
                if (!digitRuns[desc]) {
                    digitRuns[desc] = {
                        chord: chordOf("1..9"),
                        desc: desc,
                        group: group,
                        lone: lone
                    };
                    out.push(digitRuns[desc]);
                }
                continue;
            }
            out.push({
                chord: chordOf(k.key),
                desc: k.desc,
                group: group,
                lone: lone
            });
        }
        return out;
    }

    readonly property var groupOrder: ["focus", "move", "size", "edit", "select", "launch", "shell", "session", "escape"]
    readonly property real maxHeight: Screen.height - 160
    readonly property real maxWidth: Screen.width - 220
    readonly property real fit: Math.min(1, maxHeight / Math.max(1, layout.implicitHeight), maxWidth / Math.max(1, layout.implicitWidth))
    readonly property real rowHeight: 34
    readonly property real keyWidth: 132
    readonly property real descWidth: 176
    readonly property real sectionWidth: keyWidth + descWidth + Tokens.spacing.small + Tokens.padding.large * 2
    readonly property int heightBudget: Math.floor(maxHeight / rowHeight) - 2
    readonly property int widthBudget: Math.max(1, Math.floor(maxWidth / (sectionWidth + Tokens.spacing.medium)))

    readonly property var keymap: WmState.keymap
    readonly property var sections: {
        const keypad = WmState.chord("", "space");
        const all = entries(keymap.root ?? {}, "");
        const maps = keymap.submaps ?? {};
        for (const name of Object.keys(maps).sort()) {
            const map = maps[name];
            const lead = map.keypadOnly ? `${keypad} ${WmState.chord("", map.key)}` : WmState.chord(map.mods, map.key);
            all.push(...entries(map.keys ?? {}, lead));
        }
        all.push(...entries(keymap.keypad ?? {}, keypad));
        const seen = new Set();
        const groups = {};
        for (const row of all) {
            if (seen.has(row.desc))
                continue;
            seen.add(row.desc);
            (groups[row.group] = groups[row.group] ?? []).push(row);
        }
        const rank = group => {
            const i = groupOrder.indexOf(group);
            return i < 0 ? groupOrder.length : i;
        };
        return Object.keys(groups).sort((a, b) => rank(a) - rank(b) || a.localeCompare(b)).map(group => ({
                    title: group,
                    rows: groups[group].sort((a, b) => b.lone - a.lone || a.desc.localeCompare(b.desc))
                }));
    }

    function units(section: var): int {
        return section.rows.length + 2;
    }

    function fill(cap: int): var {
        const columns = [[]];
        let height = 0;
        for (const section of sections) {
            if (height > 0 && height + units(section) > cap) {
                columns.push([]);
                height = 0;
            }
            columns[columns.length - 1].push(section);
            height += units(section);
        }
        return columns;
    }

    function tallest(columns: var): int {
        return Math.max(...columns.map(column => column.reduce((sum, section) => sum + units(section), 0)));
    }

    readonly property var columns: {
        const total = sections.reduce((sum, section) => sum + units(section), 0);
        const largest = Math.max(1, ...sections.map(units));
        let best = null;
        for (let n = 1; n <= widthBudget; n++) {
            let cap = Math.max(largest, Math.ceil(total / n));
            let packed = fill(cap);
            while (packed.length > n)
                packed = fill(++cap);
            best = packed;
            if (tallest(packed) <= heightBudget)
                break;
        }
        return best ?? [];
    }
    implicitWidth: layout.implicitWidth * fit
    implicitHeight: layout.implicitHeight * fit

    ColumnLayout {
        id: layout

        width: implicitWidth
        height: implicitHeight
        scale: root.fit
        transformOrigin: Item.TopLeft
        spacing: Tokens.spacing.medium

        StyledText {
            Layout.leftMargin: Tokens.padding.small
            Layout.maximumWidth: columnsRow.implicitWidth
            text: "boxed keys need no prefix; tap s- for NORMAL (N): the same keys without s-, SPC keypad, ESC or i back"
            font: Tokens.font.label.small
            color: Colours.palette.m3outline
            wrapMode: Text.WordWrap
        }

        RowLayout {
            id: columnsRow

            spacing: Tokens.spacing.medium

            Repeater {
                model: root.columns

                ColumnLayout {
                    id: column

                    required property var modelData

                    Layout.alignment: Qt.AlignTop
                    spacing: Tokens.spacing.medium

                    Repeater {
                        model: column.modelData

                        Section {
                            required property var modelData

                            Layout.fillWidth: true
                            title: modelData.title
                            rows: modelData.rows
                        }
                    }
                }
            }
        }
    }

    component Section: StyledRect {
        id: section

        property string title
        property var rows: []

        implicitWidth: body.implicitWidth + Tokens.padding.large * 2
        implicitHeight: body.implicitHeight + Tokens.padding.large * 2

        radius: Tokens.rounding.large
        color: Colours.tPalette.m3surfaceContainer

        ColumnLayout {
            id: body

            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            spacing: Tokens.spacing.small

            StyledText {
                text: section.title
                font: Tokens.font.title.small
                color: Colours.palette.m3primary
            }

            GridLayout {
                id: grid

                columns: 1
                rowSpacing: Tokens.spacing.extraSmall
                columnSpacing: Tokens.spacing.large

                Repeater {
                    model: section.rows

                    RowLayout {
                        id: row

                        required property var modelData

                        spacing: Tokens.spacing.small

                        Item {
                            Layout.preferredWidth: root.keyWidth
                            implicitHeight: cap.implicitHeight

                            KeyCap {
                                id: cap

                                visible: row.modelData.lone
                                text: row.modelData.chord
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: Tokens.padding.small
                                visible: !row.modelData.lone
                                text: row.modelData.chord
                                font: Tokens.font.mono.small
                                color: Colours.palette.m3onSurface
                            }
                        }

                        StyledText {
                            Layout.preferredWidth: root.descWidth
                            text: row.modelData.desc
                            font: Tokens.font.body.small
                            color: Colours.palette.m3onSurfaceVariant
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }
}
