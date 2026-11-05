package net.carroll.savelag;

import com.mojang.logging.LogUtils;
import org.slf4j.Logger;

public final class SaveTimer {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static long saveStart;
    private static long playersStart;
    private static long playersNanos;
    private static long buildNanos;
    private static long copyNanos;
    private static long slowestNanos;
    private static String slowest = "-";
    private static int players;
    private static boolean flush;
    private static boolean forced;

    private SaveTimer() {}

    public static void beginSave(boolean flushing, boolean forcing) {
        saveStart = System.nanoTime();
        playersNanos = buildNanos = copyNanos = slowestNanos = 0;
        players = 0;
        slowest = "-";
        flush = flushing;
        forced = forcing;
    }

    public static void beginPlayers() {
        playersStart = System.nanoTime();
    }

    public static void endPlayers() {
        playersNanos = System.nanoTime() - playersStart;
    }

    public static void player(String name, long build, long copy) {
        players++;
        buildNanos += build;
        copyNanos += copy;
        if (build + copy > slowestNanos) {
            slowestNanos = build + copy;
            slowest = name;
        }
    }

    public static void endSave() {
        long total = System.nanoTime() - saveStart;
        int writes = PlayerWrites.WRITES.getAndSet(0);
        int unchanged = PlayerWrites.UNCHANGED.getAndSet(0);
        long writeNanos = PlayerWrites.WRITE_NANOS.getAndSet(0);
        LOGGER.info(
            "savelag: save {} ms (flush={}, forced={}); players {} ms for {} (tag build {} ms, copy {} ms, slowest {} {} ms, stats+advancements {} ms); chunks and levels {} ms; off-thread since last save: {} player writes in {} ms, {} unchanged skipped",
            ms(total), flush, forced, ms(playersNanos), players, ms(buildNanos), ms(copyNanos), slowest, ms(slowestNanos),
            ms(playersNanos - buildNanos - copyNanos), ms(total - playersNanos), writes, ms(writeNanos), unchanged);
    }

    private static String ms(long nanos) {
        return String.format("%.1f", nanos / 1e6);
    }
}
