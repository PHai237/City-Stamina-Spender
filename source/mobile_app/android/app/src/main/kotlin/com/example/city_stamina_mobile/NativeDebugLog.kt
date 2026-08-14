package com.example.city_stamina_mobile

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object NativeDebugLog {
    private const val MAX_BYTES = 96 * 1024
    private const val KEEP_BYTES = 48 * 1024

    fun write(context: Context, message: String) {
        try {
            val dir = File(context.filesDir, "logs")
            dir.mkdirs()
            val file = File(dir, "native_debug.log")
            val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())
            file.appendText("$stamp [NATIVE] $message\n")
            trim(file)
        } catch (_: Exception) {
            // Native diagnostics must not interrupt automation.
        }
    }

    fun read(context: Context): String {
        return try {
            val file = File(File(context.filesDir, "logs"), "native_debug.log")
            if (file.exists()) file.readText() else ""
        } catch (_: Exception) {
            ""
        }
    }

    private fun trim(file: File) {
        if (!file.exists() || file.length() <= MAX_BYTES) return
        val bytes = file.readBytes()
        val keepStart = (bytes.size - KEEP_BYTES).coerceAtLeast(0)
        file.writeBytes(bytes.copyOfRange(keepStart, bytes.size))
    }
}
