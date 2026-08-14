package com.example.city_stamina_mobile

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Point
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
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
    private var statusVersion = 0
    private val handler = Handler(Looper.getMainLooper())

    private val bg = Color.rgb(10, 13, 22)
    private val bubbleBg = Color.rgb(18, 24, 38)
    private val panelBg = Color.rgb(17, 22, 34)
    private val inputBg = Color.rgb(12, 16, 26)
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
    private val trayWidthDp = 276
    private val bubbleSizeDp = 46

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
                statusVersion += 1
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
            floatingFlags(),
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
            val saved = loadPosition()
            x = saved?.first ?: dp(14)
            y = saved?.second ?: dp(120)
            clampPosition(this)
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
        hideKeyboard()
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
        resizeFloatingWindow()
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
            text = if (isRunning) "RUN" else "CS"
            gravity = Gravity.CENTER
            textSize = if (isRunning) 10f else 12f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(if (isRunning) mint else sub)
            background = oval(if (isRunning) mintDim else Color.argb(10, 255, 255, 255), if (isRunning) mintBorder else border)
        }, FrameLayout.LayoutParams(dp(30), dp(30), Gravity.CENTER))
        if (isRunning) {
            bubble.addView(View(this).apply {
                background = oval(mint, bg)
            }, FrameLayout.LayoutParams(dp(8), dp(8), Gravity.TOP or Gravity.END).apply {
                topMargin = dp(5)
                rightMargin = dp(5)
            })
        }
        root.addView(bubble, LinearLayout.LayoutParams(dp(bubbleSizeDp), dp(bubbleSizeDp)))
    }

    private fun renderMenu(root: LinearLayout) {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(panelBg, dp(8), border)
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(8), dp(8), dp(8))
            background = rounded(Color.argb(8, 255, 255, 255), dp(8))
            setOnTouchListener(DragTouchListener())
        }
        header.addView(TextView(this).apply {
            text = "CS"
            gravity = Gravity.CENTER
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(mint)
            background = rounded(mintDim, dp(6), mintBorder)
        }, LinearLayout.LayoutParams(dp(26), dp(22)).apply {
            rightMargin = dp(8)
        })
        header.addView(TextView(this).apply {
            text = "Owner 1-1"
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(fg)
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(TextView(this).apply {
            text = "Hide"
            gravity = Gravity.CENTER
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(sub)
            background = rounded(Color.argb(13, 255, 255, 255), dp(6), border)
            setOnClickListener { collapseToEdge() }
        }, LinearLayout.LayoutParams(dp(42), dp(26)).apply {
            rightMargin = dp(4)
        })
        header.addView(TextView(this).apply {
            text = "X"
            gravity = Gravity.CENTER
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(coral)
            background = rounded(coralDim, dp(6), coralBorder)
            setOnClickListener {
                removeFloatingView()
                stopSelf()
            }
        }, LinearLayout.LayoutParams(dp(26), dp(26)))
        card.addView(header, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), dp(10), dp(10), dp(10))
        }

        statusText = TextView(this).apply {
            text = status
            setTextColor(statusColor(status))
            textSize = 11f
            typeface = Typeface.MONOSPACE
            maxLines = 1
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(statusBackground(status), dp(6), border)
            setPadding(dp(10), dp(7), dp(10), dp(7))
        }
        body.addView(statusText, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(30)))

        val primaryRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        amountInput = EditText(this).apply {
            hint = "Amount"
            setHintTextColor(muted)
            setTextColor(fg)
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setSingleLine(true)
            imeOptions = EditorInfo.IME_ACTION_DONE
            minWidth = 0
            setText(amount)
            setPadding(dp(10), 0, dp(10), 0)
            background = rounded(inputBg, dp(6), border)
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE) {
                    syncAmountFromInput()
                    hideKeyboard()
                    clearFocus()
                    true
                } else {
                    false
                }
            }
            setOnClickListener {
                requestFocus()
                showKeyboard(this)
            }
            setOnFocusChangeListener { view, hasFocus ->
                if (hasFocus) showKeyboard(view)
            }
        }
        primaryRow.addView(amountInput, LinearLayout.LayoutParams(0, dp(44), 1f))

        val secondaryRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        runButton = Button(this).apply {
            text = if (isRunning) "Stop" else "Run"
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            setSingleLine(true)
            setTextColor(if (isRunning) coral else mint)
            background = rounded(if (isRunning) coralDim else mintDim, dp(6), if (isRunning) coralBorder else mintBorder)
            setOnClickListener {
                syncAmountFromInput()
                hideKeyboard()
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
        primaryRow.addView(runButton, LinearLayout.LayoutParams(dp(86), dp(44)).apply {
            leftMargin = dp(8)
        })
        body.addView(primaryRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(8)
        })

        val gameButton = trayButton("Game", sub).apply {
            setOnClickListener {
                syncAmountFromInput()
                hideKeyboard()
                status = "Checking app"
                statusVersion += 1
                updateUi()
                checkActiveAppFromFloating()
                sendBroadcast(
                    Intent(ControlService.ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "game_check")
                        .putExtra("amount", amount)
                )
            }
        }
        val stageButton = trayButton("Stage", sub).apply {
            setOnClickListener {
                syncAmountFromInput()
                hideKeyboard()
                status = "Checking stage"
                statusVersion += 1
                val waitingVersion = statusVersion
                updateUi()
                startService(
                    Intent(this@FloatingControlService, ControlService::class.java)
                        .setAction(ControlService.ACTION_SET_STATUS)
                        .putExtra(ControlService.KEY_STATUS, status)
                )
                sendBroadcast(
                    Intent(ControlService.ACTION_TOGGLE_REQUEST)
                        .putExtra("type", "stage_check")
                        .putExtra("stage", "1-1")
                        .putExtra("amount", amount)
                )
                handler.postDelayed({
                    if (expanded && status == "Checking stage" && statusVersion == waitingVersion) {
                        status = "Open NTE"
                        statusVersion += 1
                        updateUi()
                        startService(
                            Intent(this@FloatingControlService, ControlService::class.java)
                                .setAction(ControlService.ACTION_SET_STATUS)
                                .putExtra(ControlService.KEY_STATUS, status)
                        )
                    }
                }, 6000)
            }
        }
        secondaryRow.addView(gameButton, LinearLayout.LayoutParams(0, dp(38), 1f))
        secondaryRow.addView(stageButton, LinearLayout.LayoutParams(0, dp(38), 1f).apply {
            leftMargin = dp(8)
        })
        body.addView(secondaryRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(8)
        })
        card.addView(body, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        root.addView(card, LinearLayout.LayoutParams(dp(trayWidthDp), LinearLayout.LayoutParams.WRAP_CONTENT))
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
            background = rounded(if (isRunning) coralDim else mintDim, dp(6), if (isRunning) coralBorder else mintBorder)
        }
        statusText?.apply {
            text = status
            setTextColor(statusColor(status))
            background = rounded(statusBackground(status), dp(6), border)
        }
    }

    private fun resizeFloatingWindow() {
        val currentParams = params ?: return
        currentParams.flags = floatingFlags()
        currentParams.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
        currentParams.width = if (expanded) dp(trayWidthDp) else dp(bubbleSizeDp)
        currentParams.height = WindowManager.LayoutParams.WRAP_CONTENT
        if (!expanded) currentParams.height = dp(bubbleSizeDp)
        clampPosition(currentParams)
        updateFloatingLayout()
    }

    private fun checkActiveAppFromFloating() {
        val activePackage = AutomationAccessibilityService.bestForegroundPackage(packageName)
        statusVersion += 1
        status = when {
            !AutomationAccessibilityService.isConnected -> "Enable Access"
            activePackage.isBlank() -> "No app"
            activePackage == packageName -> "Open NTE"
            looksLikeGamePackage(activePackage) -> "NTE ready"
            else -> "App: $activePackage"
        }
        updateUi()
        startService(
            Intent(this, ControlService::class.java)
                .setAction(ControlService.ACTION_SET_STATUS)
                .putExtra(ControlService.KEY_STATUS, status)
        )
    }

    private fun looksLikeGamePackage(packageName: String): Boolean {
        val normalized = packageName.lowercase()
        return normalized.contains("nte") ||
            normalized.contains("nevernes") ||
            normalized.contains("netease")
    }

    private fun collapseToEdge() {
        hideKeyboard()
        expanded = false
        val currentParams = params
        if (currentParams != null) {
            val (screenWidth, _) = screenSize()
            currentParams.x = if (currentParams.x > screenWidth / 2) {
                screenWidth - dp(bubbleSizeDp + 18)
            } else {
                dp(8)
            }
            clampPosition(currentParams)
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

    private fun floatingFlags(): Int {
        val base = WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH
        return if (expanded) {
            base
        } else {
            base or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        }
    }

    private fun showKeyboard(view: View) {
        view.post {
            val inputManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            inputManager.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
        }
    }

    private fun hideKeyboard() {
        val view = amountInput ?: rootView ?: return
        val inputManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        inputManager.hideSoftInputFromWindow(view.windowToken, 0)
        amountInput?.clearFocus()
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

    private fun clampPosition(currentParams: WindowManager.LayoutParams) {
        val (screenWidth, screenHeight) = screenSize()
        val viewWidth = rootView?.width?.takeIf { it > 0 } ?: if (expanded) dp(trayWidthDp) else dp(bubbleSizeDp)
        val viewHeight = rootView?.height?.takeIf { it > 0 } ?: if (expanded) dp(166) else dp(bubbleSizeDp)
        val bottomGestureReserve = if (screenHeight > screenWidth) dp(132) else dp(56)
        val maxX = (screenWidth - viewWidth - dp(8)).coerceAtLeast(dp(8))
        val maxY = (screenHeight - viewHeight - bottomGestureReserve).coerceAtLeast(dp(8))
        currentParams.x = currentParams.x.coerceIn(dp(8), maxX)
        currentParams.y = currentParams.y.coerceIn(dp(8), maxY)
    }

    private fun screenSize(): Pair<Int, Int> {
        val manager = windowManager ?: getSystemService(WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = manager.currentWindowMetrics.bounds
            bounds.width() to bounds.height()
        } else {
            @Suppress("DEPRECATION")
            val display = manager.defaultDisplay
            val point = Point()
            @Suppress("DEPRECATION")
            display.getRealSize(point)
            point.x to point.y
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun trayButton(label: String, color: Int): Button {
        return Button(this).apply {
            text = label
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            minWidth = 0
            minHeight = 0
            includeFontPadding = false
            setSingleLine(true)
            setTextColor(color)
            background = rounded(Color.argb(10, 255, 255, 255), dp(6), border)
        }
    }

    private fun statusColor(value: String): Int {
        val normalized = value.lowercase()
        return when {
            normalized.contains("ready") || normalized.contains("stage 1-1") || normalized.contains("nte ready") -> mint
            normalized.contains("stop") || normalized.contains("open") || normalized.contains("wrong") || normalized.contains("failed") || normalized.contains("access") -> coral
            normalized.contains("check") || normalized.contains("scroll") || normalized.contains("running") -> fg
            else -> sub
        }
    }

    private fun statusBackground(value: String): Int {
        val normalized = value.lowercase()
        return when {
            normalized.contains("ready") || normalized.contains("stage 1-1") || normalized.contains("nte ready") -> mintDim
            normalized.contains("stop") || normalized.contains("open") || normalized.contains("wrong") || normalized.contains("failed") || normalized.contains("access") -> coralDim
            else -> Color.argb(10, 255, 255, 255)
        }
    }

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
                    currentParams.y = startY + dy
                    clampPosition(currentParams)
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
