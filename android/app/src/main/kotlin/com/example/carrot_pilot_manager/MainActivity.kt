package com.example.carrot_pilot_manager

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  companion object {
    private const val TAG = "CarrotOverlayBridge"
  }

  private val overlayChannelName = "carrotlink/overlay_hud"

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, overlayChannelName)
        .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
          when (call.method) {
            "hasPermission" -> result.success(hasOverlayPermission())
            "requestPermission" -> {
              requestOverlayPermission()
              result.success(true)
            }

            "start" -> {
              val host = call.argument<String>("host")?.trim().orEmpty()
              if (!hasOverlayPermission()) {
                result.success(false)
                return@setMethodCallHandler
              }
              startOverlayService(OverlayHudService.ACTION_START, host)
              result.success(true)
            }

            "updateEndpoint" -> {
              val host = call.argument<String>("host")?.trim().orEmpty()
              if (host.isNotEmpty()) {
                startOverlayService(OverlayHudService.ACTION_UPDATE_ENDPOINT, host)
              }
              result.success(true)
            }

            "stop" -> {
              startOverlayService(OverlayHudService.ACTION_STOP, null)
              result.success(true)
            }

            "resetPosition" -> {
              startOverlayService(OverlayHudService.ACTION_RESET_POSITION, null)
              result.success(true)
            }

            "isRunning" -> result.success(OverlayHudService.isRunning())
            else -> result.notImplemented()
          }
        }
  }

  private fun hasOverlayPermission(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
    return Settings.canDrawOverlays(this)
  }

  private fun requestOverlayPermission() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    if (Settings.canDrawOverlays(this)) return
    val intent = Intent(
        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
        Uri.parse("package:$packageName")
    ).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    startActivity(intent)
  }

  private fun startOverlayService(action: String, host: String?) {
    val intent = Intent(this, OverlayHudService::class.java).apply {
      this.action = action
      if (!host.isNullOrBlank()) {
        putExtra(OverlayHudService.EXTRA_HOST, host)
      }
    }
    val useForegroundStart =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            action == OverlayHudService.ACTION_START &&
            !OverlayHudService.isRunning()
    try {
      if (useForegroundStart) {
        startForegroundService(intent)
      } else {
        startService(intent)
      }
    } catch (e: IllegalStateException) {
      // Fallback for rare background start timing races on Android O+.
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        Log.w(TAG, "Fallback startForegroundService for action=$action", e)
        startForegroundService(intent)
      } else {
        throw e
      }
    }
  }
}
