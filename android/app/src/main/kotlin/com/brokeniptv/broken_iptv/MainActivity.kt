package com.brokeniptv.broken_iptv

import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.brokeniptv/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> result.success(isRunningOnTv())
                "dialPhone" -> {
                    val number = call.argument<String>("number")
                    result.success(dialPhone(number))
                }
                "openWhatsApp" -> {
                    val number = call.argument<String>("number")
                    val text = call.argument<String>("text")
                    result.success(openWhatsApp(number, text))
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Opens the system dialer pre-filled with [number] (ACTION_DIAL needs no
    /// permission and never places the call without the user pressing dial).
    private fun dialPhone(number: String?): Boolean {
        if (number.isNullOrBlank()) return false
        return try {
            val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$number")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /// Opens a WhatsApp chat with [number] (E.164, no "+" or symbols) via the
    /// wa.me deep link, falling back to the browser link if WhatsApp handles it.
    private fun openWhatsApp(number: String?, text: String?): Boolean {
        if (number.isNullOrBlank()) return false
        return try {
            val encoded = if (text.isNullOrBlank()) "" else "?text=" + Uri.encode(text)
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/$number$encoded")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun isRunningOnTv(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val viaUiModeManager = uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        val viaConfiguration =
            (resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK) == Configuration.UI_MODE_TYPE_TELEVISION
        return viaUiModeManager || viaConfiguration
    }
}
