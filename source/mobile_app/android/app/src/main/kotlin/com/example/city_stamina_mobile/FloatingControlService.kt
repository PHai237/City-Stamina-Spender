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
import android.widget.FrameLayout
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
        private const val PREFS_NAME = "city_stamina_floating"
        private const val KEY_POSITION_X = "position_x"
        private const val KEY_POSITION_Y = "position_y"
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

    private val bg = Color.rgb(11, 15, 26)
    private val bubbleBg = Color.rgb(21, 29, 46)
    private val panelBg = Color.rgb(20, 26, 40)
    private val inputBg = Color.rgb(17, 22, 36)
    private val border = Color.argb(24, 255, 255, 255)
    private val mint = Color.rgb(52, 211, 153)
    private val mintDim = Color.argb(31, 52, 211, 153)
    private val mintBorder = Color.argb(71, 52, 211, 153)
    private val coral = Color.rgb(240, 96, 96)
    private val coralDim = Color.argb(31, 240, 96, 96)
    private val coralBorder = Color.argb(71, 240, 96, 96)
    private val fg = Color.rgb(220, 230, 245)
    private val sub = Color.rgb(122, 138, 170)
    private val muted = Color.rgb(58, 69, 96)

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
            val saved = loadPosition()
            x = saved?.first ?: dp(14)
            y = saved?.second ?: dp(120)
        }

        rootView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setOnTouchListener { _, event ->
                if (event.action == MotionEvent.ACTION_OUTSIDE && expanded) {
                    collapseToEdge()
                    true
                } else {
                    false
                }
            }
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
        val bubble = FrameLayout(this).apply {
            background = oval(bubbleBg, border)
            setOnTouchListener(DragTouchListener(snapOnRelease = true) {
                expanded = true
                render()
            })
        }
        bubble.addView(TextView(this).apply {
            text = if (isRunning) "ON" else "S"
            gravity = Gravity.CENTER
            textSize = if (isRunning) 12f else 15f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(if (isRunning) mint else sub)
            background = oval(if (isRunning) mintDim else Color.argb(10, 255, 255, 255), if (isRunning) mintBorder else border)
        }, FrameLayout.LayoutParams(dp(32), dp(32), Gravity.CENTER))
        if (isRunning) {
            bubble.addView(View(this).apply {
                background = oval(mint, bg)
            }, FrameLayout.LayoutParams(dp(10), dp(10), Gravity.TOP or Gravity.END).apply {
                topMargin = dp(6)
                rightMargin = dp(6)
            })
        }
        root.addView(bubble, LinearLayout.LayoutParams(dp(54), dp(54)))
    }

    private fun renderMenu(root: LinearLayout) {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(panelBg, dp(20), border)
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(10), dp(10), dp(8))
            background = rounded(Color.argb(10, 255, 255, 255), dp(20))
            setOnTouchListener(DragTouchListener())
        }
        header.addView(TextView(this).apply {
            text = "S"
            gravity = Gravity.CENTER
            textSize = 11f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(mint)
            background = rounded(mintDim, dp(8), mintBorder)
        }, LinearLayout.LayoutParams(dp(22), dp(22)).apply {
            rightMargin = dp(7)
        })
        header.addView(TextView(this).apply {
            text = "City Stamina"
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(fg)
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(TextView(this).apply {
            text = "-"
            gravity = Gravity.CENTER
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(sub)
            background = rounded(Color.argb(13, 255, 255, 255), dp(8), border)
            setOnClickListener { collapseToEdge() }
        }, LinearLayout.LayoutParams(dp(26), dp(26)).apply {
            rightMargin = dp(4)
        })
        header.addView(TextView(this).apply {
            text = "X"
            gravity = Gravity.CENTER
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(coral)
            background = rounded(coralDim, dp(8), coralBorder)
            setOnClickListener {
                removeFloatingView()
                stopSelf()
            }
        }, LinearLayout.LayoutParams(dp(26), dp(26)))
        card.addView(header, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(12), dp(12), dp(14))
        }

        amountInput = EditText(this).apply {
            hint = "Amount"
            setHintTextColor(muted)
            setTextColor(fg)
            textSize = 20f
            typeface = Typeface.DEFAULT_BOLD
            setSingleLine(true)
            setText(amount)
            setPadding(dp(12), 0, dp(12), 0)
            background = rounded(inputBg, dp(12), border)
        }
        body.addView(TextView(this).apply {
            text = "STAMINA AMOUNT"
            textSize = 9f
            typeface = Typeface.MONOSPACE
            letterSpacing = 0.1f
            setTextColor(muted)
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        body.addView(amountInput, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(50)).apply {
            topMargin = dp(4)
        })

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        runButton = Button(this).apply {
            text = if (isRunning) "Stop" else "Run"
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(if (isRunning) coral else mint)
            background = rounded(if (isRunning) coralDim else mintDim, dp(12), if (isRunning) coralBorder else mintBorder)
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
            setTextColor(sub)
            background = rounded(Color.argb(10, 255, 255, 255), dp(12), border)
            setOnClickListener {
                syncAmountFromInput()
                sendBroadcast(
                    Intent(ControlService.ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "check")
                        .putExtra("amount", amount)
                )
            }
        }
        actions.addView(runButton, LinearLayout.LayoutParams(0, dp(46), 1f))
        actions.addView(checkButton, LinearLayout.LayoutParams(0, dp(46), 1f).apply {
            leftMargin = dp(10)
        })
        body.addView(actions, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(10)
        })

        statusText = TextView(this).apply {
            text = status
            setTextColor(sub)
            textSize = 11f
            typeface = Typeface.MONOSPACE
            maxLines = 1
            gravity = Gravity.CENTER
            background = rounded(Color.argb(6, 255, 255, 255), dp(9))
            setPadding(dp(10), dp(6), dp(10), dp(6))
        }
        body.addView(statusText, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(8)
        })
        card.addView(body, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        root.addView(card, LinearLayout.LayoutParams(dp(220), LinearLayout.LayoutParams.WRAP_CONTENT))
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
            setTextColor(if (isRunning) coral else mint)
            background = rounded(if (isRunning) coralDim else mintDim, dp(12), if (isRunning) coralBorder else mintBorder)
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
            updateFloatingLayout()
            savePosition(currentParams.x, currentParams.y)
        }
        render()
    }

    private fun updateFloatingLayout() {
        val view = rootView ?: return
        val currentParams = params ?: return
        windowManager?.updateViewLayout(view, currentParams)
    }

    private fun savePosition(x: Int, y: Int) {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putInt(KEY_POSITION_X, x)
            .putInt(KEY_POSITION_Y, y)
            .apply()
    }

    private fun loadPosition(): Pair<Int, Int>? {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        if (!prefs.contains(KEY_POSITION_X) || !prefs.contains(KEY_POSITION_Y)) return null
        return prefs.getInt(KEY_POSITION_X, dp(14)) to prefs.getInt(KEY_POSITION_Y, dp(120))
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun rounded(color: Int, radius: Int, strokeColor: Int? = null): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius.toFloat()
            if (strokeColor != null) setStroke(dp(1), strokeColor)
        }
    }

    private fun oval(color: Int, strokeColor: Int? = null): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(color)
            if (strokeColor != null) setStroke(dp(1), strokeColor)
        }
    }

    private inner class DragTouchListener(
        private val snapOnRelease: Boolean = false,
        private val clickAction: (() -> Unit)? = null
    ) : View.OnTouchListener {
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
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - touchX).toInt()
                    val dy = (event.rawY - touchY).toInt()
                    if (abs(dx) + abs(dy) < dp(8)) return true
                    currentParams.x = startX + dx
                    currentParams.y = (startY + dy).coerceAtLeast(dp(8))
                    updateFloatingLayout()
                    dragging = true
                    return true
                }
                MotionEvent.ACTION_UP -> {
                    if (dragging) {
                        if (snapOnRelease) collapseToEdge()
                        else savePosition(currentParams.x, currentParams.y)
                        return true
                    }
                    clickAction?.invoke()
                    view.performClick()
                    return true
                }
            }
            return false
        }
    }
}
