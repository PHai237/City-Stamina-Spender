package com.example.city_stamina_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class ScreenCaptureService : Service() {
    companion object {
        const val ACTION_START = "city_stamina_mobile.capture.START"
        const val ACTION_STOP = "city_stamina_mobile.capture.STOP"
        private const val CHANNEL_ID = "city_stamina_screen_capture"
        private const val NOTIFICATION_ID = 1201
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("City Stamina diagnostics")
            .setContentText("Capturing one screen frame.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "City Stamina diagnostics",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Temporary screen capture for diagnostics."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
