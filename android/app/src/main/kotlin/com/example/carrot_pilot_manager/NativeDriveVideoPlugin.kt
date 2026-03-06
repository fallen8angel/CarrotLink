package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Canvas
import android.media.MediaCodec
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PerformanceHintManager
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.platform.PlatformViewRegistry
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private const val NATIVE_VIDEO_TAG = "CarrotNativeVideo"

class NativeDriveVideoPlugin(private val messenger: BinaryMessenger) : EventChannel.StreamHandler {
  companion object {
    private const val EVENT_CHANNEL = "carrotlink/native_drive_video_events"
    private const val CONTROL_CHANNEL = "carrotlink/native_drive_video_control"

    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val views = ConcurrentHashMap<Int, NativeDriveVideoView>()

    fun emit(event: Map<String, Any?>) {
      mainHandler.post {
        eventSink?.success(event)
      }
    }

    fun registerView(viewId: Int, view: NativeDriveVideoView) {
      views[viewId] = view
    }

    fun unregisterView(viewId: Int) {
      views.remove(viewId)
    }

    fun updateOverlay(viewId: Int, overlay: Map<String, Any?>?): Boolean {
      val view = views[viewId] ?: return false
      return view.updateOverlay(overlay)
    }

    fun updateArScene(viewId: Int, arScene: Map<String, Any?>?): Boolean {
      val view = views[viewId] ?: return false
      return view.updateArScene(arScene)
    }

    fun getArScene(viewId: Int): Map<String, Any?>? {
      val view = views[viewId] ?: return null
      return view.getArScene()
    }

    fun getArRenderDebug(viewId: Int): Map<String, Any?>? {
      val view = views[viewId] ?: return null
      return view.getArRenderDebug()
    }

    fun clearOverlay(viewId: Int): Boolean {
      val view = views[viewId] ?: return false
      return view.clearOverlay()
    }
  }

  private var controlChannel: MethodChannel? = null

  fun register(context: Context, registry: PlatformViewRegistry) {
    registry.registerViewFactory(
        "carrotlink/native_drive_video",
        NativeDriveVideoViewFactory(context)
    )
    EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    controlChannel =
        MethodChannel(messenger, CONTROL_CHANNEL).apply {
          setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
              "updateOverlay" -> {
                val viewId = (call.argument<Number>("viewId") ?: -1).toInt()
                @Suppress("UNCHECKED_CAST")
                val overlay = call.argument<Map<String, Any?>>("overlay")
                @Suppress("UNCHECKED_CAST")
                val arScene = call.argument<Map<String, Any?>>("arScene")
                val overlayOk = updateOverlay(viewId, overlay)
                val sceneOk = updateArScene(viewId, arScene)
                result.success(overlayOk && sceneOk)
              }

              "clearOverlay" -> {
                val viewId = (call.argument<Number>("viewId") ?: -1).toInt()
                result.success(clearOverlay(viewId))
              }

              "getArScene" -> {
                val viewId = (call.argument<Number>("viewId") ?: -1).toInt()
                result.success(getArScene(viewId))
              }

              "getArRenderDebug" -> {
                val viewId = (call.argument<Number>("viewId") ?: -1).toInt()
                result.success(getArRenderDebug(viewId))
              }

              else -> result.notImplemented()
            }
          }
        }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }
}

private class NativeDriveVideoViewFactory(private val context: Context) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(
      context: Context?,
      viewId: Int,
      args: Any?
  ): PlatformView {
    @Suppress("UNCHECKED_CAST")
    val params = (args as? Map<String, Any?>) ?: emptyMap()
    val wsUrl = params["wsUrl"]?.toString()?.trim().orEmpty()
    return NativeDriveVideoView(this.context, viewId, wsUrl)
  }
}

