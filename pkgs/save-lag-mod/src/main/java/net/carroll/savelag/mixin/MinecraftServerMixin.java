package net.carroll.savelag.mixin;

import net.carroll.savelag.SaveTimer;
import net.minecraft.server.MinecraftServer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(MinecraftServer.class)
abstract class MinecraftServerMixin {
    @Inject(method = "saveEverything", at = @At("HEAD"))
    private void savelag$begin(boolean suppressLog, boolean flush, boolean forced, CallbackInfoReturnable<Boolean> cir) {
        SaveTimer.beginSave(flush, forced);
    }

    @Inject(method = "saveEverything", at = @At("RETURN"))
    private void savelag$end(boolean suppressLog, boolean flush, boolean forced, CallbackInfoReturnable<Boolean> cir) {
        SaveTimer.endSave();
    }
}
