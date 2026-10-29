pragma Singleton

import Quickshell

Singleton {
    readonly property real exponent: 2

    function position(level: real, max: real): real {
        return max * Math.pow(Math.max(0, level) / max, 1 / exponent);
    }

    function level(position: real, max: real): real {
        return max * Math.pow(Math.max(0, position) / max, exponent);
    }
}
