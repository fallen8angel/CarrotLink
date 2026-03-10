package com.example.carrot_pilot_manager

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  companion object {
    private const val TAG = "CarrotOverlayBridge"
    private const val OAUTH_NOTIFICATION_CHANNEL_ID = "github_oauth_code"
    private const val OAUTH_NOTIFICATION_ID = 9041
  }

  private val overlayChannelName = "carrotlink/overlay_hud"
  private val oauthChannelName = "carrotlink/github_oauth_ui"
  private val displayTuningChannelName = "carrotlink/display_tuning"
  private var nativeDriveVideoPlugin: NativeDriveVideoPlugin? = null
  private var oauthCodeHudView: View? = null
  private var oauthCodeHudParams: WindowManager.LayoutParams? = null
  private val launchAtMs = SystemClock.elapsedRealtime()

  override fun onCreate(savedInstanceState: Bundle?) {
    Log.i(TAG, "onCreate +${elapsedSinceLaunch()}ms savedState=${savedInstanceState != null}")
    super.onCreate(savedInstanceState)
  }

  override fun onStart() {
    Log.i(TAG, "onStart +${elapsedSinceLaunch()}ms")
    super.onStart()
  }

  override fun onResume() {
    Log.i(TAG, "onResume +${elapsedSinceLaunch()}ms")
    super.onResume()
  }

  override fun onNewIntent(intent: Intent) {
    Log.i(TAG, "onNewIntent +${elapsedSinceLaunch()}ms action=${intent.action}")
    super.onNewIntent(intent)
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    Log.i(TAG, "configureFlutterEngine:start +${elapsedSinceLaunch()}ms")
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.renderer.addIsDisplayingFlutterUiListener(object : FlutterUiDisplayListener {
      override fun onFlutterUiDisplayed() {
        Log.i(TAG, "firstFlutterFrame +${elapsedSinceLaunch()}ms")
        flutterEngine.renderer.removeIsDisplayingFlutterUiListener(this)
      }

      override fun onFlutterUiNoLongerDisplayed() {
        Log.i(TAG, "flutterUiHidden +${elapsedSinceLaunch()}ms")
      }
    })
    if (nativeDriveVideoPlugin == null) {
      nativeDriveVideoPlugin = NativeDriveVideoPlugin(flutterEngine.dartExecutor.binaryMessenger)
      nativeDriveVideoPlugin?.register(this, flutterEngine.platformViewsController.registry)
    }
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
              val snapshotJson = call.argument<String>("snapshotJson")?.trim()
              if (!hasOverlayPermission()) {
                result.success(false)
                return@setMethodCallHandler
              }
              startOverlayService(
                  OverlayHudService.ACTION_START,
                  host,
                  snapshotJson = snapshotJson
              )
              result.success(true)
            }

            "updateEndpoint" -> {
              val host = call.argument<String>("host")?.trim().orEmpty()
              val snapshotJson = call.argument<String>("snapshotJson")?.trim()
              if (host.isNotEmpty()) {
                startOverlayService(
                    OverlayHudService.ACTION_UPDATE_ENDPOINT,
                    host,
                    snapshotJson = snapshotJson
                )
              }
              result.success(true)
            }

            "updateSemanticSnapshot" -> {
              if (!OverlayHudService.isRunning()) {
                result.success(false)
                return@setMethodCallHandler
              }
              val snapshotJson = call.argument<String>("snapshotJson")?.trim().orEmpty()
              if (snapshotJson.isBlank()) {
                result.success(false)
                return@setMethodCallHandler
              }
              startOverlayService(
                  OverlayHudService.ACTION_UPDATE_SNAPSHOT,
                  null,
                  snapshotJson = snapshotJson
              )
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
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, oauthChannelName)
        .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
          when (call.method) {
            "showCodeNotification" -> {
              val code = call.argument<String>("code")?.trim().orEmpty()
              val url = call.argument<String>("url")?.trim().orEmpty()
              showOAuthCodeNotification(code, url)
              result.success(true)
            }

            "cancelCodeNotification" -> {
              cancelOAuthCodeNotification()
              result.success(true)
            }

            "hasOverlayPermission" -> result.success(hasOverlayPermission())
            "requestOverlayPermission" -> {
              requestOverlayPermission()
              result.success(true)
            }

            "showCodeHud" -> {
              val code = call.argument<String>("code")?.trim().orEmpty()
              result.success(showOAuthCodeHud(code))
            }

            "hideCodeHud" -> {
              hideOAuthCodeHud()
              result.success(true)
            }

            "bringAppToFront" -> result.success(bringAppToFront())

            else -> result.notImplemented()
          }
        }
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, displayTuningChannelName)
        .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
          when (call.method) {
            "setHighRefreshPreferred" -> {
              val enabled = call.argument<Boolean>("enabled") ?: true
              result.success(setHighRefreshPreferred(enabled))
            }

            "getDisplayRefreshInfo" -> result.success(getDisplayRefreshInfo())
            else -> result.notImplemented()
          }
        }
    stopLegacyOverlayService()
    Log.i(TAG, "configureFlutterEngine:end +${elapsedSinceLaunch()}ms")
  }

  override fun onDestroy() {
    hideOAuthCodeHud()
    cancelOAuthCodeNotification()
    super.onDestroy()
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

  private fun showOAuthCodeNotification(code: String, url: String) {
    if (code.isBlank()) return
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      if (nm.getNotificationChannel(OAUTH_NOTIFICATION_CHANNEL_ID) == null) {
        val channel = NotificationChannel(
            OAUTH_NOTIFICATION_CHANNEL_ID,
            "GitHub OAuth Code",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
          description = "GitHub 디바이스 로그인 인증 코드 표시"
          setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
      }
    }

    val openIntent = if (url.isBlank()) {
      packageManager.getLaunchIntentForPackage(packageName)
    } else {
      Intent(Intent.ACTION_VIEW, Uri.parse(url))
    }?.apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }

    val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    } else {
      PendingIntent.FLAG_UPDATE_CURRENT
    }
    val pendingIntent = openIntent?.let {
      PendingIntent.getActivity(this, 9041, it, pendingFlags)
    }

    val notification = NotificationCompat.Builder(this, OAUTH_NOTIFICATION_CHANNEL_ID)
        .setSmallIcon(R.mipmap.launcher_icon)
        .setContentTitle("GitHub 인증 코드")
        .setContentText(code)
        .setStyle(
            NotificationCompat.BigTextStyle().bigText(
                "인증 코드: $code\n알림을 눌러 브라우저 열기"
            )
        )
        .setOnlyAlertOnce(true)
        .setOngoing(true)
        .setAutoCancel(false)
        .setPriority(NotificationCompat.PRIORITY_HIGH)
        .setContentIntent(pendingIntent)
        .build()

    nm.notify(OAUTH_NOTIFICATION_ID, notification)
  }

  private fun cancelOAuthCodeNotification() {
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    nm.cancel(OAUTH_NOTIFICATION_ID)
  }

  private fun showOAuthCodeHud(code: String): Boolean {
    if (code.isBlank()) return false
    if (!hasOverlayPermission()) return false

    val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return false

    val existing = oauthCodeHudView as? TextView
    if (existing != null) {
      existing.text = "GitHub 코드  $code"
      return true
    }

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
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT
    ).apply {
      gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
      y = (resources.displayMetrics.density * 72f).toInt()
    }

    val view = TextView(this).apply {
      text = "GitHub 코드  $code"
      setTextColor(Color.WHITE)
      textSize = 14f
      setTypeface(typeface, Typeface.BOLD)
      setPadding(dp(14), dp(8), dp(14), dp(8))
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(18f)
        setColor(Color.parseColor("#D9181C22"))
        setStroke(dp(1), Color.parseColor("#88FFFFFF"))
      }

      var startX = 0
      var startY = 0
      var downX = 0f
      var downY = 0f

      setOnTouchListener { _, event ->
        when (event.actionMasked) {
          MotionEvent.ACTION_DOWN -> {
            startX = params.x
            startY = params.y
            downX = event.rawX
            downY = event.rawY
            true
          }

          MotionEvent.ACTION_MOVE -> {
            val dx = (event.rawX - downX).toInt()
            val dy = (event.rawY - downY).toInt()
            params.x = startX + dx
            params.y = startY + dy
            try {
              wm.updateViewLayout(this, params)
            } catch (_: Throwable) {
            }
            true
          }

          else -> false
        }
      }
    }

    return try {
      wm.addView(view, params)
      oauthCodeHudView = view
      oauthCodeHudParams = params
      true
    } catch (e: Throwable) {
      Log.w(TAG, "Failed to show OAuth HUD", e)
      false
    }
  }

  private fun hideOAuthCodeHud() {
    val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
    val view = oauthCodeHudView ?: return
    try {
      wm.removeView(view)
    } catch (_: Throwable) {
    }
    oauthCodeHudView = null
    oauthCodeHudParams = null
  }

  private fun bringAppToFront(): Boolean {
    return try {
      var moved = false
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val task = am?.appTasks?.firstOrNull()
        if (task != null) {
          try {
            task.moveToFront()
            moved = true
          } catch (e: Throwable) {
            Log.w(TAG, "moveToFront failed", e)
          }
        }
      }

      val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
      if (launchIntent != null) {
        launchIntent.action = Intent.ACTION_MAIN
        launchIntent.addCategory(Intent.CATEGORY_LAUNCHER)
        launchIntent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        )
        startActivity(launchIntent)
        moved = true
      }
      moved
    } catch (e: Throwable) {
      Log.w(TAG, "Failed to bring app to front", e)
      false
    }
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).toInt()
  }

  private fun dpF(value: Float): Float {
    val density = resources.displayMetrics.density
    return value * density
  }

  private fun getDisplayRefreshInfo(): Map<String, Any> {
    val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      this.display
    } else {
      @Suppress("DEPRECATION")
      windowManager.defaultDisplay
    }
    val currentRate = display?.refreshRate?.toDouble() ?: 60.0
    val maxRate = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      val modes = display?.supportedModes ?: emptyArray()
      var maxHz = currentRate
      for (mode in modes) {
        if (mode.refreshRate.toDouble() > maxHz) {
          maxHz = mode.refreshRate.toDouble()
        }
      }
      maxHz
    } else {
      currentRate
    }
    return mapOf(
        "ok" to true,
        "currentRefreshRate" to currentRate,
        "maxRefreshRate" to maxRate
    )
  }

  private fun setHighRefreshPreferred(enabled: Boolean): Map<String, Any> {
    return try {
      val attrs = window.attributes
      val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        this.display
      } else {
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay
      }

      var targetModeId = 0
      var targetRate = display?.refreshRate ?: 60f
      if (enabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        val modes = display?.supportedModes ?: emptyArray()
        for (mode in modes) {
          if (mode.refreshRate > targetRate + 0.01f) {
            targetRate = mode.refreshRate
            targetModeId = mode.modeId
          }
        }
      }

      if (enabled) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && targetModeId > 0) {
          attrs.preferredDisplayModeId = targetModeId
        }
        attrs.preferredRefreshRate = targetRate
      } else {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          attrs.preferredDisplayModeId = 0
        }
        attrs.preferredRefreshRate = 0f
      }
      window.attributes = attrs

      mapOf(
          "ok" to true,
          "enabled" to enabled,
          "refreshRate" to attrs.preferredRefreshRate.toDouble(),
          "modeId" to targetModeId
      )
    } catch (t: Throwable) {
      Log.w(TAG, "setHighRefreshPreferred failed", t)
      mapOf(
          "ok" to false,
          "enabled" to enabled,
          "error" to (t.message ?: "unknown")
      )
    }
  }

  private fun startOverlayService(
      action: String,
      host: String?,
      snapshotJson: String? = null
  ) {
    val intent = Intent(this, OverlayHudService::class.java).apply {
      this.action = action
      if (!host.isNullOrBlank()) {
        putExtra(OverlayHudService.EXTRA_HOST, host)
      }
      if (!snapshotJson.isNullOrBlank()) {
        putExtra(OverlayHudService.EXTRA_SNAPSHOT_JSON, snapshotJson)
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

  private fun stopLegacyOverlayService() {
    try {
      stopService(Intent(this, OverlayHudService::class.java))
    } catch (e: Throwable) {
      Log.w(TAG, "Failed to stop legacy overlay service", e)
    }
  }

  private fun elapsedSinceLaunch(): Long = SystemClock.elapsedRealtime() - launchAtMs
}
