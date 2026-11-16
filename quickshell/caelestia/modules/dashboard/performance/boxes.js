.pragma library

function runs(list) {
    const out = [];
    for (const [at, len] of [...list].sort((a, b) => a[0] - b[0])) {
        const last = out[out.length - 1];
        if (last && at <= last[0] + last[1])
            last[1] = Math.max(last[1], at + len - last[0]);
        else
            out.push([at, len]);
    }
    return out;
}

function place(piece, list, fraction, flags) {
    const bytes = Math.max(1, piece.bytes);
    const raw = list ? runs(list).map(span => [span[0] / bytes, span[1] / bytes]) : fraction > 0 ? [[0, Math.min(1, fraction)]] : [];
    return raw.map(([at, len]) => {
        const from = piece.x + piece.w * at;
        return Object.assign({ x: from, w: Math.min(piece.x + piece.w, from + piece.w * len) - from, key: piece.key, label: piece.label }, flags);
    }).filter(box => box.w > 0);
}

function layout(pieces) {
    const out = [];
    for (const piece of pieces) {
        if (piece.w <= 0)
            continue;
        const bytes = Math.max(1, piece.bytes);
        out.push(...place(piece, piece.reclaimSpans, (piece.reclaimBytes ?? 0) / bytes, {}));
        out.push(...place(piece, piece.scheduledSpans, (piece.scheduledBytes ?? 0) / bytes, { scheduled: true, bytes: piece.scheduledBytes ?? 0 }));
        out.push(...place(piece, piece.nextSpans, (piece.nextBytes ?? 0) / bytes, { next: true }));
        out.push(...place(piece, piece.laggingBytes > 0 ? piece.laggingSpans ?? null : null, (piece.laggingBytes ?? 0) / bytes, { lagging: true }));
        out.push(...place(piece, piece.deletingBytes > 0 ? piece.deletingSpans ?? null : null, (piece.deletingBytes ?? 0) / bytes, { deleting: true }));
    }
    return out;
}

function merge(spans, split) {
    const sorted = spans.filter(span => span.w > 0).map(span => ({ x: span.x, w: span.w, notches: [] })).sort((a, b) => a.x - b.x);
    const out = [];
    for (const span of sorted) {
        const last = out[out.length - 1];
        const gap = last ? span.x - last.x - last.w : Infinity;
        if (gap <= 1e-3) {
            last.w = Math.max(last.w, span.x + span.w - last.x);
        } else if (gap < split) {
            last.notches.push(last.x + last.w + gap / 2);
            last.w = span.x + span.w - last.x;
        } else
            out.push(span);
    }
    return out;
}
