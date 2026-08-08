package com.example.city_stamina_mobile

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "city_stamina_mobile/overlay"

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
    }
}
