package io.github.ccch1mneyyy.dsh_app.tailnet

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** Flutter bridge for the embedded tailnet: `dsh/tailnet` + `dsh/tailnet/events`. */
class TailnetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var manager: TailnetBridgeManager
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        manager = TailnetBridgeManager.get(binding.applicationContext)
        methods = MethodChannel(binding.binaryMessenger, "dsh/tailnet").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dsh/tailnet/events").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        manager.attachSink(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    // Optional target: the SSH form passes the host it is
                    // editing so the node can come up far enough to report
                    // needs_login + authUrl. Without it this is the old
                    // "start whatever target is already pinned" call.
                    val host = call.argument<String>("targetHost")
                    val port = call.argument<Int>("targetPort")
                    val hasTarget = !host.isNullOrBlank() && port != null && port in 1..65535
                    manager.start(if (hasTarget) host else null, if (hasTarget) port else null)
                    result.success(null)
                }
                "stop" -> {
                    manager.stop()
                    result.success(null)
                }
                "status" -> result.success(manager.statusJson())
                "ensureEndpoint" -> {
                    val host = call.argument<String>("targetHost")
                    val port = call.argument<Int>("targetPort")
                    if (host.isNullOrBlank() || port == null || port !in 1..65535) {
                        result.error("bad_target", "targetHost/targetPort required", null)
                    } else {
                        // Fires on a manager thread; hop back to the platform
                        // main thread before answering the channel.
                        manager.ensureEndpoint(host, port) { endpointPort ->
                            main.post { result.success(endpointPort) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("tailnet_failed", t.toString(), null)
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        manager.attachSink(eventSink)
    }

    override fun onCancel(arguments: Any?) {
        manager.attachSink(null)
    }
}
