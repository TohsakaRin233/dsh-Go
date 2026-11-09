package io.github.ccch1mneyyy.dsh_app.tailnet

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import mobile.Bridge
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Process-wide owner of the embedded tsnet node.
 *
 * Deliberately NOT tied to DshService: that service exists to keep the *local*
 * PRoot engine alive, and someone who only uses remote hosts never starts it.
 * This manager follows the same singleton shape as RuntimeController.
 *
 * All Go calls run on one background thread; tsnet.Up() blocks until the node
 * is authorised, so it must never run on the main thread.
 */
class TailnetBridgeManager private constructor(private val appContext: Context) {

    companion object {
        private const val TAG = "Tailnet"
        private const val NODE_NAME = "dshgo-phone"
        private const val WAIT_RUNNING_MS = 45_000L
        private const val WATCH_SETTLE_MS = 180_000L
        private const val WATCH_TICK_MS = 500L

        @Volatile
        private var instance: TailnetBridgeManager? = null

        fun get(context: Context): TailnetBridgeManager =
            instance ?: synchronized(this) {
                instance ?: TailnetBridgeManager(context.applicationContext).also { instance = it }
            }
    }

    private val executor = Executors.newSingleThreadExecutor()

    /**
     * Separate from [executor] on purpose: watching the node while it waits for
     * authorization can take minutes, and must not delay stop()/ensureEndpoint().
     */
    private val watcher = Executors.newSingleThreadExecutor { r ->
        Thread(r, "tailnet-watch").apply { isDaemon = true }
    }

    /** Bumped on every start/stop so a stale watcher leaves the UI alone. */
    private val watchEpoch = AtomicInteger(0)

    private val main = Handler(Looper.getMainLooper())

    private var bridge: Bridge? = null
    private var currentTarget: String? = null
    private var sink: EventChannel.EventSink? = null

    /** Node state lives in app-private storage that never goes to backup. */
    private fun stateDir(): String {
        val dir = File(appContext.noBackupFilesDir, "tailnet/node1")
        if (!dir.exists()) dir.mkdirs()
        return dir.absolutePath
    }

    fun attachSink(eventSink: EventChannel.EventSink?) {
        sink = eventSink
        if (eventSink != null) pushStatus()
    }

    fun statusJson(): String = bridge?.statusJSON() ?: """{"state":"idle"}"""

    /**
     * Starts the node, optionally binding it to [host]:[port] first.
     *
     * Without a target there is nothing to forward to, so this used to return
     * immediately — which made a "start the node" button in the UI a no-op.
     * Now the caller can pass the host form's address, and the node comes up
     * far enough to hand back its `authUrl`.
     */
    fun start(host: String? = null, port: Int? = null) {
        executor.execute {
            if (host != null && port != null) {
                val target = "$host:$port"
                if (currentTarget != target) {
                    bridge?.stop()
                    bridge = null
                    currentTarget = target
                }
            }
            // No hard-coded destination on purpose: the target always comes from
            // the SSH host the person configured (or ensureEndpoint()).
            val target = currentTarget
            if (target == null) {
                pushStatus()
                return@execute
            }
            val b = bridge ?: Mobile_newBridge(target).also { bridge = it }
            try {
                b.start()
            } catch (t: Throwable) {
                Log.w(TAG, "tailnet start failed", t)
            }
            pushStatus()
            // tsnet.Up() blocks on its own goroutine, so the node sits in
            // starting/needs_login for a while; without this the UI would only
            // ever see the first frame and never the authUrl.
            watchUntilSettled(b)
        }
    }

    fun stop() {
        watchEpoch.incrementAndGet()
        executor.execute {
            bridge?.stop()
            bridge = null
            currentTarget = null
            pushStatus()
        }
    }

    /**
     * Brings the node up for [host]:[port] on the manager's background thread
     * and delivers the loopback port through [onResult] (0 = failed).
     *
     * Never blocks the caller: MethodChannel handlers run on the Android main
     * thread, and waiting for tsnet there is an instant ANR (the first cut of
     * this code did exactly that and froze the whole UI).
     */
    fun ensureEndpoint(host: String, port: Int, onResult: (Int) -> Unit) {
        executor.execute {
            val result = try {
                ensureEndpointBlocking(host, port)
            } catch (t: Throwable) {
                Log.w(TAG, "ensureEndpoint failed", t)
                0
            }
            onResult(result)
        }
    }

    /**
     * The actual work, already on the background thread.
     *
     * A different target than the current one rebuilds the Go bridge: the
     * bridge pins exactly one destination on purpose, so it is never a generic
     * TCP proxy.
     */
    private fun ensureEndpointBlocking(host: String, port: Int): Int {
        val target = "$host:$port"
        var b = bridge
        if (b == null || currentTarget != target) {
            b?.stop()
            b = Mobile_newBridge(target)
            bridge = b
            currentTarget = target
        }
        b!!.start()
        val deadline = System.currentTimeMillis() + WAIT_RUNNING_MS
        while (System.currentTimeMillis() < deadline) {
            val status = b.statusJSON()
            if (status.contains("\"state\":\"running\"")) break
            if (status.contains("\"state\":\"error\"")) {
                pushStatus(status)
                return 0
            }
            // Waiting out the full timeout cannot help here: the person has to
            // authorize the node in a browser first. Fail fast and publish the
            // status so the form can point at the login link instead of hanging.
            if (status.contains("\"state\":\"needs_login\"")) {
                pushStatus(status)
                return 0
            }
            Thread.sleep(400)
        }
        pushStatus()
        // Already on the manager thread: calling Go directly here. Never
        // submit to the same single-thread executor again — that deadlocks.
        // Go's EnsureEndpoint returns an error unless the node is running, and
        // gomobile turns that into an exception, so it is caught here.
        return try {
            b.ensureEndpoint().toInt()
        } catch (t: Throwable) {
            Log.w(TAG, "tailnet endpoint unavailable", t)
            0
        }
    }

    /**
     * Re-publishes the node status until it settles, so a login prompt reaches
     * Dart. Runs on [watcher]: at most one loop per start, cancelled by the
     * next start/stop through [watchEpoch].
     */
    private fun watchUntilSettled(b: Bridge) {
        val epoch = watchEpoch.incrementAndGet()
        watcher.execute {
            val deadline = System.currentTimeMillis() + WATCH_SETTLE_MS
            while (epoch == watchEpoch.get() && System.currentTimeMillis() < deadline) {
                val status = try {
                    b.statusJSON()
                } catch (t: Throwable) {
                    Log.w(TAG, "tailnet status failed", t)
                    return@execute
                }
                pushStatus(status)
                if (status.contains("\"state\":\"running\"") || status.contains("\"state\":\"error\"")) {
                    return@execute
                }
                Thread.sleep(WATCH_TICK_MS)
            }
        }
    }

    private fun Mobile_newBridge(target: String): Bridge =
        mobile.Mobile.newBridge(stateDir(), NODE_NAME, target)

    private fun pushStatus(json: String = statusJson()) {
        main.post { sink?.success(json) }
    }
}
