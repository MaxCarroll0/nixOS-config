import QtQuick
import Quickshell
import Caelestia.Config
import qs.services
import qs.modules.drawers

StyledText {
    id: root

    readonly property bool floating: hover.hovered && truncated
    readonly property Item surface: {
        const win = QsWindow.window;
        const contentWin = win as ContentWindow;
        return contentWin ? contentWin.interactionWrapper : (win as QsWindow)?.contentItem ?? null;
    }

    function place(): void {
        if (!surface)
            return;
        const at = mapToItem(surface, 0, 0);
        const w = chip.width;
        const left = elide === Text.ElideLeft ? at.x + width - w + Tokens.padding.small : at.x - Tokens.padding.small;
        chip.x = Math.max(4, Math.min(surface.width - w - 4, left));
        chip.y = Math.max(4, Math.min(surface.height - chip.height - 4, at.y - Tokens.padding.extraSmall));
    }

    onFloatingChanged: if (floating)
        place()

    HoverHandler {
        id: hover
    }

    StyledRect {
        id: chip

        parent: root.surface
        visible: root.floating
        z: 100
        width: Math.min(full.implicitWidth, (root.surface?.width ?? 0) - 8 - Tokens.padding.small * 2) + Tokens.padding.small * 2
        height: full.implicitHeight + Tokens.padding.extraSmall * 2
        radius: Tokens.rounding.small
        color: Colours.palette.m3surfaceContainerHighest
        onWidthChanged: root.place()

        StyledText {
            id: full

            x: Tokens.padding.small
            y: Tokens.padding.extraSmall
            width: chip.width - Tokens.padding.small * 2
            text: root.text
            font: root.font
            color: root.color
            wrapMode: Text.Wrap
        }
    }
}
