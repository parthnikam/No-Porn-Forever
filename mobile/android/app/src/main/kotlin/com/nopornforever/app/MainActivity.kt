package com.nopornforever.app

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val vpnMethod = "com.nopornforever.filterd/vpn"
    private val vpnEvents = "com.nopornforever.filterd/vpn_events"
    private val screenMethod = "com.nopornforever.filterd/screen"
    private val screenEvents = "com.nopornforever.filterd/screen_frames"

    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingScreenResult: MethodChannel.Result? = null
    private var pendingScreenArgs: Map<*, *>? = null
    private var vpnEventSink: EventChannel.EventSink? = null
    private var screenEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, vpnMethod)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(
                        mapOf(
                            "platform" to "android",
                            "vpnSupported" to true,
                            "vpnImplemented" to true,
                            "overlaySupported" to true,
                            "notes" to "Android VpnService local DNS filter is fully wired. " +
                                "User must accept the VPN consent dialog. " +
                                "Same nsfw.txt semantics as desktop filterd.",
                        ),
                    )
                    "start" -> startVpn(result)
                    "stop" -> {
                        stopVpn()
                        result.success(true)
                    }
                    "testDomain" -> {
                        val domain = call.argument<String>("domain") ?: ""
                        val eng = FilterVpnService.engine ?: FilterVpnService.loadEngine(this)
                        val d = eng.check(domain)
                        result.success(
                            mapOf(
                                "domain" to d.domain,
                                "blocked" to d.blocked,
                                "matchedRule" to d.matchedRule,
                                "source" to d.source,
                                "allowedBy" to d.allowedBy,
                            ),
                        )
                    }
                    "reloadLists" -> {
                        val eng = FilterVpnService.loadEngine(this)
                        result.success(
                            mapOf(
                                "blockCount" to eng.block.length(),
                                "allowCount" to eng.allow.length(),
                            ),
                        )
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, vpnEvents)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    vpnEventSink = events
                    EventBus.listener = { map ->
                        runOnUiThread { vpnEventSink?.success(map) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    vpnEventSink = null
                    EventBus.listener = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, screenMethod)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(
                        mapOf(
                            "platform" to "android",
                            "screenCaptureSupported" to true,
                            "notes" to "MediaProjection periodic JPEG frames for image classifier.",
                        ),
                    )
                    "start" -> {
                        val args = call.arguments as? Map<*, *>
                        startScreenCapture(args, result)
                    }
                    "stop" -> {
                        ScreenCaptureService.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, screenEvents)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    screenEventSink = events
                    FrameBus.listener = { b64 ->
                        runOnUiThread { screenEventSink?.success(b64) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    screenEventSink = null
                    FrameBus.listener = null
                }
            })
    }

    private fun startVpn(result: MethodChannel.Result) {
        val prepare = VpnService.prepare(this)
        if (prepare != null) {
            pendingVpnResult = result
            @Suppress("DEPRECATION")
            startActivityForResult(prepare, REQ_VPN)
        } else {
            launchVpnService()
            result.success(true)
        }
    }

    private fun launchVpnService() {
        val intent = Intent(this, FilterVpnService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        EventBus.emitStatus("connecting")
    }

    private fun stopVpn() {
        val intent = Intent(this, FilterVpnService::class.java).setAction(FilterVpnService.ACTION_STOP)
        startService(intent)
        EventBus.emitStatus("idle")
    }

    private fun startScreenCapture(args: Map<*, *>?, result: MethodChannel.Result) {
        pendingScreenArgs = args
        pendingScreenResult = result
        val mpm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), REQ_SCREEN)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_VPN -> {
                val res = pendingVpnResult
                pendingVpnResult = null
                if (resultCode == Activity.RESULT_OK) {
                    launchVpnService()
                    res?.success(true)
                } else {
                    res?.success(false)
                }
            }
            REQ_SCREEN -> {
                val res = pendingScreenResult
                val args = pendingScreenArgs
                pendingScreenResult = null
                pendingScreenArgs = null
                if (resultCode == Activity.RESULT_OK && data != null) {
                    val interval = (args?.get("intervalMs") as? Number)?.toLong() ?: 4000L
                    val quality = (args?.get("quality") as? Number)?.toInt() ?: 55
                    val maxWidth = (args?.get("maxWidth") as? Number)?.toInt() ?: 720
                    ScreenCaptureService.start(this, resultCode, data, interval, quality, maxWidth)
                    res?.success(true)
                } else {
                    res?.success(false)
                }
            }
        }
    }

    companion object {
        private const val REQ_VPN = 1001
        private const val REQ_SCREEN = 1002
    }
}
