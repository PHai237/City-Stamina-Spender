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
import androidx.core.app.RemoteInput

class ControlService : Service() {
    companion object {
        const val ACTION_SHOW = "city_stamina_mobile.control.SHOW"
        const val ACTION_HIDE = "city_stamina_mobile.control.HIDE"
        const val ACTION_SET_RUNNING = "city_stamina_mobile.control.SET_RUNNING"
        const val ACTION_SET_IDLE = "city_stamina_mobile.control.SET_IDLE"
        const val ACTION_SET_AMOUNT = "city_stamina_mobile.control.SET_AMOUNT"
        const val ACTION_SET_STATUS = "city_stamina_mobile.control.SET_STATUS"
        const val ACTION_TOGGLE = "city_stamina_mobile.control.TOGGLE"
        const val ACTION_CHECK = "city_stamina_mobile.control.CHECK"
        const val ACTION_TOGGLE_REQUEST = "city_stamina_mobile.control.TOGGLE_REQUEST"
        const val KEY_AMOUNT = "city_stamina_mobile.control.AMOUNT"
        const val KEY_STATUS = "city_stamina_mobile.control.STATUS"

        private const val CHANNEL_ID = "city_stamina_control"
        private const val NOTIFICATION_ID = 1101
    }

    private var isRunning = false
    private var amount = ""
    private var status = "Ready"

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
            ACTION_SET_AMOUNT -> {
                amount = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_AMOUNT)?.toString()
                    ?: intent.getStringExtra(KEY_AMOUNT)
                    ?: ""
                sendBroadcast(
                    Intent(ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "amount")
                        .putExtra("amount", amount)
                )
                showNotification()
            }
            ACTION_SET_STATUS -> {
                status = intent.getStringExtra(KEY_STATUS) ?: "Ready"
                showNotification()
            }
            ACTION_TOGGLE -> {
                isRunning = !isRunning
                sendBroadcast(
                    Intent(ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "toggle")
                        .putExtra("running", isRunning)
                )
                showNotification()
            }
            ACTION_CHECK -> {
                sendBroadcast(
                    Intent(ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "check")
                )
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

        val amountPendingIntent = PendingIntent.getService(
            this,
            12,
            Intent(this, ControlService::class.java).setAction(ACTION_SET_AMOUNT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )

        val checkPendingIntent = PendingIntent.getService(
            this,
            13,
            Intent(this, ControlService::class.java).setAction(ACTION_CHECK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val amountInput = RemoteInput.Builder(KEY_AMOUNT)
            .setLabel("Amount")
            .build()

        val actionTitle = if (isRunning) "Stop" else "Run"
        val contentText = if (isRunning) {
            "Running ${amount.ifBlank { "stage 1-1" }}. $status"
        } else {
            "Amount: ${amount.ifBlank { "not set" }}. $status"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("City Stamina")
            .setContentText(contentText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppPendingIntent)
            .addAction(
                NotificationCompat.Action.Builder(
                    android.R.drawable.ic_menu_edit,
                    "Amount",
                    amountPendingIntent
                ).addRemoteInput(amountInput).build()
            )
            .addAction(android.R.drawable.ic_media_play, actionTitle, togglePendingIntent)
            .addAction(android.R.drawable.ic_menu_search, "Check", checkPendingIntent)
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
