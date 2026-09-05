import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

ShellRoot {
  id: root

  property var palette: ({})
  property var keymap: ({})
  property string submap: ""
  property bool panelVisible: false

  function role(name, fallback) {
    return palette[name] !== undefined ? palette[name] : fallback
  }

  function currentEntries() {
    if (submap.length === 0) return []
    const maps = keymap.submaps || {}
    const entry = maps[submap]
    if (entry === undefined) return []
    const keys = entry.keys || {}
    let out = []
    for (const name in keys) {
      const k = keys[name]
      const mods = k.mods && k.mods.length > 0 ? k.mods + "+" : ""
      out.push({ chord: mods + k.key, desc: k.desc })
    }
    out.sort((a, b) => a.chord.localeCompare(b.chord))
    return out
  }

  function currentTitle() {
    const maps = keymap.submaps || {}
    const entry = maps[submap]
    return entry !== undefined ? entry.desc : submap
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/theme/palette.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.palette = JSON.parse(text())
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/wm/help.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.keymap = JSON.parse(text())
  }

  Socket {
    connected: true
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr/"
          + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") + "/.socket2.sock"
    parser: SplitParser {
      onRead: line => {
        if (line.startsWith("submap>>")) root.submap = line.substring(8).trim()
      }
    }
  }

  Timer {
    id: idle
    interval: 400
    repeat: false
    onTriggered: root.panelVisible = true
  }

  onSubmapChanged: {
    if (submap.length > 0) {
      idle.restart()
    } else {
      idle.stop()
      panelVisible = false
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.panelVisible && root.currentEntries().length > 0

      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "wm-whichkey"

      anchors { bottom: true }
      exclusiveZone: 0
      margins { bottom: 60 }
      implicitWidth: card.implicitWidth
      implicitHeight: card.implicitHeight
      color: "transparent"

      Rectangle {
        id: card
        anchors.centerIn: parent
        radius: 7
        color: root.role("surface", "#ebdbb2")
        border.width: 3
        border.color: root.role("border-active", "#af3a03")
        implicitWidth: layout.implicitWidth + 32
        implicitHeight: layout.implicitHeight + 24

        ColumnLayout {
          id: layout
          anchors.centerIn: parent
          spacing: 6

          Text {
            text: root.currentTitle()
            color: root.role("accent", "#af3a03")
            font.family: "Fira Code"
            font.pixelSize: 15
            font.bold: true
            Layout.bottomMargin: 4
          }

          GridLayout {
            columns: 2
            columnSpacing: 28
            rowSpacing: 4

            Repeater {
              model: root.currentEntries()
              delegate: RowLayout {
                required property var modelData
                spacing: 10
                Text {
                  text: modelData.chord
                  color: root.role("accent-alt", "#076678")
                  font.family: "Fira Code"
                  font.pixelSize: 14
                  font.bold: true
                  Layout.minimumWidth: 70
                }
                Text {
                  text: modelData.desc
                  color: root.role("fg", "#3c3836")
                  font.family: "Fira Code"
                  font.pixelSize: 14
                }
              }
            }
          }
        }
      }
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.submap.length > 0

      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "wm-submap-indicator"

      anchors { top: true; right: true }
      exclusiveZone: 0
      margins { top: 8; right: 8 }
      implicitWidth: pill.implicitWidth
      implicitHeight: pill.implicitHeight
      color: "transparent"

      Rectangle {
        id: pill
        radius: 7
        color: root.role("accent", "#af3a03")
        implicitWidth: label.implicitWidth + 20
        implicitHeight: label.implicitHeight + 10

        Text {
          id: label
          anchors.centerIn: parent
          text: root.submap
          color: root.role("bg", "#f9f5d7")
          font.family: "Fira Code"
          font.pixelSize: 13
          font.bold: true
        }
      }
    }
  }
}
