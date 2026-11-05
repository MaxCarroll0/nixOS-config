package net.carroll.savelag.mixin;

import net.carroll.savelag.SaveTimer;
import net.minecraft.server.players.PlayerList;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(PlayerList.class)
abstract class PlayerListMixin {
    @Inject(method = "saveAll", at = @At("HEAD"))
    private void savelag$begin(CallbackInfo ci) {
        SaveTimer.beginPlayers();
    }

    @Inject(method = "saveAll", at = @At("RETURN"))
    private void savelag$end(CallbackInfo ci) {
        SaveTimer.endPlayers();
    }
}
