package com.example.city_stamina_mobile

import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

class FloatingControlService : Service() {
    companion object {
        const val ACTION_SHOW = "city_stamina_mobile.floating.SHOW"
        const val ACTION_HIDE = "city_stamina_mobile.floating.HIDE"
        const val ACTION_SET_RUNNING = "city_stamina_mobile.floating.SET_RUNNING"
        const val ACTION_SET_IDLE = "city_stamina_mobile.floating.SET_IDLE"
        const val ACTION_SET_AMOUNT = "city_stamina_mobile.floating.SET_AMOUNT"
        const val ACTION_SET_STATUS = "city_stamina_mobile.floating.SET_STATUS"
        const val KEY_AMOUNT = ControlService.KEY_AMOUNT
        const val KEY_STATUS = ControlService.KEY_STATUS
    }

    private var windowManager: WindowManager? = null
    private var rootView: View? = null
    private var amountInput: EditText? = null
    private var runButton: Button? = null
    private var statusText: TextView? = null
    private var isRunning = false
    private var amount = ""
    private var status = "Ready"

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> {
                removeFloatingView()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SET_RUNNING -> {
                isRunning = true
                updateUi()
            }
            ACTION_SET_IDLE -> {
                isRunning = false
                updateUi()
            }
            ACTION_SET_AMOUNT -> {
                amount = intent.getStringExtra(KEY_AMOUNT) ?: ""
                updateUi()
            }
            ACTION_SET_STATUS -> {
                status = intent.getStringExtra(KEY_STATUS) ?: "Ready"
                updateUi()
            }
            else -> showFloatingView()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        removeFloatingView()
        super.onDestroy()
    }

    private fun showFloatingView() {
        if (rootView != null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) return

        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(14, 10, 14, 10)
            setBackgroundColor(Color.argb(232, 10, 17, 32))
        }

        amountInput = EditText(this).apply {
            hint = "Amount"
            setHintTextColor(Color.rgb(148, 163, 184))
            setTextColor(Color.WHITE)
            textSize = 13f
            setSingleLine(true)
            minWidth = 150
            setText(amount)
        }
        runButton = Button(this).apply {
            text = if (isRunning) "Stop" else "Run"
            textSize = 12f
            setOnClickListener {
                syncAmountFromInput()
                isRunning = !isRunning
                sendBroadcast(
                    Intent(ControlService.ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "toggle")
                        .putExtra("running", isRunning)
                        .putExtra("amount", amount)
                )
                updateUi()
            }
        }
        val checkButton = Button(this).apply {
            text = "Check"
            textSize = 12f
            setOnClickListener {
                syncAmountFromInput()
                sendBroadcast(
                    Intent(ControlService.ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "check")
                        .putExtra("amount", amount)
                )
            }
        }
        statusText = TextView(this).apply {
            text = status
            setTextColor(Color.rgb(203, 213, 225))
            textSize = 11f
            maxLines = 1
        }

        root.addView(amountInput, LinearLayout.LayoutParams(170, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(runButton, LinearLayout.LayoutParams(120, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(checkButton, LinearLayout.LayoutParams(130, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(statusText, LinearLayout.LayoutParams(220, LinearLayout.LayoutParams.WRAP_CONTENT))

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 40
            y = 160
        }

        root.setOnTouchListener(DragTouchListener(params))
        rootView = root
        windowManager?.addView(root, params)
        updateUi()
    }

    private fun removeFloatingView() {
        rootView?.let { windowManager?.removeView(it) }
        rootView = null
        amountInput = null
        runButton = null
        statusText = null
    }

    private fun syncAmountFromInput() {
        amount = amountInput?.text?.toString() ?: amount
        sendBroadcast(
            Intent(ControlService.ACTION_TOGGLE_REQUEST)
                .putExtra("type", "amount")
                .putExtra("amount", amount)
        )
    }

    private fun updateUi() {
        amountInput?.let {
            if (it.text.toString() != amount) it.setText(amount)
        }
        runButton?.text = if (isRunning) "Stop" else "Run"
        statusText?.text = status
    }

    private inner class DragTouchListener(
        private val params: WindowManager.LayoutParams
    ) : View.OnTouchListener {
        private var startX = 0
        private var startY = 0
        private var touchX = 0f
        private var touchY = 0f
        private var dragging = false

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchX = event.rawX
                    touchY = event.rawY
                    dragging = false
                    return false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - touchX).toInt()
                    val dy = (event.rawY - touchY).toInt()
                    if (kotlin.math.abs(dx) + kotlin.math.abs(dy) < 10) return false
                    params.x = startX + dx
                    params.y = startY + dy
                    windowManager?.updateViewLayout(view, params)
                    dragging = true
                    return true
                }
                MotionEvent.ACTION_UP -> return dragging
            }
            return false
        }
    }
}
