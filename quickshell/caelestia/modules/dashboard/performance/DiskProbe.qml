pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

Item {
    id: root

    property var results: ({})
    property var pending: []
    property string current: ""
    property string currentKind: ""
    property string currentPath: ""
    property var rows: []
    property var times: ({})
    property int unpublished: 0
    readonly property bool busy: current !== ""

    readonly property string dirScript: "cd \"$1\" 2>/dev/null || exit 0; du -ax --max-depth=1 --block-size=1 . 2>/dev/null | sed -u \"s/^/S\\t/\"; find . -xdev -mindepth 1 -printf \"%T@\\t%P\\n\" 2>/dev/null | awk -F\"\\t\" '{ n = $2; i = index(n, \"/\"); if (i) n = substr(n, 1, i - 1); if ($1 + 0 > m[n] + 0) m[n] = $1 } END { for (n in m) printf \"T\\t%s\\t%s\\n\", m[n], n }'"
    readonly property string closureScript: "t=$(mktemp); nix-store -qR \"$1\" 2>/dev/null | sed 's/.*/\"path\":\"&\"/' > \"$t\"; [ -s \"$t\" ] && grep -F -f \"$t\" \"$2\"; rm -f \"$t\""
    readonly property string fileScript: "if [ -s \"$1\" ]; then cat \"$1\"; elif [ \"$2\" = dead ]; then nix-store --gc --print-dead 2>/dev/null | grep -v \"\\.drv$\" | xargs -r -n 200 nix path-info --json 2>/dev/null; fi"

    function has(id: string): bool {
        return id in results;
    }

    function measuring(id: string): bool {
        return current === id;
    }

    function request(id: string, kind: string, path: string, extra: string): void {
        if (id in results || current === id || pending.some(item => item.id === id))
            return;
        pending = pending.concat([{ id: id, kind: kind, path: path, extra: extra }]);
        next();
    }

    function next(): void {
        if (current !== "" || pending.length === 0)
            return;
        const job = pending[0];
        pending = pending.slice(1);
        current = job.id;
        currentKind = job.kind;
        currentPath = job.path;
        rows = [];
        times = {};
        unpublished = 0;
        publish();
        if (job.kind === "dir")
            process.command = ["sh", "-c", dirScript, "probe", job.path];
        else if (job.kind === "closure" && job.extra !== "")
            process.command = ["sh", "-c", closureScript, "probe", job.path, job.extra];
        else if (job.kind === "closure")
            process.command = ["sh", "-c", 'nix-store -qR "$1" 2>/dev/null | xargs -r -n 200 nix path-info --json 2>/dev/null', "probe", job.path];
        else if (job.kind === "dead" || job.kind === "file")
            process.command = ["sh", "-c", fileScript, "probe", job.path, job.kind];
        else {
            finish();
            return;
        }
        process.running = true;
    }

    function publish(): void {
        const copy = Object.assign({}, results);
        copy[current] = rows.slice();
        results = copy;
        unpublished = 0;
    }

    function add(row: var): void {
        rows.push(row);
        unpublished += 1;
        if (unpublished >= 40)
            publish();
    }

    function line(text: string): void {
        if (text.length === 0)
            return;
        if (currentKind === "dir") {
            const parts = text.split("\t");
            if (parts[0] === "S" && parts.length >= 3) {
                const name = parts.slice(2).join("\t");
                if (name === ".")
                    return;
                add({ path: `${currentPath}/${name.replace(/^\.\//, "")}`, size: parseInt(parts[1]), last_used: 0, kind: "dir" });
            } else if (parts[0] === "T" && parts.length >= 3) {
                const name = parts.slice(2).join("\t");
                times[`${currentPath}/${name}`] = Math.floor(parseFloat(parts[1]));
            }
            return;
        }
        let data;
        try {
            data = JSON.parse(text);
        } catch (e) {
            return;
        }
        if (typeof data.path === "string") {
            add({ path: data.path, size: data.size ?? 0, last_used: data.last_used ?? 0, tier: data.tier ?? 0, kind: currentKind === "dead" ? "dead path" : data.projects > 1 ? `store path shared by ${data.projects} projects` : "store path" });
            return;
        }
        for (const path in data) {
            const info = data[path];
            if (info)
                add({ path: path, size: info.narSize ?? 0, last_used: info.registrationTime ?? 0, kind: currentKind === "dead" ? "dead path" : "store path" });
        }
    }

    function finish(): void {
        if (currentKind === "dir")
            for (const row of rows)
                row.last_used = times[row.path] ?? 0;
        publish();
        current = "";
        currentKind = "";
        currentPath = "";
        next();
    }

    Process {
        id: process

        stdout: SplitParser {
            onRead: data => root.line(data)
        }
        onExited: root.finish()
    }
}
