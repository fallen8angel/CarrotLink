package com.example.carrot_pilot_manager

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.roundToInt

class OverlayHudService : Service() {
  companion object {
    const val ACTION_START = "carrot.overlay.START"
    const val ACTION_STOP = "carrot.overlay.STOP"
    const val ACTION_UPDATE_ENDPOINT = "carrot.overlay.UPDATE_ENDPOINT"
    const val ACTION_RESET_POSITION = "carrot.overlay.RESET_POSITION"
    const val EXTRA_HOST = "extra_host"

    private const val NOTIFICATION_CHANNEL_ID = "carrot_overlay_hud"
    private const val NOTIFICATION_ID = 9021
    private const val PREFS_NAME = "carrot_hud_overlay_prefs"
    private const val PREF_X = "overlay_x"
    private const val PREF_Y = "overlay_y"
    private const val TAG = "CarrotHudOverlay"

    @Volatile
    private var running = false

    @JvmStatic
    fun isRunning(): Boolean = running
  }

  private val mainHandler = Handler(Looper.getMainLooper())

  private var windowManager: WindowManager? = null
  private var rootView: View? = null
  private var rootLayoutParams: WindowManager.LayoutParams? = null

  private var wsClient: OkHttpClient? = null
  private var webSocket: WebSocket? = null
  private var reconnectRunnable: Runnable? = null
  private var destroyed = false

  private var hostIp: String? = null
  private var lastMessageAt = 0L
  private var isSocketConnected = false

  private var metricCpuValue: TextView? = null
  private var metricMemValue: TextView? = null
  private var metricVoltLabel: TextView? = null
  private var metricVoltValue: TextView? = null

  private var speedValue: TextView? = null
  private var setSpeedValue: TextView? = null
  private var tempSourceValue: TextView? = null
  private var tempSpeedValue: TextView? = null
  private var gearValue: TextView? = null
  private var modeValue: TextView? = null
  private var limitValue: TextView? = null
  private var gpsValue: TextView? = null
  private var statusValue: TextView? = null
  private val tfBarViews = mutableListOf<View>()

  private var lastUiUpdateAt = 0L
  private var lastStatus = "대기 중"
  private var dragTouchSlop = 8
  private var lastBoundsCheckAt = 0L

  private val staleCheckRunnable = object : Runnable {
    override fun run() {
      if (destroyed) return
      val now = SystemClock.elapsedRealtime()
      if (now - lastBoundsCheckAt >= 1500) {
        lastBoundsCheckAt = now
        ensureOverlayInBounds(forceApply = false, persistIfChanged = true)
      }
      if (isSocketConnected) {
        val age = now - lastMessageAt
        if (age > 2500) {
          isSocketConnected = false
          updateStatusUi("데이터 지연, 재연결")
          updateNotification("데이터 지연, 재연결")
          scheduleReconnect()
        }
      }
      mainHandler.postDelayed(this, 1000)
    }
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    running = true
    destroyed = false
    windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    dragTouchSlop = ViewConfiguration.get(this).scaledTouchSlop
    createNotificationChannel()
    startForegroundCompat("대기 중")
    Log.i(TAG, "Service created")
    mainHandler.post(staleCheckRunnable)
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val action = intent?.action ?: ACTION_START
    Log.i(TAG, "onStartCommand action=$action startId=$startId host=${intent?.getStringExtra(EXTRA_HOST)}")
    when (action) {
      ACTION_STOP -> {
        stopSelf()
        return START_NOT_STICKY
      }

      ACTION_RESET_POSITION -> {
        if (!canDrawOverlay()) {
          updateStatusUi("오버레이 권한 필요")
          updateNotification("오버레이 권한 필요")
          return START_STICKY
        }
        if (rootView == null || rootLayoutParams == null) {
          return START_STICKY
        }
        resetOverlayPosition()
        if (!hostIp.isNullOrBlank()) {
          connectWebSocket(force = false)
        }
      }

      ACTION_START, ACTION_UPDATE_ENDPOINT -> {
        val nextHost = intent?.getStringExtra(EXTRA_HOST)?.trim().orEmpty()
        if (nextHost.isNotEmpty()) {
          hostIp = nextHost
        }

        if (!canDrawOverlay()) {
          updateStatusUi("오버레이 권한 필요")
          updateNotification("오버레이 권한 필요")
          return START_STICKY
        }

        attachOverlayIfNeeded()
        if (hostIp.isNullOrBlank()) {
          updateStatusUi("IP 미설정")
          updateNotification("IP 미설정")
          return START_STICKY
        }
        ensureOverlayInBounds(forceApply = false, persistIfChanged = true)
        connectWebSocket(force = true)
      }
    }
    return START_STICKY
  }

