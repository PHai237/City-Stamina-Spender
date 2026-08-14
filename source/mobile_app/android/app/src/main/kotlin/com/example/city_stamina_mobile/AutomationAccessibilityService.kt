package com.example.city_stamina_mobile

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent

class AutomationAccessibilityService : AccessibilityService() {
    companion object {
        private const val RECENT_EXTERNAL_PACKAGE_MS = 10 * 60 * 1000L
        private const val RECENT_USEFUL_PACKAGE_MS = 2 * 60 * 1000L
        private const val MAX_PACKAGE_HISTORY = 18

        @Volatile
        var lastPackageName: String = ""

        @Volatile
        var lastExternalPackageName: String = ""

        @Volatile
        var lastExternalPackageSeenAt: Long = 0L

        @Volatile
        var lastUsefulPackageName: String = ""

        @Volatile
        var lastUsefulPackageSeenAt: Long = 0L

        @Volatile
        var isConnected: Boolean = false

        @Volatile
        private var instance: AutomationAccessibilityService? = null

        private val packageHistory = ArrayDeque<String>()

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
                ?.firstOrNull { it.isUsefulPackage(appPackageName) }
            if (!windowPackage.isNullOrBlank()) {
                return windowPackage
            }

            if (lastPackageName.isUsefulPackage(appPackageName)) {
                return lastPackageName
            }

            val usefulAge = SystemClock.elapsedRealtime() - lastUsefulPackageSeenAt
            if (lastUsefulPackageName.isNotBlank() && usefulAge <= RECENT_USEFUL_PACKAGE_MS) {
                return lastUsefulPackageName
            }

            val externalAge = SystemClock.elapsedRealtime() - lastExternalPackageSeenAt
            if (lastExternalPackageName.isNotBlank() && externalAge <= RECENT_EXTERNAL_PACKAGE_MS) {
                return lastExternalPackageName
            }

            return lastPackageName
        }

        fun debugSnapshot(appPackageName: String): Map<String, Any> {
            val history = synchronized(packageHistory) { packageHistory.toList() }
            return mapOf(
                "lastPackage" to lastPackageName,
                "lastExternalPackage" to lastExternalPackageName,
                "lastUsefulPackage" to lastUsefulPackageName,
                "bestForegroundPackage" to bestForegroundPackage(appPackageName),
                "packageHistory" to history
            )
        }

        private fun String?.isUsefulPackage(appPackageName: String): Boolean {
            if (isNullOrBlank()) return false
            if (this == appPackageName) return false
            val normalized = lowercase()
            return normalized != "android" &&
                normalized != "com.android.launcher" &&
                normalized != "com.google.android.apps.nexuslauncher" &&
                normalized != "com.oppo.launcher" &&
                normalized != "com.coloros.launcher" &&
                normalized != "com.android.systemui" &&
                normalized != "com.google.android.inputmethod.latin" &&
                !normalized.contains("launcher") &&
                !normalized.contains("inputmethod")
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        isConnected = true
        NativeDebugLog.write(this, "Accessibility connected.")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val packageName = event?.packageName?.toString() ?: return
        lastPackageName = packageName
        synchronized(packageHistory) {
            if (packageHistory.lastOrNull() != packageName) {
                packageHistory.addLast(packageName)
                while (packageHistory.size > MAX_PACKAGE_HISTORY) {
                    packageHistory.removeFirst()
                }
            }
        }
        if (packageName != this.packageName) {
            lastExternalPackageName = packageName
            lastExternalPackageSeenAt = SystemClock.elapsedRealtime()
        }
        if (packageName.isUsefulPackage(this.packageName)) {
            lastUsefulPackageName = packageName
            lastUsefulPackageSeenAt = SystemClock.elapsedRealtime()
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
