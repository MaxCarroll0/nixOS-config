package net.carroll.savelag;

import com.mojang.logging.LogUtils;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import net.minecraft.Util;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.NbtIo;
import org.slf4j.Logger;

public final class PlayerWrites {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final ExecutorService WRITER = Executors.newSingleThreadExecutor(task -> {
        Thread thread = new Thread(task, "savelag-player-writer");
        thread.setDaemon(true);
        return thread;
    });
    private static final Map<UUID, Future<?>> PENDING = new ConcurrentHashMap<>();
    private static final Map<UUID, CompoundTag> WRITTEN = new ConcurrentHashMap<>();
    static final AtomicLong WRITE_NANOS = new AtomicLong();
    static final AtomicInteger WRITES = new AtomicInteger();
    static final AtomicInteger UNCHANGED = new AtomicInteger();

    static {
        Runtime.getRuntime().addShutdownHook(new Thread(PlayerWrites::drain, "savelag-drain"));
    }

    private PlayerWrites() {}

    public static void submit(UUID id, Path dir, String name, CompoundTag tag) {
        PENDING.put(id, WRITER.submit(() -> write(id, dir, name, tag)));
    }

    private static void write(UUID id, Path dir, String name, CompoundTag tag) {
        long start = System.nanoTime();
        Path current = dir.resolve(name + ".dat");
        if (tag.equals(WRITTEN.get(id)) && Files.isRegularFile(current)) {
            UNCHANGED.incrementAndGet();
            return;
        }
        try {
            Path temp = Files.createTempFile(dir, name + "-", ".dat");
            NbtIo.writeCompressed(tag, temp);
            Util.safeReplaceFile(current, temp, dir.resolve(name + ".dat_old"));
            WRITTEN.put(id, tag);
        } catch (Exception e) {
            WRITTEN.remove(id);
            LOGGER.warn("Failed to save player data for {}", name, e);
        }
        WRITES.incrementAndGet();
        WRITE_NANOS.addAndGet(System.nanoTime() - start);
    }

    public static void await(UUID id) {
        Future<?> pending = PENDING.get(id);
        if (pending == null) {
            return;
        }
        try {
            pending.get(30, TimeUnit.SECONDS);
        } catch (Exception e) {
            LOGGER.warn("Pending player data write for {} did not finish", id, e);
        }
    }

    public static void drain() {
        try {
            WRITER.submit(() -> {}).get(60, TimeUnit.SECONDS);
        } catch (Exception e) {
            LOGGER.error("Player data writes did not drain", e);
        }
    }
}
