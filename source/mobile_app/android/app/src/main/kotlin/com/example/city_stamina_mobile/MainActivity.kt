package com.example.city_stamina_mobile

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.provider.Settings
import android.text.TextUtils
import android.util.DisplayMetrics
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val channelName = "city_stamina_mobile/control"
    private val eventsChannelName = "city_stamina_mobile/control_events"
    private val screenCaptureRequestCode = 2101
    private var controlEventSink: EventChannel.EventSink? = null
    private var controlReceiver: BroadcastReceiver? = null
    private var pendingScreenCaptureResult: MethodChannel.Result? = null

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
                "getDeviceInfo" -> result.success(getDeviceInfo())
                "isAccessibilityEnabled" -> result.success(isAutomationAccessibilityEnabled())
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "captureScreen" -> requestScreenCapture(result)
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

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != screenCaptureRequestCode) return

        val pending = pendingScreenCaptureResult ?: return
        pendingScreenCaptureResult = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            stopScreenCaptureService()
            pending.error("SCREEN_CAPTURE_DENIED", "Screen capture permission was denied.", null)
            return
        }

        Thread {
            try {
                val result = captureOneFrame(resultCode, data)
                runOnUiThread { pending.success(result) }
            } catch (error: Exception) {
                runOnUiThread {
                    pending.error("SCREEN_CAPTURE_FAILED", error.message ?: "Screen capture failed.", null)
                }
            } finally {
                stopScreenCaptureService()
            }
        }.start()
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

    private fun requestScreenCapture(result: MethodChannel.Result) {
        if (pendingScreenCaptureResult != null) {
            result.error("SCREEN_CAPTURE_BUSY", "A screen capture request is already active.", null)
            return
        }

        pendingScreenCaptureResult = result
        startScreenCaptureService()
        val manager = getSystemService(MediaProjectionManager::class.java)
        startActivityForResult(manager.createScreenCaptureIntent(), screenCaptureRequestCode)
    }

    private fun captureOneFrame(resultCode: Int, data: Intent): Map<String, Any> {
        val metrics = currentDisplayMetrics()
        val width = metrics.widthPixels.coerceAtLeast(1)
        val height = metrics.heightPixels.coerceAtLeast(1)
        val density = metrics.densityDpi.coerceAtLeast(DisplayMetrics.DENSITY_DEFAULT)

        val manager = getSystemService(MediaProjectionManager::class.java)
        val projection: MediaProjection = manager.getMediaProjection(resultCode, data)
            ?: throw IllegalStateException("MediaProjection could not be created.")
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        val thread = HandlerThread("CityStaminaScreenCapture")
        thread.start()
        val handler = Handler(thread.looper)
        projection.registerCallback(object : MediaProjection.Callback() {}, handler)
        val latch = CountDownLatch(1)
        val imageHolder = arrayOfNulls<android.media.Image>(1)

        reader.setOnImageAvailableListener({ source ->
            imageHolder[0] = source.acquireLatestImage()
            latch.countDown()
        }, handler)

        val display = projection.createVirtualDisplay(
            "CityStaminaScreenCapture",
            width,
            height,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            handler
        ) ?: throw IllegalStateException("Virtual display could not be created.")

        try {
            if (!latch.await(2200, TimeUnit.MILLISECONDS)) {
                throw IllegalStateException("Timed out while waiting for a screen frame.")
            }

            val image = imageHolder[0] ?: throw IllegalStateException("No screen frame was captured.")
            image.use {
                val plane = it.planes[0]
                val buffer = plane.buffer
                val pixelStride = plane.pixelStride
                val rowStride = plane.rowStride
                val rowPadding = rowStride - pixelStride * width
                val bitmapWidth = width + rowPadding / pixelStride
                val bitmap = Bitmap.createBitmap(bitmapWidth, height, Bitmap.Config.ARGB_8888)
                bitmap.copyPixelsFromBuffer(buffer)
                val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)

                val dir = File(cacheDir, "mobile_diagnostics")
                dir.mkdirs()
                val file = File(dir, "screen-${System.currentTimeMillis()}.png")
                FileOutputStream(file).use { output ->
                    cropped.compress(Bitmap.CompressFormat.PNG, 92, output)
                }
                bitmap.recycle()
                cropped.recycle()

                return mapOf(
                    "path" to file.absolutePath,
                    "width" to width,
                    "height" to height,
                    "densityDpi" to density
                )
            }
        } finally {
            display.release()
            reader.close()
            projection.stop()
            thread.quitSafely()
        }
    }

    private fun currentDisplayMetrics(): DisplayMetrics {
        val metrics = DisplayMetrics()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = getSystemService(WindowManager::class.java).currentWindowMetrics.bounds
            metrics.widthPixels = bounds.width()
            metrics.heightPixels = bounds.height()
            metrics.densityDpi = resources.displayMetrics.densityDpi
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealMetrics(metrics)
        }
        return metrics
    }

    private fun getDeviceInfo(): Map<String, Any> {
        val metrics = currentDisplayMetrics()
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "brand" to Build.BRAND,
            "device" to Build.DEVICE,
            "androidSdk" to Build.VERSION.SDK_INT,
            "androidRelease" to Build.VERSION.RELEASE,
            "screenWidth" to metrics.widthPixels,
            "screenHeight" to metrics.heightPixels,
            "densityDpi" to metrics.densityDpi,
            "accessibilityEnabled" to isAutomationAccessibilityEnabled(),
            "activePackage" to AutomationAccessibilityService.lastPackageName
        )
    }

    private fun isAutomationAccessibilityEnabled(): Boolean {
        val expected = "$packageName/${AutomationAccessibilityService::class.java.name}"
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val splitter = TextUtils.SimpleStringSplitter(':')
        splitter.setString(enabled)
        for (service in splitter) {
            if (service.equals(expected, ignoreCase = true)) return true
        }
        return false
    }

    private fun startScreenCaptureService() {
        val intent = Intent(this, ScreenCaptureService::class.java).setAction(ScreenCaptureService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopScreenCaptureService() {
        startService(Intent(this, ScreenCaptureService::class.java).setAction(ScreenCaptureService.ACTION_STOP))
    }
}