class NativeDriveVideoView(
    context: Context,
    private val viewId: Int,
    private val wsUrl: String
) : PlatformView, SurfaceHolder.Callback {

  private val rootView = FrameLayout(context)
  private val surfaceView: SurfaceView = SurfaceView(context)
  private val overlayView = NativeDriveOverlayView(context)
  private val reconnectHandler = Handler(Looper.getMainLooper())
  private val decodeThread = HandlerThread("CarrotNativeDecode-$viewId").apply { start() }
  private val decodeHandler = Handler(decodeThread.looper)
  private val okHttpClient =
      OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build()

  @Volatile private var webSocket: WebSocket? = null
  @Volatile private var surface: Surface? = null
  @Volatile private var codec: MediaCodec? = null
  @Volatile private var arScenePayload: Map<String, Any?>? = null
  @Volatile private var codecConfigured = false
  @Volatile private var waitingKeyFrame = true
  @Volatile private var closed = false
  @Volatile private var lastFrameId = -1
  @Volatile private var currentWidth = 0
  @Volatile private var currentHeight = 0
  @Volatile private var connectAttempts = 0
  @Volatile private var lastPacketAtMs = 0L
  @Volatile private var lastDecodedAtMs = 0L
  private val pendingFrameIds: ArrayDeque<Int> = ArrayDeque()
  private val pendingDecodeTasks = AtomicInteger(0)
  @Volatile private var frameStallStrikes = 0
  @Volatile private var decodeBacklogDropCount = 0

  private var reconnectRunnable: Runnable? = null
  private var frameWatchdogRunnable: Runnable? = null
  private val cameraName: String = parseCameraName(wsUrl)
  private val frameWatchdogIntervalMs = 1000L
  private val frameStallTimeoutMs = 7000L
  private val frameDecodeStallTimeoutMs = 6500L
  private val frameStallStrikeLimit = 4
  private val frameHardReconnectMs = 24000L
  private val frameDecodeHardReconnectMs = 18000L
  private val frameStallStateEmitEvery = 2
  private val decodeTaskBacklogLimit = 2
  private val codecBacklogLimit = 2
  private val decodeBacklogStateEmitEvery = 24
  @Volatile private var hintedFrameRate = 30f
  @Volatile private var performanceHintTargetNs = 33_333_333L
  @Volatile private var performanceHintSession: PerformanceHintManager.Session? = null

  init {
    rootView.addView(
        surfaceView,
        FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        ),
    )
    rootView.addView(
        overlayView,
        FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        ),
    )
    surfaceView.holder.addCallback(this)
    ensurePerformanceHintSession()
    NativeDriveVideoPlugin.registerView(viewId, this)
    emitState("init")
  }

  override fun getView(): View = rootView

  override fun dispose() {
    closed = true
    clearReconnect()
    stopFrameWatchdog()
    closeSocket()
    clearSurfaceFrameRateHint()
    closePerformanceHintSession()
    releaseDecoder()
    clearOverlay()
    try {
      decodeThread.quitSafely()
    } catch (_: Throwable) {
    }
    NativeDriveVideoPlugin.unregisterView(viewId)
    emitState("disposed")
  }

  override fun surfaceCreated(holder: SurfaceHolder) {
    surface = holder.surface
    applySurfaceFrameRateHint(hintedFrameRate)
    emitState("surface_created")
    connect()
  }

  override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
    // no-op
  }

  override fun surfaceDestroyed(holder: SurfaceHolder) {
    surface = null
    clearSurfaceFrameRateHint()
    emitState("surface_destroyed")
    stopFrameWatchdog()
    closeSocket()
    releaseDecoder()
  }

  private fun connect() {
    if (closed) return
    if (surface == null || !surface!!.isValid) return
    if (wsUrl.isBlank()) {
      emitError("invalid_ws_url")
      return
    }
    closeSocket()
    connectAttempts += 1
    frameStallStrikes = 0
    emitState("connecting")
    val request = Request.Builder().url(wsUrl).build()
    val newSocket =
        okHttpClient.newWebSocket(
            request,
            object : WebSocketListener() {
              override fun onOpen(webSocket: WebSocket, response: Response) {
                if (!isCurrentSocket(webSocket)) return
                lastPacketAtMs = System.currentTimeMillis()
                lastDecodedAtMs = lastPacketAtMs
                frameStallStrikes = 0
                startFrameWatchdog()
                emitState("connected")
              }

              override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                if (!isCurrentSocket(webSocket)) return
                lastPacketAtMs = System.currentTimeMillis()
                frameStallStrikes = 0
                val copy = bytes.toByteArray()
                val queued = pendingDecodeTasks.incrementAndGet()
                decodeHandler.post {
                  try {
                    handlePacket(copy)
                  } finally {
                    val remain = pendingDecodeTasks.decrementAndGet()
                    if (remain < 0) {
                      pendingDecodeTasks.set(0)
                    }
                  }
                }
                if (queued >= (decodeTaskBacklogLimit + 4) &&
                    (queued == (decodeTaskBacklogLimit + 4) || queued % 8 == 0)
                ) {
                  emitState("decode_queue_$queued")
                }
              }

              override fun onFailure(
                  webSocket: WebSocket,
                  t: Throwable,
                  response: Response?,
              ) {
                if (!isCurrentSocket(webSocket)) return
                stopFrameWatchdog()
                this@NativeDriveVideoView.webSocket = null
                emitError("socket_failure:${t.message ?: "unknown"}")
                releaseDecoder()
                scheduleReconnect(900)
              }

              override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!isCurrentSocket(webSocket)) return
                stopFrameWatchdog()
                this@NativeDriveVideoView.webSocket = null
                emitState("closed:$code")
                scheduleReconnect(900)
              }
            },
        )
    webSocket = newSocket
  }

  private fun isCurrentSocket(callbackSocket: WebSocket?): Boolean {
    return callbackSocket != null && callbackSocket === webSocket
  }

  private fun scheduleReconnect(delayMs: Long) {
    if (closed) return
    if (surface == null || !surface!!.isValid) return
    clearReconnect()
    reconnectRunnable =
        Runnable {
          reconnectRunnable = null
          connect()
        }
    reconnectHandler.postDelayed(reconnectRunnable!!, delayMs)
  }

  private fun clearReconnect() {
    reconnectRunnable?.let {
      reconnectHandler.removeCallbacks(it)
    }
    reconnectRunnable = null
  }

  private fun startFrameWatchdog() {
    stopFrameWatchdog()
    lastPacketAtMs = System.currentTimeMillis()
    lastDecodedAtMs = lastPacketAtMs
    frameWatchdogRunnable =
        object : Runnable {
          override fun run() {
            if (closed) return
            val localSurface = surface
            if (localSurface == null || !localSurface.isValid) {
              stopFrameWatchdog()
              return
            }
            val now = System.currentTimeMillis()
            val elapsedPacketMs = now - lastPacketAtMs
            val elapsedDecodedMs = now - lastDecodedAtMs
            val packetStalled = elapsedPacketMs > frameStallTimeoutMs
            val decodeStalled = codecConfigured && elapsedDecodedMs > frameDecodeStallTimeoutMs
            if (webSocket != null && (packetStalled || decodeStalled)) {
              frameStallStrikes += 1
              if (frameStallStrikes == 1 || frameStallStrikes % frameStallStateEmitEvery == 0) {
                emitState("stalling_pkt_${elapsedPacketMs}ms_dec_${elapsedDecodedMs}ms")
              }
              val packetHardStall = elapsedPacketMs > frameHardReconnectMs
              val decodeHardStall = codecConfigured && elapsedDecodedMs > frameDecodeHardReconnectMs
              if ((packetHardStall || decodeHardStall) && frameStallStrikes >= frameStallStrikeLimit) {
                emitError("frame_stall_pkt_${elapsedPacketMs}ms_dec_${elapsedDecodedMs}ms")
                stopFrameWatchdog()
                closeSocket()
                releaseDecoder()
                scheduleReconnect(350)
                return
              }
            } else {
              if (frameStallStrikes > 0) {
                emitState("recovered")
              }
              frameStallStrikes = 0
            }
            reconnectHandler.postDelayed(this, frameWatchdogIntervalMs)
          }
        }
    reconnectHandler.postDelayed(frameWatchdogRunnable!!, frameWatchdogIntervalMs)
  }

  private fun stopFrameWatchdog() {
    frameWatchdogRunnable?.let { reconnectHandler.removeCallbacks(it) }
    frameWatchdogRunnable = null
  }

  private fun closeSocket() {
    val ws = webSocket
    webSocket = null
    try {
      ws?.close(1000, "dispose")
    } catch (_: Throwable) {
    }
  }

  fun updateOverlay(overlay: Map<String, Any?>?): Boolean {
    if (closed) return false
    overlayView.updateOverlay(overlay)
    return true
  }

  fun updateArScene(arScene: Map<String, Any?>?): Boolean {
    if (closed) return false
    overlayView.updateArScene(NativeDriveArScene.fromPayload(arScene))
    arScenePayload = arScene
    return true
  }

  fun getArScene(): Map<String, Any?>? {
    return arScenePayload
  }

  fun getArRenderDebug(): Map<String, Any?>? {
    return overlayView.getArRenderDebug()
  }

  fun clearOverlay(): Boolean {
    overlayView.clearOverlay()
    arScenePayload = null
    return true
  }

  private fun releaseDecoder() {
    codecConfigured = false
    waitingKeyFrame = true
    lastFrameId = -1
    pendingDecodeTasks.set(0)
    pendingFrameIds.clear()
    val c = codec
    codec = null
    if (c != null) {
      try {
        c.stop()
      } catch (_: Throwable) {
      }
      try {
        c.release()
      } catch (_: Throwable) {
      }
    }
  }

  private data class ParsedPacket(
      val meta: JSONObject,
      val payload: ByteArray,
  )

  private fun noteBacklogDrop(reason: String, backlog: Int) {
    decodeBacklogDropCount += 1
    if (decodeBacklogDropCount == 1 || decodeBacklogDropCount % decodeBacklogStateEmitEvery == 0) {
      emitState("drop_${reason}_n${decodeBacklogDropCount}_b$backlog")
    }
  }

  private fun handlePacket(packet: ByteArray) {
    if (closed) return
    if (surface == null || !surface!!.isValid) return

    val parsed = parsePacket(packet) ?: return
    val meta = parsed.meta
    val frameId = meta.optInt("frameId", -1)
    if (frameId >= 0 && lastFrameId >= 0 && frameId <= lastFrameId) {
      return
    }
    val keyByMeta =
        meta.optBoolean("keyFrame", false) || ((meta.optInt("flags", 0) and 0x8) != 0)
    val queuedTasks = pendingDecodeTasks.get()
    if (queuedTasks > (decodeTaskBacklogLimit + 1) && !keyByMeta) {
      noteBacklogDrop("task", queuedTasks)
      return
    }
    if (pendingFrameIds.size >= codecBacklogLimit && !keyByMeta) {
      noteBacklogDrop("codec", pendingFrameIds.size)
      return
    }
    if (frameId >= 0) {
      lastFrameId = frameId
    }

    val width = meta.optInt("width", 0).coerceAtLeast(0)
    val height = meta.optInt("height", 0).coerceAtLeast(0)
    updateFrameRateHintFromMeta(meta)
    if (width > 0 && height > 0 && (width != currentWidth || height != currentHeight)) {
      currentWidth = width
      currentHeight = height
      emitMeta(width, height)
    }

    val annexb = toAnnexB(parsed.payload, keyByMeta) ?: return

    if (!codecConfigured) {
      if (!keyByMeta) return
      val w = if (width > 0) width else 1928
      val h = if (height > 0) height else 1208
      if (!configureDecoder(w, h)) {
        emitError("decoder_init_failed")
        return
      }
    }

    val isKey = keyByMeta
    if (waitingKeyFrame && !isKey) return
    waitingKeyFrame = false

    val ts =
        when {
          meta.has("timestampEof") -> meta.optLong("timestampEof")
          meta.has("timestampSof") -> meta.optLong("timestampSof")
          else -> System.nanoTime()
        }
    val ptsUs = if (ts > 0L) ts / 1000L else (System.nanoTime() / 1000L)
    queueFrame(annexb, ptsUs, frameId)
  }

  private fun configureDecoder(width: Int, height: Int): Boolean {
    releaseDecoder()
    val s = surface ?: return false
    return try {
      val localCodec = MediaCodec.createDecoderByType("video/avc")
      val format = MediaFormat.createVideoFormat("video/avc", width, height)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
      }
      format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
      localCodec.configure(format, s, null, 0)
      localCodec.start()
      applySurfaceFrameRateHint(hintedFrameRate)
      ensurePerformanceHintSession()
      codec = localCodec
      codecConfigured = true
      waitingKeyFrame = true
      emitState("decoder_configured_${width}x$height")
      true
    } catch (t: Throwable) {
      Log.w(NATIVE_VIDEO_TAG, "configureDecoder failed", t)
      releaseDecoder()
      false
    }
  }

  private fun queueFrame(frame: ByteArray, ptsUs: Long, frameId: Int) {
    val localCodec = codec ?: return
    try {
      val inputIndex = localCodec.dequeueInputBuffer(0)
      if (inputIndex < 0) {
        noteBacklogDrop("input", pendingFrameIds.size)
        return
      }
      val input = localCodec.getInputBuffer(inputIndex) ?: return
      input.clear()
      input.put(frame)
      localCodec.queueInputBuffer(inputIndex, 0, frame.size, ptsUs, 0)
      if (frameId >= 0) {
        pendingFrameIds.addLast(frameId)
      }
      val decodeStartNs = System.nanoTime()
      drainOutput(localCodec, decodeStartNs)
    } catch (t: Throwable) {
      emitError("decoder_queue_failed:${t.message ?: "unknown"}")
      releaseDecoder()
    }
  }

  private fun drainOutput(localCodec: MediaCodec, decodeStartNs: Long) {
    val info = MediaCodec.BufferInfo()
    while (true) {
      val outIndex = localCodec.dequeueOutputBuffer(info, 0)
      when {
        outIndex >= 0 -> {
          lastDecodedAtMs = System.currentTimeMillis()
          reportPerformanceActualWork((System.nanoTime() - decodeStartNs).coerceAtLeast(1_000_000L))
          val renderedFrameId = if (pendingFrameIds.isEmpty()) -1 else pendingFrameIds.removeFirst()
          if (renderedFrameId >= 0) {
            emitFrame(renderedFrameId)
          }
          localCodec.releaseOutputBuffer(outIndex, true)
        }

        outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> return
        outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
          val format = localCodec.outputFormat
          val w = format.getInteger(MediaFormat.KEY_WIDTH)
          val h = format.getInteger(MediaFormat.KEY_HEIGHT)
          emitMeta(w, h)
        }

        else -> return
      }
    }
  }

  private fun parsePacket(packet: ByteArray): ParsedPacket? {
    if (packet.size < 6) return null
    val metaLen =
        ((packet[0].toInt() and 0xFF) shl 24) or
            ((packet[1].toInt() and 0xFF) shl 16) or
            ((packet[2].toInt() and 0xFF) shl 8) or
            (packet[3].toInt() and 0xFF)
    if (metaLen <= 1 || metaLen > 65536) return null
    val offset = 4 + metaLen
    if (offset >= packet.size) return null
    return try {
      val metaText = String(packet, 4, metaLen, Charsets.UTF_8)
      val meta = JSONObject(metaText)
      val payload = packet.copyOfRange(offset, packet.size)
      ParsedPacket(meta, payload)
    } catch (_: Throwable) {
      null
    }
  }

  private fun hasStartCode(data: ByteArray): Boolean {
    var i = 0
    while (i + 3 < data.size) {
      if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
        if (data[i + 2] == 1.toByte()) return true
        if (i + 3 < data.size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) return true
      }
      i += 1
    }
    return false
  }

  private fun toAnnexB(data: ByteArray, isKeyFrame: Boolean): ByteArray? {
    if (data.isEmpty()) return null
    if (hasStartCode(data)) return data
    if (isKeyFrame && data[0].toInt() == 1) {
      val cfg = avcConfigToAnnexB(data)
      if (cfg != null && cfg.isNotEmpty()) return cfg
    }
    val converted = avccPayloadToAnnexB(data, 4)
    return converted ?: data
  }

  private fun avcConfigToAnnexB(data: ByteArray): ByteArray? {
    if (data.size < 7) return null
    if (data[0].toInt() != 1) return null
    val lengthSize = ((data[4].toInt() and 0x03) + 1).coerceIn(1, 4)
    var off = 5
    val out = ByteArrayOutputStream(data.size + 64)

    val spsCount = data[off].toInt() and 0x1F
    off += 1
    for (i in 0 until spsCount) {
      if (off + 2 > data.size) return null
      val len = ((data[off].toInt() and 0xFF) shl 8) or (data[off + 1].toInt() and 0xFF)
      off += 2
      if (len <= 0 || off + len > data.size) return null
      out.write(byteArrayOf(0, 0, 0, 1))
      out.write(data, off, len)
      off += len
    }

    if (off + 1 > data.size) return null
    val ppsCount = data[off].toInt() and 0xFF
    off += 1
    for (i in 0 until ppsCount) {
      if (off + 2 > data.size) return null
      val len = ((data[off].toInt() and 0xFF) shl 8) or (data[off + 1].toInt() and 0xFF)
      off += 2
      if (len <= 0 || off + len > data.size) return null
      out.write(byteArrayOf(0, 0, 0, 1))
      out.write(data, off, len)
      off += len
    }

    if (off < data.size) {
      val remain = data.copyOfRange(off, data.size)
      val payload = avccPayloadToAnnexB(remain, lengthSize)
      if (payload != null && payload.isNotEmpty()) {
        out.write(payload)
      }
    }
    return out.toByteArray()
  }

  private fun avccPayloadToAnnexB(data: ByteArray, lengthSize: Int): ByteArray? {
    val ls = lengthSize.coerceIn(1, 4)
    var off = 0
    val out = ByteArrayOutputStream(data.size + 64)
    while (off + ls <= data.size) {
      var nalLen = 0
      for (i in 0 until ls) {
        nalLen = (nalLen shl 8) or (data[off + i].toInt() and 0xFF)
      }
      off += ls
      if (nalLen <= 0 || off + nalLen > data.size) return null
      out.write(byteArrayOf(0, 0, 0, 1))
      out.write(data, off, nalLen)
      off += nalLen
    }
    if (off != data.size) return null
    return out.toByteArray()
  }

  private fun emitMeta(width: Int, height: Int) {
    NativeDriveVideoPlugin.emit(
        mapOf(
            "viewId" to viewId,
            "type" to "camera_meta",
            "camera" to cameraName,
            "width" to width,
            "height" to height,
        ))
  }

  private fun emitFrame(frameId: Int) {
    NativeDriveVideoPlugin.emit(
        mapOf(
            "viewId" to viewId,
            "type" to "camera_frame",
            "camera" to cameraName,
            "frameId" to frameId,
        ))
  }

  private fun emitError(reason: String) {
    NativeDriveVideoPlugin.emit(
        mapOf(
            "viewId" to viewId,
            "type" to "camera_error",
            "camera" to cameraName,
            "reason" to reason,
        ))
  }

  private fun emitState(state: String) {
    NativeDriveVideoPlugin.emit(
        mapOf(
            "viewId" to viewId,
            "type" to "camera_state",
            "camera" to cameraName,
            "state" to state,
            "attempt" to connectAttempts,
        ))
  }

  private fun parseCameraName(url: String): String {
    val fallback = "road"
    return try {
      val path = Uri.parse(url).path.orEmpty()
      when {
        path.endsWith("/wideRoad", ignoreCase = true) -> "wideRoad"
        path.endsWith("/road", ignoreCase = true) -> "road"
        else -> fallback
      }
    } catch (_: Throwable) {
      fallback
    }
  }

  private fun updateFrameRateHintFromMeta(meta: JSONObject) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
    val byFps = meta.optDouble("fps", 0.0).toFloat()
    val byFrameRate = meta.optDouble("frameRate", 0.0).toFloat()
    val raw = if (byFps > 0f) byFps else byFrameRate
    if (raw <= 0f) return
    val normalized =
        when {
          raw >= 90f -> 120f
          raw >= 50f -> 60f
          raw >= 28f -> 30f
          else -> 24f
        }
    if (kotlin.math.abs(normalized - hintedFrameRate) < 0.1f) return
    hintedFrameRate = normalized
    applySurfaceFrameRateHint(hintedFrameRate)
    updatePerformanceHintTarget(hintedFrameRate)
  }

  private fun applySurfaceFrameRateHint(targetFps: Float) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
    val rate = targetFps.coerceIn(15f, 120f)
    try {
      invokeSetFrameRateReflective(surfaceView, rate)
      val localSurface = surface
      if (localSurface != null && localSurface.isValid) {
        invokeSetFrameRateReflective(localSurface, rate)
      }
    } catch (t: Throwable) {
      Log.w(NATIVE_VIDEO_TAG, "applySurfaceFrameRateHint failed", t)
    }
  }

  private fun clearSurfaceFrameRateHint() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
    try {
      invokeSetFrameRateReflective(surfaceView, 0f)
      val localSurface = surface
      if (localSurface != null && localSurface.isValid) {
        invokeSetFrameRateReflective(localSurface, 0f)
      }
    } catch (_: Throwable) {
    }
  }

  private fun invokeSetFrameRateReflective(target: Any, fps: Float) {
    // Keep build compatibility even when compileSdk does not expose setFrameRate APIs.
    try {
      val cls = target.javaClass
      val threeArgs =
          cls.methods.firstOrNull { method ->
            method.name == "setFrameRate" && method.parameterTypes.size == 3
          }
      if (threeArgs != null) {
        threeArgs.invoke(target, fps, 0, 0)
        return
      }
      val twoArgs =
          cls.methods.firstOrNull { method ->
            method.name == "setFrameRate" && method.parameterTypes.size == 2
          }
      if (twoArgs != null) {
        twoArgs.invoke(target, fps, 0)
      }
    } catch (_: Throwable) {
    }
  }

  private fun ensurePerformanceHintSession() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
    if (performanceHintSession != null) return
    try {
      val manager = rootView.context.getSystemService(PerformanceHintManager::class.java) ?: return
      val decodeTid = decodeThread.threadId
      if (decodeTid <= 0) return
      performanceHintSession =
          manager.createHintSession(intArrayOf(decodeTid), performanceHintTargetNs)
      emitState("perf_hint_on_tid_$decodeTid")
    } catch (t: Throwable) {
      Log.w(NATIVE_VIDEO_TAG, "ensurePerformanceHintSession failed", t)
      performanceHintSession = null
    }
  }

  private fun updatePerformanceHintTarget(fps: Float) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
    val clamped = fps.coerceIn(15f, 120f)
    val targetNs = (1_000_000_000f / clamped).toLong().coerceIn(8_000_000L, 66_000_000L)
    performanceHintTargetNs = targetNs
    try {
      performanceHintSession?.updateTargetWorkDuration(targetNs)
    } catch (_: Throwable) {
    }
  }

  private fun reportPerformanceActualWork(actualWorkNs: Long) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
    if (actualWorkNs <= 0L) return
    try {
      performanceHintSession?.reportActualWorkDuration(actualWorkNs.coerceIn(1_000_000L, 200_000_000L))
    } catch (_: Throwable) {
    }
  }

  private fun closePerformanceHintSession() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
      performanceHintSession = null
      return
    }
    try {
      performanceHintSession?.close()
    } catch (_: Throwable) {
    } finally {
      performanceHintSession = null
    }
  }
}