  override fun onDestroy() {
    Log.i(TAG, "Service destroying")
    destroyed = true
    running = false
    mainHandler.removeCallbacks(staleCheckRunnable)
    cancelReconnect()
    disconnectWebSocket(shutdownClient = true)
    detachOverlay()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
    super.onDestroy()
  }

  private fun canDrawOverlay(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
    return Settings.canDrawOverlays(this)
  }

  private fun connectWebSocket(force: Boolean) {
    if (destroyed) return
    val host = hostIp?.trim().orEmpty()
    if (host.isEmpty()) return
    if (!force && isSocketConnected && webSocket != null) return

    cancelReconnect()
    disconnectWebSocket(shutdownClient = false)

    if (wsClient == null) {
      wsClient = OkHttpClient.Builder()
          .pingInterval(20, TimeUnit.SECONDS)
          .retryOnConnectionFailure(true)
          .build()
    }

    updateStatusUi("연결 중")
    updateNotification("연결 중: $host")

    val request = Request.Builder()
        .url("ws://$host:7000/ws/carstate")
        .build()

    webSocket = wsClient?.newWebSocket(
        request,
        object : WebSocketListener() {
          override fun onOpen(webSocket: WebSocket, response: Response) {
            isSocketConnected = true
            lastMessageAt = SystemClock.elapsedRealtime()
            mainHandler.post {
              updateStatusUi("연결됨")
              updateNotification("연결됨: $host")
            }
          }

          override fun onMessage(webSocket: WebSocket, text: String) {
            val now = SystemClock.elapsedRealtime()
            if (now - lastUiUpdateAt < 100) return
            lastUiUpdateAt = now
            lastMessageAt = now
            applyPayloadText(text)
          }

          override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            isSocketConnected = false
            mainHandler.post {
              updateStatusUi("끊김, 재연결")
              updateNotification("끊김, 재연결")
            }
            scheduleReconnect()
          }

          override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            isSocketConnected = false
            mainHandler.post {
              updateStatusUi("연결 종료, 재시도")
              updateNotification("연결 종료, 재시도")
            }
            scheduleReconnect()
          }
        }
    )
  }

  private fun scheduleReconnect() {
    if (destroyed) return
    if (hostIp.isNullOrBlank()) return
    if (reconnectRunnable != null) return

    reconnectRunnable = Runnable {
      reconnectRunnable = null
      if (!destroyed) {
        connectWebSocket(force = true)
      }
    }
    mainHandler.postDelayed(reconnectRunnable!!, 2000)
  }

  private fun cancelReconnect() {
    reconnectRunnable?.let { mainHandler.removeCallbacks(it) }
    reconnectRunnable = null
  }

  private fun disconnectWebSocket(shutdownClient: Boolean) {
    try {
      webSocket?.cancel()
    } catch (_: Throwable) {
    }
    webSocket = null
    isSocketConnected = false

    if (shutdownClient) {
      wsClient?.dispatcher?.executorService?.shutdown()
      wsClient?.connectionPool?.evictAll()
      wsClient = null
    }
  }

  private fun attachOverlayIfNeeded() {
    if (rootView != null) {
      ensureOverlayInBounds(forceApply = true, persistIfChanged = true)
      return
    }
    val wm = windowManager ?: return

    val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
      @Suppress("DEPRECATION")
      val legacyType = WindowManager.LayoutParams.TYPE_PHONE
      legacyType
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
      gravity = Gravity.START or Gravity.TOP
      x = defaultOverlayX()
      y = defaultOverlayY()
    }

    val overlay = buildHudView()
    try {
      wm.addView(overlay, params)
      rootLayoutParams = params
      rootView = overlay
      restoreOverlayPosition(params)
      ensureOverlayInBounds(forceApply = true, persistIfChanged = true)
      overlay.post {
        ensureOverlayInBounds(forceApply = true, persistIfChanged = true)
        val size = currentOverlaySize()
        Log.i(TAG, "Overlay attached size=${size.first}x${size.second} x=${params.x} y=${params.y}")
      }
    } catch (_: Throwable) {
      updateStatusUi("오버레이 생성 실패")
      updateNotification("오버레이 생성 실패")
    }
  }

  private fun detachOverlay() {
    val wm = windowManager ?: return
    val view = rootView ?: return
    rootLayoutParams?.let { persistOverlayPosition(it) }
    Log.i(TAG, "Detaching overlay size=${view.width}x${view.height}")
    try {
      wm.removeView(view)
    } catch (_: Throwable) {
    }
    rootView = null
    rootLayoutParams = null
  }

  private fun buildHudView(): View {
    val card = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      minimumWidth = dp(260)
      minimumHeight = dp(180)
      setPadding(dp(10), dp(8), dp(10), dp(8))
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(14f)
        setColor(Color.parseColor("#D9010A18"))
        setStroke(dp(1), Color.parseColor("#66FFFFFF"))
      }
      elevation = dpF(6f)
    }

    val metricsRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    val cpuMetric = createMetricCell("CPU", "--°C")
    metricCpuValue = cpuMetric.second
    val memMetric = createMetricCell("MEM", "--%")
    metricMemValue = memMetric.second
    val voltMetric = createMetricCell("VOLT", "--.-V")
    metricVoltLabel = voltMetric.first.findViewWithTag("label")
    metricVoltValue = voltMetric.second

    metricsRow.addView(cpuMetric.first)
    metricsRow.addView(space(6))
    metricsRow.addView(memMetric.first)
    metricsRow.addView(space(6))
    metricsRow.addView(voltMetric.first)
    card.addView(metricsRow)
    card.addView(spaceVertical(8))

    val middleRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }

    speedValue = textView(46f, bold = true).apply {
      text = "--"
      setTextColor(Color.WHITE)
      minWidth = dp(88)
      gravity = Gravity.CENTER
    }
    middleRow.addView(speedValue)

    val rightColumn = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.START
    }
    tempSourceValue = textView(16f, bold = true).apply {
      text = "eco"
      setTextColor(Color.parseColor("#22FF61"))
    }
    tempSpeedValue = textView(22f, bold = true).apply {
      text = "--"
      setTextColor(Color.parseColor("#22FF61"))
    }
    setSpeedValue = textView(18f, bold = true).apply {
      text = "SET --"
      setTextColor(Color.parseColor("#22FF61"))
    }
    limitValue = textView(16f, bold = true).apply {
      text = "LIMIT --"
      setTextColor(Color.WHITE)
    }
    rightColumn.addView(tempSourceValue)
    rightColumn.addView(tempSpeedValue)
    rightColumn.addView(setSpeedValue)
    rightColumn.addView(limitValue)
    middleRow.addView(space(10))
    middleRow.addView(rightColumn)
    card.addView(middleRow)
    card.addView(spaceVertical(8))

    val bottomRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }

    gearValue = textView(22f, bold = true).apply {
      text = "U"
      setTextColor(Color.WHITE)
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(10f)
        setStroke(dp(1), Color.parseColor("#88FFFFFF"))
      }
      setPadding(dp(10), dp(2), dp(10), dp(2))
    }
    bottomRow.addView(gearValue)
    bottomRow.addView(space(8))

    gpsValue = textView(14f, bold = true).apply {
      text = "GPS --"
      setTextColor(Color.parseColor("#A0FFFFFF"))
    }
    bottomRow.addView(gpsValue)
    bottomRow.addView(space(8))

    modeValue = textView(14f, bold = true).apply {
      text = "Normal"
      setTextColor(Color.WHITE)
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(10f)
        setColor(Color.parseColor("#1E9A44"))
      }
      setPadding(dp(8), dp(4), dp(8), dp(4))
    }
    bottomRow.addView(modeValue)
    bottomRow.addView(space(8))

    val barWrap = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    repeat(4) { idx ->
      val bar = View(this).apply {
        this.layoutParams = LinearLayout.LayoutParams(dp(12), dp(8)).also {
          if (idx > 0) it.marginStart = dp(3)
        }
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = dpF(3f)
          setColor(Color.parseColor("#505862"))
        }
        alpha = 0.55f
      }
      tfBarViews.add(bar)
      barWrap.addView(bar)
    }
    bottomRow.addView(barWrap)
    card.addView(bottomRow)
    card.addView(spaceVertical(6))

    statusValue = textView(12f, bold = false).apply {
      text = "대기 중"
      setTextColor(Color.parseColor("#A0FFFFFF"))
    }
    card.addView(statusValue)

    card.setOnTouchListener(object : View.OnTouchListener {
      private var startX = 0
      private var startY = 0
      private var touchX = 0f
      private var touchY = 0f
      private var dragging = false

      override fun onTouch(v: View?, event: MotionEvent?): Boolean {
        val e = event ?: return false
        when (e.actionMasked) {
          MotionEvent.ACTION_DOWN -> {
            val p = rootLayoutParams ?: return false
            startX = p.x
            startY = p.y
            touchX = e.rawX
            touchY = e.rawY
            dragging = false
            return true
          }

          MotionEvent.ACTION_MOVE -> {
            val p = rootLayoutParams ?: return false
            val dx = (e.rawX - touchX).toInt()
            val dy = (e.rawY - touchY).toInt()
            if (!dragging && abs(dx) < dragTouchSlop && abs(dy) < dragTouchSlop) {
              return true
            }
            dragging = true
            p.x = startX + dx
            p.y = startY + dy
            val size = currentOverlaySize()
            clampOverlayPosition(p, size.first, size.second)
            try {
              windowManager?.updateViewLayout(rootView, p)
            } catch (_: Throwable) {
            }
            return true
          }

          MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
            val p = rootLayoutParams
            if (dragging && p != null) {
              persistOverlayPosition(p)
              ensureOverlayInBounds(forceApply = true, persistIfChanged = true)
            }
            dragging = false
            return true
          }
        }
        return false
      }
    })

    return card
  }

  private fun createMetricCell(label: String, value: String): Pair<LinearLayout, TextView> {
    val labelView = textView(10f, bold = true).apply {
      text = label
      tag = "label"
      setTextColor(Color.parseColor("#D8FFFFFF"))
      gravity = Gravity.CENTER_HORIZONTAL
    }
    val valueView = textView(13f, bold = true).apply {
      text = value
      setTextColor(Color.WHITE)
      gravity = Gravity.CENTER_HORIZONTAL
    }
    val cell = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      minimumWidth = dp(64)
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(8f)
        setColor(Color.parseColor("#1E9A44"))
      }
      setPadding(dp(8), dp(4), dp(8), dp(4))
      addView(labelView)
      addView(valueView)
    }
    return Pair(cell, valueView)
  }

  private fun textView(sizeSp: Float, bold: Boolean): TextView {
    return TextView(this).apply {
      textSize = sizeSp
      typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      includeFontPadding = false
    }
  }

  private fun space(widthDp: Int): View {
    return View(this).apply {
      layoutParams = LinearLayout.LayoutParams(dp(widthDp), 1)
    }
  }

  private fun spaceVertical(heightDp: Int): View {
    return View(this).apply {
      layoutParams = LinearLayout.LayoutParams(1, dp(heightDp))
    }
  }

  private fun defaultOverlayX(): Int = dp(10)

  private fun defaultOverlayY(): Int = dp(72)

  private fun prefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

  private fun persistOverlayPosition(params: WindowManager.LayoutParams) {
    try {
      prefs().edit()
          .putInt(PREF_X, params.x)
          .putInt(PREF_Y, params.y)
          .apply()
    } catch (_: Throwable) {
    }
  }

  private fun restoreOverlayPosition(params: WindowManager.LayoutParams) {
    try {
      val pref = prefs()
      params.x = pref.getInt(PREF_X, defaultOverlayX())
      params.y = pref.getInt(PREF_Y, defaultOverlayY())
    } catch (_: Throwable) {
      params.x = defaultOverlayX()
      params.y = defaultOverlayY()
    }
  }

  private fun resetOverlayPosition() {
    val params = rootLayoutParams ?: return
    params.x = defaultOverlayX()
    params.y = defaultOverlayY()
    ensureOverlayInBounds(forceApply = true, persistIfChanged = true)
    Log.i(TAG, "Overlay position reset to default")
  }

  private fun currentOverlaySize(): Pair<Int, Int> {
    val view = rootView
    if (view == null) return Pair(dp(260), dp(180))
    if (view.width <= 0 || view.height <= 0) {
      val spec = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
      view.measure(spec, spec)
      view.layout(0, 0, view.measuredWidth, view.measuredHeight)
    }
    var width = if (view.width > 0) view.width else view.measuredWidth
    var height = if (view.height > 0) view.height else view.measuredHeight
    if (width < dp(120) || height < dp(120)) {
      val bounds = screenBounds()
      val wSpec = View.MeasureSpec.makeMeasureSpec(
          (bounds.width() - dp(12)).coerceAtLeast(dp(120)),
          View.MeasureSpec.AT_MOST
      )
      val hSpec = View.MeasureSpec.makeMeasureSpec(
          (bounds.height() - dp(12)).coerceAtLeast(dp(120)),
          View.MeasureSpec.AT_MOST
      )
      view.measure(wSpec, hSpec)
      view.layout(0, 0, view.measuredWidth, view.measuredHeight)
      width = if (view.width > 0) view.width else view.measuredWidth
      height = if (view.height > 0) view.height else view.measuredHeight
    }
    return Pair(width.coerceAtLeast(dp(120)), height.coerceAtLeast(dp(120)))
  }

  private fun screenBounds(): Rect {
    val wm = windowManager
    if (wm == null) {
      val dm = resources.displayMetrics
      return Rect(0, 0, dm.widthPixels, dm.heightPixels)
    }
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      wm.currentWindowMetrics.bounds
    } else {
      val dm = resources.displayMetrics
      Rect(0, 0, dm.widthPixels, dm.heightPixels)
    }
  }

  private fun clampOverlayPosition(
      params: WindowManager.LayoutParams,
      viewWidth: Int,
      viewHeight: Int
  ): Boolean {
    val bounds = screenBounds()
    val safeMargin = dp(6)

    val minX = safeMargin
    val minY = safeMargin
    val maxX = (bounds.width() - viewWidth - safeMargin).coerceAtLeast(minX)
    val maxY = (bounds.height() - viewHeight - safeMargin).coerceAtLeast(minY)

    val clampedX = params.x.coerceIn(minX, maxX)
    val clampedY = params.y.coerceIn(minY, maxY)
    val changed = clampedX != params.x || clampedY != params.y
    if (changed) {
      params.x = clampedX
      params.y = clampedY
    }
    return changed
  }

  private fun ensureOverlayInBounds(forceApply: Boolean, persistIfChanged: Boolean) {
    val view = rootView ?: return
    val params = rootLayoutParams ?: return
    val (width, height) = currentOverlaySize()
    val changed = clampOverlayPosition(params, width, height)
    if (!changed && !forceApply) return
    try {
      windowManager?.updateViewLayout(view, params)
      if (persistIfChanged && (changed || forceApply)) {
        persistOverlayPosition(params)
      }
    } catch (_: Throwable) {
    }
  }

  private fun applyPayloadText(raw: String) {
    try {
      val obj = JSONObject(raw)
      val cpu = formatTemp(optDouble(obj, "cpuTempC"))
      val mem = formatPercent(optDouble(obj, "memPct"))
      val diskLabel = (obj.optString("diskLabel", "VOLT").ifBlank { "VOLT" }).uppercase(Locale.US)
      val diskRaw = optDouble(obj, "diskPct")
      val disk = if (diskLabel == "VOLT") {
        if (diskRaw == null) "--.-V" else String.format(Locale.US, "%.1fV", diskRaw)
      } else {
        if (diskRaw == null) "--%" else "${diskRaw.roundToInt()}%"
      }

      val speedKph = optDouble(obj, "vEgo")?.let { (it * 3.6).roundToInt().toString() } ?: "--"
      val vSet = optDouble(obj, "vSetKph")?.roundToInt()?.toString() ?: "--"
      val gear = obj.optString("gear", "U").ifBlank { "U" }
      val gpsOk = obj.optBoolean("gpsOk", false)
      val tfBars = obj.optInt("tfBars", obj.optInt("tfGap", 0)).coerceIn(0, 4)

      val driveMode = obj.optJSONObject("driveMode")
      val modeName = driveMode?.optString("name")?.takeIf { it.isNotBlank() } ?: "Normal"
      val modeKind = driveMode?.optString("kind")?.lowercase(Locale.US) ?: "normal"

      val tempObj = obj.optJSONObject("temp")
      val tempSource = tempObj?.optString("source")?.takeIf { it.isNotBlank() } ?: "eco"
      val tempSpeed = optDouble(tempObj, "speed")?.roundToInt()?.toString() ?: "--"
      val tempIsDecel = tempObj?.optBoolean("is_decel", false) ?: false

      val limit = optDouble(obj, "speedLimitKph")?.roundToInt()?.toString() ?: "--"
      val limitOver = obj.optBoolean("speedLimitOver", false)

      mainHandler.post {
        setTextIfChanged(metricCpuValue, cpu)
        setTextIfChanged(metricMemValue, mem)
        setTextIfChanged(metricVoltLabel, diskLabel)
        setTextIfChanged(metricVoltValue, disk)
        setTextIfChanged(speedValue, speedKph)
        setTextIfChanged(setSpeedValue, "SET $vSet")
        setTextIfChanged(gearValue, gear)
        setTextIfChanged(gpsValue, if (gpsOk) "GPS OK" else "GPS --")
        setTextIfChanged(tempSourceValue, tempSource)
        setTextIfChanged(tempSpeedValue, tempSpeed)
        setTextIfChanged(limitValue, "LIMIT $limit")
        setTextIfChanged(modeValue, modeName)
        setTextIfChanged(statusValue, "연결됨 · $hostIp")

        tempSpeedValue?.setTextColor(
            if (tempIsDecel) Color.parseColor("#FF9C2A") else Color.parseColor("#22FF61")
        )
        limitValue?.setTextColor(if (limitOver) Color.parseColor("#FF5050") else Color.WHITE)
        gpsValue?.setTextColor(if (gpsOk) Color.WHITE else Color.parseColor("#A0FFFFFF"))
        applyDriveModeStyle(modeKind)
        applyTfBars(tfBars)
      }
    } catch (_: Throwable) {
    }
  }

  private fun applyDriveModeStyle(kind: String) {
    val bg = modeValue?.background as? GradientDrawable ?: return
    when (kind) {
      "eco" -> {
        bg.setColor(Color.parseColor("#10C248"))
        modeValue?.setTextColor(Color.WHITE)
      }

      "safe" -> {
        bg.setColor(Color.parseColor("#FF9C2A"))
        modeValue?.setTextColor(Color.parseColor("#1A1F26"))
      }

      "sport" -> {
        bg.setColor(Color.parseColor("#FF2A2A"))
        modeValue?.setTextColor(Color.WHITE)
      }

      else -> {
        bg.setColor(Color.parseColor("#E7EEF7"))
        modeValue?.setTextColor(Color.parseColor("#1A1F26"))
      }
    }
  }

  private fun applyTfBars(activeBars: Int) {
    tfBarViews.forEachIndexed { index, view ->
      val on = index >= (4 - activeBars)
      val bg = view.background as? GradientDrawable ?: return@forEachIndexed
      bg.setColor(if (on) Color.parseColor("#1CFF57") else Color.parseColor("#505862"))
      view.alpha = if (on) 1.0f else 0.55f
    }
  }

  private fun updateStatusUi(status: String) {
    mainHandler.post {
      setTextIfChanged(statusValue, status)
      lastStatus = status
    }
  }

  private fun setTextIfChanged(view: TextView?, text: String) {
    if (view == null) return
    if (view.text?.toString() == text) return
    view.text = text
  }

  private fun formatTemp(value: Double?): String {
    return if (value == null) "--°C" else "${value.roundToInt()}°C"
  }

  private fun formatPercent(value: Double?): String {
    return if (value == null) "--%" else "${value.roundToInt()}%"
  }

  private fun optDouble(obj: JSONObject?, key: String): Double? {
    if (obj == null) return null
    if (!obj.has(key) || obj.isNull(key)) return null
    val value = obj.opt(key) ?: return null
    return when (value) {
      is Number -> value.toDouble()
      is String -> value.toDoubleOrNull()
      else -> null
    }
  }

  private fun updateNotification(text: String) {
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    nm.notify(NOTIFICATION_ID, buildNotification(text))
  }

  private fun startForegroundCompat(text: String) {
    val notification = buildNotification(text)
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        startForeground(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )
      } else {
        startForeground(NOTIFICATION_ID, notification)
      }
    } catch (t: Throwable) {
      Log.w(TAG, "startForeground with type failed, fallback", t)
      startForeground(NOTIFICATION_ID, notification)
    }
  }

  private fun buildNotification(text: String): Notification {
    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
    val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    } else {
      PendingIntent.FLAG_UPDATE_CURRENT
    }
    val pendingIntent = if (launchIntent == null) {
      null
    } else {
      PendingIntent.getActivity(this, 0, launchIntent, flags)
    }

    return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
        .setSmallIcon(R.mipmap.launcher_icon)
        .setContentTitle("Carrot HUD")
        .setContentText(text)
        .setOnlyAlertOnce(true)
        .setOngoing(true)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setContentIntent(pendingIntent)
        .build()
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (nm.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return
    val channel = NotificationChannel(
        NOTIFICATION_CHANNEL_ID,
        "Carrot HUD Overlay",
        NotificationManager.IMPORTANCE_LOW
    ).apply {
      description = "HUD 오버레이 서비스 상태"
      setShowBadge(false)
    }
    nm.createNotificationChannel(channel)
  }

  private fun dp(value: Int): Int {
    val density = resources.displayMetrics.density
    return (value * density).roundToInt()
  }

  private fun dpF(value: Float): Float {
    val density = resources.displayMetrics.density
    return value * density
  }
}
