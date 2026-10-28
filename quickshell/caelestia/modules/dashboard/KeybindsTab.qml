pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.whichkey

Item {
    id: root

    function entries(keys: var): var {
        const digitRuns = {};
        const out = [];
        for (const name in keys) {
            const k = keys[name];
            if (k.key.startsWith("XF86") || k.key === "Print")
                continue;
            if (/^[1-9]$/.test(k.key) && k.desc.endsWith(" " + k.key)) {
                const desc = k.desc.slice(0, -1) + "N";
                const id = k.mods + "|" + desc;
                if (!digitRuns[id]) {
                    digitRuns[id] = {
                        chord: WmState.chord(k.mods, "1..9"),
                        desc: desc
                    };
                    out.push(digitRuns[id]);
                }
                continue;
            }
            out.push({
                chord: WmState.chord(k.mods, k.key),
                desc: k.desc
            });
        }
        return out.sort((a, b) => a.desc.localeCompare(b.desc));
    }

    readonly property var keymap: WmState.keymap
    readonly property var globalEntries: entries(keymap.root ?? {})
    readonly property var submapColumns: {
        const maps = keymap.submaps ?? {};
        const sections = Object.keys(maps).map(name => ({
                    title: maps[name].desc,
                    prefix: `${WmState.chord(maps[name].mods, maps[name].key)} · ${maps[name].key}`,
                    rows: entries(maps[name].keys ?? {})
                }));
        sections.push({
            title: "keypad",
            prefix: "N SPC",
            rows: entries(keymap.keypad ?? {})
        });
        sections.sort((a, b) => b.rows.length - a.rows.length);
        const columns = [[], []];
        const heights = [0, 0];
        for (const section of sections) {
            const shorter = heights[0] <= heights[1] ? 0 : 1;
            columns[shorter].push(section);
            heights[shorter] += section.rows.length + 2;
        }
        return columns;
    }

    implicitWidth: layout.implicitWidth
    implicitHeight: layout.implicitHeight

    RowLayout {
        id: layout

        anchors.fill: parent
        spacing: Tokens.spacing.medium

        Section {
            Layout.alignment: Qt.AlignTop
            title: "Global"
            note: "tap s- for NORMAL (N): the same keys without s-, w s g m p prefixes, SPC keypad, ESC or i back"
            columns: 2
            rows: root.globalEntries
        }

        Repeater {
            model: root.submapColumns

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
                        prefix: modelData.prefix
                        rows: modelData.rows
                    }
                }
            }
        }
    }

    component Section: StyledRect {
        id: section

        property string title
        property string prefix
        property string note
        property var rows: []
        property int columns: 1

        implicitWidth: body.implicitWidth + Tokens.padding.large * 2
        implicitHeight: body.implicitHeight + Tokens.padding.large * 2

        radius: Tokens.rounding.large
        color: Colours.tPalette.m3surfaceContainer

        ColumnLayout {
            id: body

            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            spacing: Tokens.spacing.small

            RowLayout {
                spacing: Tokens.spacing.small

                StyledText {
                    Layout.rightMargin: Tokens.spacing.small
                    text: section.title
                    font: Tokens.font.title.small
                    color: Colours.palette.m3primary
                }

                KeyCap {
                    visible: section.prefix.length > 0
                    text: section.prefix
                    prominent: true
                }
            }

            StyledText {
                Layout.maximumWidth: grid.implicitWidth
                visible: section.note.length > 0
                text: section.note
                font: Tokens.font.label.small
                color: Colours.palette.m3outline
                wrapMode: Text.WordWrap
            }

            GridLayout {
                id: grid

                columns: section.columns
                rowSpacing: Tokens.spacing.extraSmall
                columnSpacing: Tokens.spacing.large

                Repeater {
                    model: section.rows

                    RowLayout {
                        id: row

                        required property var modelData

                        spacing: Tokens.spacing.small

                        Item {
                            Layout.preferredWidth: 128
                            implicitHeight: cap.implicitHeight

                            KeyCap {
                                id: cap

                                text: row.modelData.chord
                            }
                        }

                        StyledText {
                            Layout.preferredWidth: 250
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
