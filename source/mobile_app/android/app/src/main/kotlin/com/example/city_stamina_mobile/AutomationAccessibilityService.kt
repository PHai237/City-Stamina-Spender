package com.example.city_stamina_mobile

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent

class AutomationAccessibilityService : AccessibilityService() {
    companion object {
        private const val RECENT_EXTERNAL_PACKAGE_MS = 10 * 60 * 1000L

        @Volatile
        var lastPackageName: String = ""

        @Volatile
        var lastExternalPackageName: String = ""

        @Volatile
        var lastExternalPackageSeenAt: Long = 0L

        @Volatile
        var isConnected: Boolean = false

        @Volatile
        private var instance: AutomationAccessibilityService? = null

        fun tap(x: Float, y: Float): Boolean {
            val service = instance ?: return false
            val path = Path().apply { moveTo(x, y) }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 70))
                .build()
            return service.dispatchGesture(gesture, null, null)
        }

        fun swipe(startX: Float, startY: Float, endX: Float, endY: Float, durationMs: Long): Boolean {
            val service = instance ?: return false
            val path = Path().apply {
                moveTo(startX, startY)
                lineTo(endX, endY)
            }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs.coerceAtLeast(120)))
                .build()
            return service.dispatchGesture(gesture, null, null)
        }

        fun bestForegroundPackage(appPackageName: String): String {
            val service = instance
            val windowPackage = service?.windows
                ?.asSequence()
                ?.filter { it.isActive || it.isFocused }
                ?.mapNotNull { it.root?.packageName?.toString() }
                ?.firstOrNull { it.isNotBlank() && it != appPackageName }
            if (!windowPackage.isNullOrBlank()) {
                return windowPackage
            }

            if (lastPackageName.isNotBlank() && lastPackageName != appPackageName) {
                return lastPackageName
            }

            val externalAge = SystemClock.elapsedRealtime() - lastExternalPackageSeenAt
            if (lastExternalPackageName.isNotBlank() && externalAge <= RECENT_EXTERNAL_PACKAGE_MS) {
                return lastExternalPackageName
            }

            return lastPackageName
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        isConnected = true
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val packageName = event?.packageName?.toString() ?: return
        lastPackageName = packageName
        if (packageName != this.packageName) {
            lastExternalPackageName = packageName
            lastExternalPackageSeenAt = SystemClock.elapsedRealtime()
        }
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        isConnected = false
        super.onDestroy()
    }
}
