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
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import java.util.Locale
import kotlin.math.roundToInt

class OverlayHudService : Service() {
  companion object {
    const val ACTION_START = "carrot.overlay.START"
    const val ACTION_STOP = "carrot.overlay.STOP"
    const val ACTION_UPDATE_ENDPOINT = "carrot.overlay.UPDATE_ENDPOINT"
    const val ACTION_RESET_POSITION = "carrot.overlay.RESET_POSITION"
    const val ACTION_UPDATE_SNAPSHOT = "carrot.overlay.UPDATE_SNAPSHOT"
    const val EXTRA_HOST = "extra_host"
    const val EXTRA_SNAPSHOT_JSON = "extra_snapshot_json"

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
  private val dragHoldToCloseMs = 260L

  private var destroyed = false
  private var overlayLayoutSignature: String? = null

  private var hostIp: String? = null
  private var lastSemanticSnapshotAt = 0L
  private var semanticSourceActive = false
  private var fallbackCpuTempC: Double? = null
  private var fallbackCpuUpdatedAt = 0L
  private var fallbackMemPct: Double? = null
  private var fallbackMemUpdatedAt = 0L
  private var fallbackDiskPct: Double? = null
  private var fallbackDiskUpdatedAt = 0L

  private var hudBindings: OverlayHudViewBindings? = null

  private var lastUiUpdateAt = 0L
  private var lastStatus = "대기 중"
  private var dragTouchSlop = 8
  private var lastBoundsCheckAt = 0L
  private var lastAppliedUiState: OverlayHudUiState? = null
  private lateinit var positionController: OverlayHudPositionController
  private lateinit var closeTargetController: OverlayHudCloseTargetController
  private lateinit var socketClient: OverlayHudSocketClient

  private val staleCheckRunnable = object : Runnable {
    override fun run() {
      if (destroyed) return
      val now = SystemClock.elapsedRealtime()
      if (now - lastBoundsCheckAt >= 1500) {
        lastBoundsCheckAt = now
        ensureOverlayLayoutProfile()
        ensureOverlayInBounds(forceApply = false, persistIfChanged = true)
      }
      val semanticFresh = hasFreshSemanticSnapshot(now)
      if (semanticSourceActive && !semanticFresh) {
        semanticSourceActive = false
        updateStatusUi("semantic 지연, websocket 전환")
        updateNotification("semantic 지연, websocket 전환")
        if (!hostIp.isNullOrBlank()) {
          socketClient.resetCandidates()
          connectWebSocket(force = true)
        }
      } else if (socketClient.isConnected) {
        val age = now - socketClient.lastMessageAt
        if (age > 2500) {
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
    positionController = OverlayHudPositionController(
        context = this,
        windowManagerProvider = { windowManager },
        prefsName = PREFS_NAME,
        prefXKey = PREF_X,
        prefYKey = PREF_Y,
    )
    closeTargetController = OverlayHudCloseTargetController(
        context = this,
        windowManagerProvider = { windowManager },
        overlayWindowTypeProvider = ::overlayWindowType,
    )
    socketClient = OverlayHudSocketClient(mainHandler)
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

      ACTION_UPDATE_SNAPSHOT -> {
        val snapshotJson = intent?.getStringExtra(EXTRA_SNAPSHOT_JSON)?.trim().orEmpty()
        if (snapshotJson.isNotEmpty()) {
          applySemanticSnapshotJson(snapshotJson)
        }
        return START_STICKY
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
        if (!hostIp.isNullOrBlank() && !hasFreshSemanticSnapshot()) {
          connectWebSocket(force = false)
        }
      }

      ACTION_START, ACTION_UPDATE_ENDPOINT -> {
        val nextHost = intent?.getStringExtra(EXTRA_HOST)?.trim().orEmpty()
        val snapshotJson = intent?.getStringExtra(EXTRA_SNAPSHOT_JSON)?.trim().orEmpty()
        if (nextHost.isNotEmpty()) {
          if (hostIp != nextHost) {
            socketClient.resetCandidates()
          }
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
        if (snapshotJson.isNotEmpty()) {
          applySemanticSnapshotJson(snapshotJson)
        }
        if (hasFreshSemanticSnapshot()) {
          val host = hostIp?.trim().orEmpty()
          updateStatusUi("연결됨 · ${if (host.isNotEmpty()) host else "-"}")
          updateNotification("연결됨: ${if (host.isNotEmpty()) host else "-"}")
          return START_STICKY
        }
        socketClient.resetCandidates()
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
    socketClient.cancelReconnect()
    socketClient.disconnect(shutdownClient = true)
    detachOverlay()
    closeTargetController.detach()
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

  private fun overlayWindowType(): Int {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
      @Suppress("DEPRECATION")
      WindowManager.LayoutParams.TYPE_PHONE
    }
  }

  private fun currentOverlayLayoutProfile(): OverlayHudLayoutProfile {
    val bounds = positionController.screenBounds()
    return OverlayHudLayoutProfiles.fromScreenBounds(
        widthPx = bounds.width(),
        heightPx = bounds.height(),
        density = resources.displayMetrics.density,
    )
  }

  private fun currentOverlayLayoutSignature(): String {
    return OverlayHudLayoutProfiles.signature(currentOverlayLayoutProfile())
  }

  private fun connectWebSocket(force: Boolean) {
    if (destroyed) return
    val host = hostIp?.trim().orEmpty()
    if (host.isEmpty()) return
    if (hasFreshSemanticSnapshot()) {
      updateStatusUi("연결됨 · $host")
      updateNotification("연결됨: $host")
      return
    }
    socketClient.connect(
        host = host,
        force = force,
        hasFreshSemanticSnapshot = ::hasFreshSemanticSnapshot,
        onStatus = { status, notification ->
          updateStatusUi(status)
          updateNotification(notification)
        },
        onMessage = { text ->
          val now = SystemClock.elapsedRealtime()
          if (now - lastUiUpdateAt < 100) return@connect
          lastUiUpdateAt = now
          applyPayloadText(text)
        },
        requestReconnect = ::scheduleReconnect,
    )
  }

  private fun scheduleReconnect() {
    socketClient.scheduleReconnect(
        host = hostIp,
        destroyed = destroyed,
        reconnectDelayMs = 2000,
        onConnect = {
          connectWebSocket(force = true)
        },
    )
  }

  private fun attachOverlayIfNeeded() {
    if (rootView != null) {
      ensureOverlayLayoutProfile()
      ensureOverlayInBounds(forceApply = true, persistIfChanged = true)
      return
    }
    val wm = windowManager ?: return

    val params = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        overlayWindowType(),
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT
    ).apply {
      gravity = Gravity.START or Gravity.TOP
      x = positionController.defaultOverlayX()
      y = positionController.defaultOverlayY()
    }

    val overlay = buildHudView()
    try {
      wm.addView(overlay, params)
      rootLayoutParams = params
      rootView = overlay
      overlayLayoutSignature = currentOverlayLayoutSignature()
      positionController.restoreOverlayPosition(params)
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
    rootLayoutParams?.let { positionController.persistOverlayPosition(it) }
    Log.i(TAG, "Detaching overlay size=${view.width}x${view.height}")
    try {
      wm.removeView(view)
    } catch (_: Throwable) {
    }
    rootView = null
    rootLayoutParams = null
    overlayLayoutSignature = null
    hudBindings = null
  }

  private fun ensureOverlayLayoutProfile() {
    val wm = windowManager ?: return
    val currentView = rootView ?: return
    val currentParams = rootLayoutParams ?: return
    val nextSignature = currentOverlayLayoutSignature()
    if (overlayLayoutSignature == nextSignature) return

    val preservedX = currentParams.x
    val preservedY = currentParams.y
    val replacement = buildHudView()
    try {
      wm.removeView(currentView)
    } catch (_: Throwable) {
    }

    val nextParams = WindowManager.LayoutParams().apply {
      copyFrom(currentParams)
      x = preservedX
      y = preservedY
    }
    try {
      wm.addView(replacement, nextParams)
      rootView = replacement
      rootLayoutParams = nextParams
      overlayLayoutSignature = nextSignature
      lastAppliedUiState?.let(::applyUiState)
      updateStatusUi(lastStatus)
      replacement.post {
        ensureOverlayInBounds(forceApply = true, persistIfChanged = true)
      }
    } catch (_: Throwable) {
      rootView = null
      rootLayoutParams = null
      overlayLayoutSignature = null
      hudBindings = null
    }
  }

  private fun showCloseTarget() {
    closeTargetController.show()
  }

  private fun hideCloseTarget() {
    closeTargetController.hide()
  }

  private fun setCloseTargetHover(hover: Boolean) {
    closeTargetController.setHover(hover)
  }

  private fun isOverlayOverCloseTarget(): Boolean {
    return closeTargetController.isOverlayOverTarget(rootView)
  }

  private fun buildHudView(): View {
    val profile = currentOverlayLayoutProfile()
    val builtView = OverlayHudViewFactory(this).build(profile)
    val card = builtView.rootView
    hudBindings = builtView.bindings
    card.setOnTouchListener(
        OverlayHudTouchInteractions.createTouchListener(
            mainHandler = mainHandler,
            dragTouchSlop = dragTouchSlop,
            dragHoldToCloseMs = dragHoldToCloseMs,
            callbacks = OverlayHudTouchCallbacks(
                currentLayoutParams = { rootLayoutParams },
                currentOverlaySize = { currentOverlaySize() },
                updateOverlayLayout = { params ->
                  try {
                    windowManager?.updateViewLayout(rootView, params)
                  } catch (_: Throwable) {
                  }
                },
                clampOverlayPosition = { params, width, height ->
                  positionController.clampOverlayPosition(params, width, height)
                },
                snapOverlayToNearestAnchor = { params, width, height ->
                  positionController.snapOverlayToNearestAnchor(params, width, height)
                },
                persistOverlayPosition = { params ->
                  positionController.persistOverlayPosition(params)
                },
                showCloseTarget = ::showCloseTarget,
                hideCloseTarget = ::hideCloseTarget,
                setCloseTargetHover = ::setCloseTargetHover,
                isOverlayOverCloseTarget = ::isOverlayOverCloseTarget,
                onRequestClose = {
                  updateStatusUi("HUD 종료")
                  stopSelf()
                },
                onTap = ::openAppFromOverlayTap,
            ),
        )
    )

    return card
  }

  private fun openAppFromOverlayTap() {
    try {
      val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return
      launchIntent.addFlags(
          Intent.FLAG_ACTIVITY_NEW_TASK or
              Intent.FLAG_ACTIVITY_SINGLE_TOP or
              Intent.FLAG_ACTIVITY_CLEAR_TOP
      )
      startActivity(launchIntent)
    } catch (_: Throwable) {
    }
  }

  private fun resetOverlayPosition() {
    val params = rootLayoutParams ?: return
    params.x = positionController.defaultOverlayX()
    params.y = positionController.defaultOverlayY()
    ensureOverlayInBounds(forceApply = true, persistIfChanged = true)
    Log.i(TAG, "Overlay position reset to default")
  }

  private fun currentOverlaySize(): Pair<Int, Int> {
    return positionController.currentOverlaySize(rootView)
  }

  private fun ensureOverlayInBounds(forceApply: Boolean, persistIfChanged: Boolean) {
    positionController.ensureOverlayInBounds(
        view = rootView,
        params = rootLayoutParams,
        forceApply = forceApply,
        persistIfChanged = persistIfChanged,
    )
  }

  private fun applyPayloadText(raw: String) {
    val result = OverlayHudPayloadParser.parse(raw, currentParseContext()) ?: return
    applyParseResult(result)
  }

  private fun applySemanticSnapshotJson(raw: String) {
    val result = OverlayHudPayloadParser.parse(raw, currentParseContext()) ?: return
    if (result.kind != OverlayHudPayloadKind.Semantic) return
    applyParseResult(result)
  }

  private fun currentParseContext(): OverlayHudParseContext {
    return OverlayHudParseContext(
        hostIp = hostIp,
        fallbackCpuTempC = latestFallbackCpuTemp(),
        fallbackMemPct = latestFallbackMemPct(),
        fallbackDiskPct = latestFallbackDiskPct(),
    )
  }

  private fun applyMetricPatch(patch: OverlayHudMetricPatch) {
    val now = SystemClock.elapsedRealtime()
    patch.cpuTempC?.let {
      fallbackCpuTempC = it
      fallbackCpuUpdatedAt = now
    }
    patch.memPct?.let {
      fallbackMemPct = it
      fallbackMemUpdatedAt = now
    }
    patch.diskPct?.let {
      fallbackDiskPct = it
      fallbackDiskUpdatedAt = now
    }
  }

  private fun applyParseResult(result: OverlayHudParseResult) {
    applyMetricPatch(result.metricPatch)
    if (result.kind == OverlayHudPayloadKind.Semantic) {
      val now = SystemClock.elapsedRealtime()
      val shouldSwitchFromLegacy =
          !semanticSourceActive || socketClient.isConnected || socketClient.hasReconnectScheduled()
      lastSemanticSnapshotAt = now
      semanticSourceActive = true
      if (shouldSwitchFromLegacy) {
        socketClient.cancelReconnect()
        socketClient.disconnect(shutdownClient = false)
      }
      applyUiState(result.uiState)
      if (shouldSwitchFromLegacy) {
        updateNotification("연결됨: ${result.hostLabel ?: "-"}")
      }
      return
    }
    applyUiState(result.uiState)
  }

  private fun applyUiState(state: OverlayHudUiState) {
    lastAppliedUiState = state
    mainHandler.post {
      val bindings = hudBindings ?: return@post
      OverlayHudUiApplier.apply(bindings, state)
    }
  }

  private fun hasFreshSemanticSnapshot(now: Long = SystemClock.elapsedRealtime()): Boolean {
    if (!semanticSourceActive) return false
    return now - lastSemanticSnapshotAt <= 2500L
  }

  private fun updateStatusUi(status: String) {
    mainHandler.post {
      hudBindings?.let { OverlayHudUiApplier.updateStatus(it, status) }
      lastStatus = status
    }
  }

  private fun latestFallbackCpuTemp(): Double? {
    val value = fallbackCpuTempC ?: return null
    val age = SystemClock.elapsedRealtime() - fallbackCpuUpdatedAt
    return if (age <= 15000) value else null
  }

  private fun latestFallbackMemPct(): Double? {
    val value = fallbackMemPct ?: return null
    val age = SystemClock.elapsedRealtime() - fallbackMemUpdatedAt
    return if (age <= 15000) value else null
  }

  private fun latestFallbackDiskPct(): Double? {
    val value = fallbackDiskPct ?: return null
    val age = SystemClock.elapsedRealtime() - fallbackDiskUpdatedAt
    return if (age <= 15000) value else null
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

}
