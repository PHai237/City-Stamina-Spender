package com.example.city_stamina_mobile

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

class AutomationAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var lastPackageName: String = ""
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        lastPackageName = event?.packageName?.toString() ?: lastPackageName
    }

    override fun onInterrupt() = Unit
}
