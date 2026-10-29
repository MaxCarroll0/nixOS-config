pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Singleton {
    id: root

    property string submap: ""
    property var keymap: ({})
    property var selection: []
    property var aceLabels: []

    readonly property bool normal: submap === "normal" || submap.startsWith("normal:")
    readonly property bool select: submap === "select"
    readonly property bool view: submap === "view"
    readonly property var mode: (keymap.modes ?? {})[submap] ?? null
    readonly property bool prefixActive: mode !== null && submap !== "normal" && !view

    readonly property var keyNames: ({
            comma: ",",
            period: ".",
            slash: "/",
            equal: "=",
            minus: "-",
            bracketleft: "[",
            bracketright: "]",
            grave: "`",
            space: "SPC",
            Return: "RET",
            Tab: "TAB",
            Delete: "<delete>",
            escape: "ESC",
            "code:66": "Caps"
        })
    readonly property var modifierOrder: [["CTRL", "C-"], ["ALT", "M-"], ["SUPER", "s-"]]

    function receive(payload: string): void {
        try {
            const state = JSON.parse(payload);
            selection = state.selection ?? [];
            aceLabels = state.ace ?? [];
        } catch (e) {}
    }

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
            else if (event.name === "custom" && event.data.startsWith("wm>>"))
                root.receive(event.data.slice(4));
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
