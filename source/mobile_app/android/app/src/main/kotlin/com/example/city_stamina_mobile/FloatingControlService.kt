package com.example.city_stamina_mobile

import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
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
import kotlin.math.abs

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
    private var rootView: LinearLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var amountInput: EditText? = null
    private var runButton: Button? = null
    private var statusText: TextView? = null
    private var expanded = false
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
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(14)
            y = dp(120)
        }

        rootView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setOnTouchListener(DragTouchListener())
        }
        windowManager?.addView(rootView, params)
        render()
    }

    private fun removeFloatingView() {
        rootView?.let { windowManager?.removeView(it) }
        rootView = null
        params = null
        amountInput = null
        runButton = null
        statusText = null
    }

    private fun render() {
        val root = rootView ?: return
        root.removeAllViews()
        amountInput = null
        runButton = null
        statusText = null

        if (expanded) {
            renderMenu(root)
        } else {
            renderBubble(root)
        }
        updateUi()
    }

    private fun renderBubble(root: LinearLayout) {
        val bubble = TextView(this).apply {
            text = if (isRunning) "■" else "▶"
            gravity = Gravity.CENTER
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            background = rounded(Color.rgb(37, 99, 235), dp(22))
            setOnClickListener {
                expanded = true
                render()
            }
        }
        root.addView(bubble, LinearLayout.LayoutParams(dp(54), dp(54)))
    }

    private fun renderMenu(root: LinearLayout) {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(12))
            background = rounded(Color.argb(244, 10, 17, 32), dp(18), Color.argb(180, 51, 65, 85))
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(TextView(this).apply {
            text = "Owner's Selection"
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(TextView(this).apply {
            text = "×"
            gravity = Gravity.CENTER
            textSize = 20f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.rgb(148, 163, 184))
            setOnClickListener { collapseToEdge() }
        }, LinearLayout.LayoutParams(dp(34), dp(34)))
        card.addView(header, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        amountInput = EditText(this).apply {
            hint = "Amount"
            setHintTextColor(Color.rgb(148, 163, 184))
            setTextColor(Color.WHITE)
            textSize = 20f
            typeface = Typeface.DEFAULT_BOLD
            setSingleLine(true)
            setText(amount)
            setPadding(dp(12), 0, dp(12), 0)
            background = rounded(Color.rgb(15, 23, 42), dp(12), Color.rgb(59, 130, 246))
        }
        card.addView(amountInput, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(54)).apply {
            topMargin = dp(8)
        })

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        runButton = Button(this).apply {
            text = if (isRunning) "Stop" else "Run"
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.rgb(8, 13, 23))
            background = rounded(if (isRunning) Color.rgb(248, 113, 113) else Color.rgb(52, 211, 153), dp(14))
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
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            background = rounded(Color.rgb(30, 41, 59), dp(14), Color.rgb(51, 65, 85))
            setOnClickListener {
                syncAmountFromInput()
                sendBroadcast(
                    Intent(ControlService.ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "check")
                        .putExtra("amount", amount)
                )
            }
        }
        actions.addView(runButton, LinearLayout.LayoutParams(0, dp(48), 1f))
        actions.addView(checkButton, LinearLayout.LayoutParams(0, dp(48), 1f).apply {
            leftMargin = dp(10)
        })
        card.addView(actions, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(10)
        })

        statusText = TextView(this).apply {
            text = status
            setTextColor(Color.rgb(203, 213, 225))
            textSize = 11f
            maxLines = 1
            gravity = Gravity.CENTER
        }
        card.addView(statusText, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(8)
        })

        root.addView(card, LinearLayout.LayoutParams(dp(280), LinearLayout.LayoutParams.WRAP_CONTENT))
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
            if (it.text.toString() != amount) {
                it.setText(amount)
                it.setSelection(it.text.length)
            }
        }
        runButton?.apply {
            text = if (isRunning) "Stop" else "Run"
            setTextColor(Color.rgb(8, 13, 23))
            background = rounded(if (isRunning) Color.rgb(248, 113, 113) else Color.rgb(52, 211, 153), dp(14))
        }
        statusText?.text = status
    }

    private fun collapseToEdge() {
        expanded = false
        val currentParams = params
        if (currentParams != null) {
            val screenWidth = resources.displayMetrics.widthPixels
            currentParams.x = if (currentParams.x > screenWidth / 2) {
                screenWidth - dp(72)
            } else {
                dp(8)
            }
            windowManager?.updateViewLayout(rootView, currentParams)
        }
        render()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun rounded(color: Int, radius: Int, strokeColor: Int? = null): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius.toFloat()
            if (strokeColor != null) setStroke(dp(1), strokeColor)
        }
    }

    private inner class DragTouchListener : View.OnTouchListener {
        private var startX = 0
        private var startY = 0
        private var touchX = 0f
        private var touchY = 0f
        private var dragging = false

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            val currentParams = params ?: return false
            when (event.action) {
                MotionEvent.ACTION_OUTSIDE -> {
                    if (expanded) collapseToEdge()
                    return false
                }
                MotionEvent.ACTION_DOWN -> {
                    startX = currentParams.x
                    startY = currentParams.y
                    touchX = event.rawX
                    touchY = event.rawY
                    dragging = false
                    return false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - touchX).toInt()
                    val dy = (event.rawY - touchY).toInt()
                    if (abs(dx) + abs(dy) < dp(8)) return false
                    currentParams.x = startX + dx
                    currentParams.y = (startY + dy).coerceAtLeast(dp(8))
                    windowManager?.updateViewLayout(view, currentParams)
                    dragging = true
                    return true
                }
                MotionEvent.ACTION_UP -> {
                    if (dragging && !expanded) collapseToEdge()
                    return dragging
                }
            }
            return false
        }
    }
}
