pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    property var keymap: ({})

    readonly property var keyNames: ({
            comma: ",",
            period: ".",
            slash: "/",
            equal: "=",
            minus: "-",
            space: "SPC",
            Return: "RET",
            Tab: "TAB",
            Delete: "<delete>",
            escape: "ESC"
        })
    readonly property var modifierOrder: [["CTRL", "C-"], ["ALT", "M-"], ["SUPER", "s-"]]

    function emacsChord(mods: string, key: string): string {
        const held = mods.split(" ").filter(m => m.length > 0);
        const shifted = held.includes("SHIFT");
        const letter = /^[a-z]$/.test(key);
        const prefix = modifierOrder.filter(([name]) => held.includes(name)).map(([, emacs]) => emacs).join("");
        const name = keyNames[key] ?? key;
        if (shifted && letter)
            return prefix + name.toUpperCase();
        return prefix + (shifted ? "S-" : "") + name;
    }

    function entries(keys: var): var {
        const digitRuns = {};
        const out = [];
        for (const name in keys) {
            const k = keys[name];
            if (k.key.startsWith("XF86") || k.key === "Print")
                continue;
            const digit = /^[1-9]$/.test(k.key) && k.desc.endsWith(" " + k.key);
            if (digit) {
                const desc = k.desc.slice(0, -1) + "N";
                const id = k.mods + "|" + desc;
                if (!digitRuns[id]) {
                    digitRuns[id] = {
                        chord: emacsChord(k.mods, "1..9"),
                        desc: desc
                    };
                    out.push(digitRuns[id]);
                }
                continue;
            }
            out.push({
                chord: emacsChord(k.mods, k.key),
                desc: k.desc
            });
        }
        return out.sort((a, b) => a.desc.localeCompare(b.desc));
    }

    readonly property var globalEntries: entries(keymap.root ?? {})
    readonly property var submapColumns: {
        const maps = keymap.submaps ?? {};
        const sections = Object.keys(maps).map(name => ({
                    title: maps[name].desc,
                    prefix: emacsChord(maps[name].mods, maps[name].key),
                    rows: entries(maps[name].keys ?? {})
                })).sort((a, b) => b.rows.length - a.rows.length);
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

    FileView {
        path: `${Quickshell.env("HOME")}/.config/wm/help.json`
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                root.keymap = JSON.parse(text());
            } catch (e) {
                root.keymap = {};
            }
        }
    }

    RowLayout {
        id: layout

        anchors.fill: parent
        spacing: Tokens.spacing.medium

        Section {
            Layout.alignment: Qt.AlignTop
            title: "Global"
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

            GridLayout {
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
                            Layout.preferredWidth: 116
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

    component KeyCap: StyledRect {
        id: cap

        property alias text: label.text
        property bool prominent

        implicitWidth: Math.max(label.implicitWidth + Tokens.padding.small * 2, implicitHeight)
        implicitHeight: label.implicitHeight + Tokens.padding.extraSmall * 2

        radius: Tokens.rounding.small
        color: prominent ? Colours.palette.m3primaryContainer : Colours.tPalette.m3surfaceContainerHigh

        StyledText {
            id: label

            anchors.centerIn: parent
            font: Tokens.font.mono.small
            color: cap.prominent ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
        }
    }
}
