package com.example.city_stamina_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class ControlService : Service() {
    companion object {
        const val ACTION_SHOW = "city_stamina_mobile.control.SHOW"
        const val ACTION_HIDE = "city_stamina_mobile.control.HIDE"
        const val ACTION_SET_RUNNING = "city_stamina_mobile.control.SET_RUNNING"
        const val ACTION_SET_IDLE = "city_stamina_mobile.control.SET_IDLE"
        const val ACTION_TOGGLE = "city_stamina_mobile.control.TOGGLE"
        const val ACTION_TOGGLE_REQUEST = "city_stamina_mobile.control.TOGGLE_REQUEST"

        private const val CHANNEL_ID = "city_stamina_control"
        private const val NOTIFICATION_ID = 1101
    }

    private var isRunning = false

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SET_RUNNING -> {
                isRunning = true
                showNotification()
            }
            ACTION_SET_IDLE -> {
                isRunning = false
                showNotification()
            }
            ACTION_TOGGLE -> {
                isRunning = !isRunning
                sendBroadcast(Intent(ACTION_TOGGLE_REQUEST).putExtra("running", isRunning))
                showNotification()
            }
            else -> showNotification()
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun showNotification() {
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val openAppIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val openAppPendingIntent = PendingIntent.getActivity(
            this,
            10,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val togglePendingIntent = PendingIntent.getService(
            this,
            11,
            Intent(this, ControlService::class.java).setAction(ACTION_TOGGLE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val actionTitle = if (isRunning) "Stop" else "Run"
        val contentText = if (isRunning) {
            "Automation is running. Tap Stop if needed."
        } else {
            "Ready. Tap Run after entering amount in the app."
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("City Stamina")
            .setContentText(contentText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppPendingIntent)
            .addAction(android.R.drawable.ic_media_play, actionTitle, togglePendingIntent)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "City Stamina control",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Run and stop City Stamina automation from notification shade."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