private class NativeDriveOverlayView(context: Context) : View(context) {
  @Volatile private var overlayPayload: NativeDriveOverlayPayload? = null
  private val overlayRenderer = NativeDriveOverlayCanvasRenderer()
  private val arSceneRenderer = NativeDriveArSceneOverlayRenderer()
  private val arRenderPipeline = NativeDriveArRenderStatePipeline()

  fun updateOverlay(payload: Map<String, Any?>?) {
    if (payload == null) {
      clearOverlay()
      return
    }
    val parsed = NativeDriveOverlayPayload.fromPayload(payload) ?: run {
      clearOverlay()
      return
    }
    overlayPayload = parsed
    postInvalidateOnAnimation()
  }

  fun updateArScene(scene: NativeDriveArScene?) {
    arRenderPipeline.updateScene(scene)
    postInvalidateOnAnimation()
  }

  fun getArRenderDebug(): Map<String, Any?>? = arRenderPipeline.currentDebug()

  fun clearOverlay() {
    overlayPayload = null
    arRenderPipeline.clear()
    postInvalidateOnAnimation()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val overlay = overlayPayload
    val scene = arRenderPipeline.currentScene()
    if (overlay == null && scene == null) return
    val drawWidth = width.toFloat()
    val drawHeight = height.toFloat()
    if (drawWidth <= 1f || drawHeight <= 1f) return
    val strokeScale = overlayRenderer.draw(canvas, overlay, drawWidth, drawHeight)
    val renderFrame = arRenderPipeline.resolveFrame(overlay = overlay, drawWidth = drawWidth)
    if (renderFrame.scene == null || renderFrame.policy == null) return
    arSceneRenderer.draw(
        canvas = canvas,
        scene = renderFrame.scene,
        drawWidth = drawWidth,
        drawHeight = drawHeight,
        strokeScale = strokeScale,
        policy = renderFrame.policy,
    )
  }
}
