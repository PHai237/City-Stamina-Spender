package com.example.city_stamina_mobile

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "city_stamina_mobile/control"
    private val eventsChannelName = "city_stamina_mobile/control_events"
    private var controlEventSink: EventChannel.EventSink? = null
    private var controlReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "canPostNotifications" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                    } else {
                        true
                    }
                    result.success(granted)
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1102)
                    }
                    result.success(null)
                }
                "startControl" -> {
                    startService(Intent(this, ControlService::class.java).setAction(ControlService.ACTION_SHOW))
                    result.success(null)
                }
                "stopControl" -> {
                    startService(Intent(this, ControlService::class.java).setAction(ControlService.ACTION_HIDE))
                    result.success(null)
                }
                "setControlRunning" -> {
                    val running = call.argument<Boolean>("running") ?: false
                    val action = if (running) ControlService.ACTION_SET_RUNNING else ControlService.ACTION_SET_IDLE
                    startService(Intent(this, ControlService::class.java).setAction(action))
                    result.success(null)
                }
                "setControlAmount" -> {
                    val amount = call.argument<String>("amount") ?: ""
                    startService(
                        Intent(this, ControlService::class.java)
                            .setAction(ControlService.ACTION_SET_AMOUNT)
                            .putExtra(ControlService.KEY_AMOUNT, amount)
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventsChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    controlEventSink = events
                    registerControlReceiver()
                }

                override fun onCancel(arguments: Any?) {
                    unregisterControlReceiver()
                    controlEventSink = null
                }
            }
        )
    }

    override fun onDestroy() {
        unregisterControlReceiver()
        super.onDestroy()
    }

    private fun registerControlReceiver() {
        if (controlReceiver != null) return
        controlReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != ControlService.ACTION_TOGGLE_REQUEST) return
                controlEventSink?.success(
                    mapOf(
                        "type" to (intent.getStringExtra("type") ?: "toggle"),
                        "running" to intent.getBooleanExtra("running", false),
                        "amount" to (intent.getStringExtra("amount") ?: "")
                    )
                )
            }
        }

        val filter = IntentFilter(ControlService.ACTION_TOGGLE_REQUEST)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(controlReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(controlReceiver, filter)
        }
    }

    private fun unregisterControlReceiver() {
        controlReceiver?.let {
            unregisterReceiver(it)
            controlReceiver = null
        }
    }
}
