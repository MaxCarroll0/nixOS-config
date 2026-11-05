package net.carroll.savelag;

import com.mojang.authlib.GameProfile;
import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.IntegerArgumentType;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.stream.Stream;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.NbtAccounter;
import net.minecraft.nbt.NbtIo;
import net.minecraft.network.chat.Component;
import net.minecraft.server.MinecraftServer;
import net.carroll.savelag.mixin.MinecraftServerAccessor;
import net.minecraft.world.level.storage.LevelResource;
import net.minecraft.world.level.storage.PlayerDataStorage;
import net.neoforged.neoforge.common.util.FakePlayer;
import net.neoforged.neoforge.common.util.FakePlayerFactory;

public final class SaveBench {
    private SaveBench() {}

    public static void register(CommandDispatcher<CommandSourceStack> dispatcher) {
        dispatcher.register(Commands.literal("savelag")
            .requires(source -> source.hasPermission(4))
            .then(Commands.literal("bench")
                .then(Commands.argument("rounds", IntegerArgumentType.integer(1, 1000))
                    .executes(context -> run(context.getSource(), IntegerArgumentType.getInteger(context, "rounds")))))
            .then(Commands.literal("roundtrip").executes(context -> roundtrip(context.getSource()))));
    }

    private static int run(CommandSourceStack source, int rounds) {
        MinecraftServer server = source.getServer();
        Path dir = server.getWorldPath(LevelResource.PLAYER_DATA_DIR);
        List<Path> files;
        try (Stream<Path> listing = Files.list(dir)) {
            files = listing.filter(p -> p.getFileName().toString().endsWith(".dat")).sorted().toList();
        } catch (Exception e) {
            source.sendFailure(Component.literal("savelag bench: " + e));
            return 0;
        }
        for (Path file : files) {
            try {
                String name = file.getFileName().toString().replace(".dat", "");
                CompoundTag stored = NbtIo.readCompressed(file, NbtAccounter.unlimitedHeap());
                FakePlayer player = FakePlayerFactory.get(server.overworld(), new GameProfile(UUID.fromString(name), "bench-" + name.substring(0, 8)));
                player.load(stored);
                long[] stock = new long[rounds];
                long[] build = new long[rounds];
                long[] copy = new long[rounds];
                long bytes = 0;
                for (int i = 0; i < rounds; i++) {
                    long start = System.nanoTime();
                    CompoundTag tag = player.saveWithoutId(new CompoundTag());
                    Path temp = Files.createTempFile(dir, "savelag-bench-", ".dat");
                    NbtIo.writeCompressed(tag, temp);
                    stock[i] = System.nanoTime() - start;
                    bytes = Files.size(temp);
                    Files.delete(temp);
                    start = System.nanoTime();
                    CompoundTag rebuilt = player.saveWithoutId(new CompoundTag());
                    long mid = System.nanoTime();
                    rebuilt.copy();
                    build[i] = mid - start;
                    copy[i] = System.nanoTime() - mid;
                }
                String line = String.format("savelag bench %s: %d bytes gzip; median main-thread stock %.1f ms, with mod %.1f ms (build %.1f, copy %.1f); max stock %.1f, with mod %.1f",
                    name, bytes, median(stock), median(build) + median(copy), median(build), median(copy), max(stock), maxSum(build, copy));
                source.sendSuccess(() -> Component.literal(line), true);
                FakePlayerFactory.unloadLevel(server.overworld());
            } catch (Exception e) {
                source.sendFailure(Component.literal("savelag bench " + file.getFileName() + ": " + e));
            }
        }
        return files.size();
    }

    private static int roundtrip(CommandSourceStack source) {
        MinecraftServer server = source.getServer();
        PlayerDataStorage storage = ((MinecraftServerAccessor) server).savelag$playerDataStorage();
        Path dir = server.getWorldPath(LevelResource.PLAYER_DATA_DIR);
        int failures = 0;
        for (Path file : playerFiles(dir)) {
            String name = file.getFileName().toString().replace(".dat", "");
            try {
                UUID id = UUID.fromString(name);
                CompoundTag before = NbtIo.readCompressed(file, NbtAccounter.unlimitedHeap());
                FakePlayer player = FakePlayerFactory.get(server.overworld(), new GameProfile(id, "rt-" + name.substring(0, 8)));
                player.load(before);
                CompoundTag expected = player.saveWithoutId(new CompoundTag());
                int unchangedBefore = PlayerWrites.UNCHANGED.get();
                storage.save(player);
                PlayerWrites.drain();
                CompoundTag written = NbtIo.readCompressed(file, NbtAccounter.unlimitedHeap());
                CompoundTag rotated = NbtIo.readCompressed(dir.resolve(name + ".dat_old"), NbtAccounter.unlimitedHeap());
                storage.save(player);
                PlayerWrites.drain();
                boolean skipped = PlayerWrites.UNCHANGED.get() == unchangedBefore + 1;
                FakePlayer reloaded = FakePlayerFactory.get(server.overworld(), new GameProfile(id, "rt-" + name.substring(0, 8)));
                boolean loads = storage.load(reloaded).isPresent();
                boolean ok = written.equals(expected) && rotated.equals(before) && skipped && loads;
                if (!ok) {
                    failures++;
                }
                String line = String.format("savelag roundtrip %s: %s (written=expected %b, dat_old=previous %b, unchanged skipped %b, loads %b)",
                    name, ok ? "OK" : "FAIL", written.equals(expected), rotated.equals(before), skipped, loads);
                source.sendSuccess(() -> Component.literal(line), true);
                FakePlayerFactory.unloadLevel(server.overworld());
            } catch (IllegalArgumentException e) {
                continue;
            } catch (Exception e) {
                failures++;
                source.sendFailure(Component.literal("savelag roundtrip " + name + ": " + e));
            }
        }
        int total = failures;
        source.sendSuccess(() -> Component.literal("savelag roundtrip failures: " + total), true);
        return failures == 0 ? 1 : 0;
    }

    private static List<Path> playerFiles(Path dir) {
        try (Stream<Path> listing = Files.list(dir)) {
            return listing.filter(p -> p.getFileName().toString().endsWith(".dat")).sorted().toList();
        } catch (Exception e) {
            return List.of();
        }
    }

    private static double median(long[] nanos) {
        long[] sorted = nanos.clone();
        Arrays.sort(sorted);
        return sorted[sorted.length / 2] / 1e6;
    }

    private static double max(long[] nanos) {
        return Arrays.stream(nanos).max().orElse(0) / 1e6;
    }

    private static double maxSum(long[] a, long[] b) {
        long worst = 0;
        for (int i = 0; i < a.length; i++) {
            worst = Math.max(worst, a[i] + b[i]);
        }
        return worst / 1e6;
    }
}
