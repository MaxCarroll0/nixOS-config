package one.damien.keeprunninglock;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayDeque;
import java.util.Deque;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.event.entity.player.PlayerEvent;
import net.neoforged.neoforge.event.server.ServerStartedEvent;
import net.neoforged.neoforge.event.server.ServerStoppingEvent;
import net.neoforged.neoforge.event.tick.ServerTickEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@Mod("keeprunninglock")
public final class KeepRunningLock {
    private static final Path LOCK_FILE = Path.of("/run/keep-running.lock");
    private static final int RECONCILE_EVERY_TICKS = 100;
    private static final Logger LOG = LoggerFactory.getLogger("keeprunninglock");

    private final Deque<FileLock> held = new ArrayDeque<>();
    private FileChannel channel;
    private int ticks;

    public KeepRunningLock() {
        NeoForge.EVENT_BUS.register(this);
    }

    @SubscribeEvent
    public void onStarted(ServerStartedEvent event) {
        try {
            channel = FileChannel.open(LOCK_FILE, StandardOpenOption.READ);
        } catch (IOException e) {
            LOG.error("cannot open {}", LOCK_FILE, e);
        }
        reconcile(event.getServer().getPlayerCount());
    }

    @SubscribeEvent
    public void onLogin(PlayerEvent.PlayerLoggedInEvent event) {
        reconcile(held.size() + 1);
    }

    @SubscribeEvent
    public void onLogout(PlayerEvent.PlayerLoggedOutEvent event) {
        reconcile(held.size() - 1);
    }

    @SubscribeEvent
    public void onTick(ServerTickEvent.Post event) {
        if (++ticks % RECONCILE_EVERY_TICKS == 0) {
            reconcile(event.getServer().getPlayerCount());
        }
    }

    @SubscribeEvent
    public void onStopping(ServerStoppingEvent event) {
        reconcile(0);
        if (channel != null) {
            try {
                channel.close();
            } catch (IOException e) {
                LOG.warn("closing {}", LOCK_FILE, e);
            }
            channel = null;
        }
    }

    private void reconcile(int players) {
        if (channel == null) {
            return;
        }
        int wanted = Math.max(0, players);
        while (held.size() > wanted) {
            try {
                held.pop().release();
            } catch (IOException e) {
                LOG.warn("releasing lock", e);
            }
        }
        while (held.size() < wanted) {
            try {
                held.push(channel.lock(2L * held.size(), 1, true));
            } catch (IOException e) {
                LOG.error("taking lock {}", held.size(), e);
                return;
            }
        }
    }
}
