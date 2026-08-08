package com.example.city_stamina_mobile

import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import android.widget.Toast

class OverlayService : Service() {
    companion object {
        const val ACTION_SHOW = "city_stamina_mobile.overlay.SHOW"
        const val ACTION_HIDE = "city_stamina_mobile.overlay.HIDE"
        const val ACTION_SET_RUNNING = "city_stamina_mobile.overlay.SET_RUNNING"
        const val ACTION_SET_IDLE = "city_stamina_mobile.overlay.SET_IDLE"
    }

    private lateinit var windowManager: WindowManager
    private var overlayView: TextView? = null
    private var isRunning = false

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SHOW -> showOverlay()
            ACTION_HIDE -> hideOverlay()
            ACTION_SET_RUNNING -> setRunning(true)
            ACTION_SET_IDLE -> setRunning(false)
            else -> showOverlay()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        hideOverlay()
        super.onDestroy()
    }

    private fun showOverlay() {
        if (overlayView != null) {
            updateOverlayText()
            return
        }

        val view = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.BLACK)
            gravity = Gravity.CENTER
            setPadding(22, 12, 22, 12)
            background = overlayBackground(Color.rgb(54, 214, 167))
            updateOverlayText(this)
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 32
            y = 260
        }

        view.setOnTouchListener(DragTouchListener(params))
        view.setOnClickListener {
            isRunning = !isRunning
            updateOverlayText()
            Toast.makeText(this, if (isRunning) "Run" else "Stop", Toast.LENGTH_SHORT).show()
        }

        overlayView = view
        windowManager.addView(view, params)
    }

    private fun hideOverlay() {
        overlayView?.let {
            windowManager.removeView(it)
            overlayView = null
        }
    }

    private fun setRunning(running: Boolean) {
        isRunning = running
        updateOverlayText()
    }

    private fun updateOverlayText() {
        overlayView?.let { updateOverlayText(it) }
    }

    private fun updateOverlayText(view: TextView) {
        view.text = if (isRunning) "Stop" else "Run"
        view.background = overlayBackground(
            if (isRunning) Color.rgb(255, 105, 105) else Color.rgb(54, 214, 167)
        )
    }

    private fun overlayBackground(color: Int): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = 999f
            setColor(color)
        }
    }

    private inner class DragTouchListener(
        private val params: WindowManager.LayoutParams
    ) : View.OnTouchListener {
        private var downRawX = 0f
        private var downRawY = 0f
        private var startX = 0
        private var startY = 0
        private var moved = false

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    moved = false
                    return false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - downRawX).toInt()
                    val dy = (event.rawY - downRawY).toInt()
                    if (kotlin.math.abs(dx) > 8 || kotlin.math.abs(dy) > 8) {
                        moved = true
                        params.x = startX + dx
                        params.y = startY + dy
                        windowManager.updateViewLayout(view, params)
                        return true
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (moved) return true
                }
            }
            return false
        }
    }
}
