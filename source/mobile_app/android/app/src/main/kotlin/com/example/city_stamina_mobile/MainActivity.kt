package com.example.city_stamina_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "city_stamina_mobile/overlay"
    private val eventsChannelName = "city_stamina_mobile/overlay_events"
    private var overlayEventSink: EventChannel.EventSink? = null
    private var overlayReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "canDrawOverlays" -> result.success(Settings.canDrawOverlays(this))
                "openOverlaySettings" -> {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName")
                    )
                    startActivity(intent)
                    result.success(null)
                }
                "startOverlay" -> {
                    if (!Settings.canDrawOverlays(this)) {
                        result.error("overlay_permission_missing", "Draw over other apps permission is not granted.", null)
                        return@setMethodCallHandler
                    }
                    startService(Intent(this, OverlayService::class.java).setAction(OverlayService.ACTION_SHOW))
                    result.success(null)
                }
                "stopOverlay" -> {
                    startService(Intent(this, OverlayService::class.java).setAction(OverlayService.ACTION_HIDE))
                    result.success(null)
                }
                "setRunning" -> {
                    val running = call.argument<Boolean>("running") ?: false
                    val action = if (running) OverlayService.ACTION_SET_RUNNING else OverlayService.ACTION_SET_IDLE
                    startService(Intent(this, OverlayService::class.java).setAction(action))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventsChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    overlayEventSink = events
                    registerOverlayReceiver()
                }

                override fun onCancel(arguments: Any?) {
                    unregisterOverlayReceiver()
                    overlayEventSink = null
                }
            }
        )
    }

    override fun onDestroy() {
        unregisterOverlayReceiver()
        super.onDestroy()
    }

    private fun registerOverlayReceiver() {
        if (overlayReceiver != null) return
        overlayReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != OverlayService.ACTION_TOGGLE_REQUEST) return
                overlayEventSink?.success(
                    mapOf(
                        "type" to "toggle",
                        "running" to intent.getBooleanExtra("running", false)
                    )
                )
            }
        }

        val filter = IntentFilter(OverlayService.ACTION_TOGGLE_REQUEST)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(overlayReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(overlayReceiver, filter)
        }
    }

    private fun unregisterOverlayReceiver() {
        overlayReceiver?.let {
            unregisterReceiver(it)
            overlayReceiver = null
        }
    }
}
