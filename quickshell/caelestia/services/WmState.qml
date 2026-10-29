pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Singleton {
    id: root

    property string submap: ""
    property var keymap: ({})

    readonly property bool normal: submap === "normal" || submap.startsWith("normal:")
    readonly property var mode: (keymap.modes ?? {})[submap] ?? null
    readonly property bool prefixActive: mode !== null && submap !== "normal"

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
            escape: "ESC",
            "code:66": "Caps"
        })
    readonly property var modifierOrder: [["CTRL", "C-"], ["ALT", "M-"], ["SUPER", "s-"]]

    function chord(mods: string, key: string): string {
        const held = mods.split(" ").filter(m => m.length > 0);
        const shifted = held.includes("SHIFT");
        const letter = /^[a-z]$/.test(key);
        const prefix = modifierOrder.filter(([name]) => held.includes(name)).map(([, emacs]) => emacs).join("");
        const name = keyNames[key] ?? key;
        if (shifted && letter)
            return prefix + name.toUpperCase();
        return prefix + (shifted ? "S-" : "") + name;
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "submap")
                root.submap = event.data;
        }
    }

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
}
