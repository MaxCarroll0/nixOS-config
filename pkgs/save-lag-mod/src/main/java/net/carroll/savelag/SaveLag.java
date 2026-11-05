package net.carroll.savelag;

import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.event.RegisterCommandsEvent;
import net.neoforged.neoforge.event.server.ServerStoppedEvent;

@Mod("savelag")
public final class SaveLag {
    public SaveLag(IEventBus modBus) {
        NeoForge.EVENT_BUS.addListener(ServerStoppedEvent.class, event -> PlayerWrites.drain());
        NeoForge.EVENT_BUS.addListener(RegisterCommandsEvent.class, event -> SaveBench.register(event.getDispatcher()));
    }
}
