package net.carroll.savelag.mixin;

import com.mojang.logging.LogUtils;
import java.io.File;
import java.util.Optional;
import net.carroll.savelag.PlayerWrites;
import net.carroll.savelag.SaveTimer;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.storage.PlayerDataStorage;
import net.neoforged.neoforge.event.EventHooks;
import org.slf4j.Logger;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(PlayerDataStorage.class)
abstract class PlayerDataStorageMixin {
    @Unique
    private static final Logger savelag$LOGGER = LogUtils.getLogger();

    @Shadow
    @Final
    private File playerDir;

    @Inject(method = "save", at = @At("HEAD"), cancellable = true)
    private void savelag$save(Player player, CallbackInfo ci) {
        ci.cancel();
        long start = System.nanoTime();
        try {
            CompoundTag built = player.saveWithoutId(new CompoundTag());
            long mid = System.nanoTime();
            CompoundTag snapshot = built.copy();
            SaveTimer.player(player.getName().getString(), mid - start, System.nanoTime() - mid);
            PlayerWrites.submit(player.getUUID(), playerDir.toPath(), player.getStringUUID(), snapshot);
            EventHooks.firePlayerSavingEvent(player, playerDir, player.getStringUUID());
        } catch (Exception e) {
            savelag$LOGGER.warn("Failed to save player data for {}", player.getName().getString(), e);
        }
    }

    @Inject(method = "load(Lnet/minecraft/world/entity/player/Player;)Ljava/util/Optional;", at = @At("HEAD"))
    private void savelag$awaitWrite(Player player, CallbackInfoReturnable<Optional<CompoundTag>> cir) {
        PlayerWrites.await(player.getUUID());
    }
}
