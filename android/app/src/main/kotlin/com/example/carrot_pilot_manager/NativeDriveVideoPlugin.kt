package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private const val NATIVE_VIDEO_TAG = "CarrotNativeVideo"

private fun createNativeDriveYoloRuntime(
    context: Context,
    backendHint: String,
): NativeDriveYoloRuntime {
  val backend = backendHint.trim().lowercase()
  return if (backend.startsWith("litert") || backend.startsWith("tflite")) {
    NativeDriveLiteRtRuntime(context)
  } else {
    NativeDriveExecuTorchRuntime(context)
  }
}

class NativeDriveVideoPlugin(private val messenger: BinaryMessenger) : EventChannel.StreamHandler {
  companion object {
    private const val EVENT_CHANNEL = "carrotlink/native_drive_video_events"
    private const val CONTROL_CHANNEL = "carrotlink/native_drive_video_control"

    @Volatile private var appContext: Context? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val offlineDebugThread =
        HandlerThread("CarrotYoloOfflineDebug").apply { start() }
    private val offlineDebugHandler = Handler(offlineDebugThread.looper)
    private val views = ConcurrentHashMap<Int, NativeDriveVideoView>()
    private val offlineVideoDebugSessionLock = Any()
    private var offlineVideoDebugSession: OfflineVideoDebugSession? = null

    private data class OfflineVideoDebugSession(
        val path: String,
        val baseSignature: String,
        val runtime: NativeDriveYoloRuntime,
        val retriever: MediaMetadataRetriever,
        var activeConfig: NativeDriveYoloConfig,
        var sourceWidth: Int = 0,
        var sourceHeight: Int = 0,
        var frameCounter: Int = 0,
        var framesSeen: Int = 0,
        var framesSampled: Int = 0,
        var framesSkipped: Int = 0,
        var lastFrameId: Int = -1,
        var lastFramePtsUs: Long = 0L,
        var lastSkipReason: String = "idle",
    )

    private fun requiresQnnLoweredPlaybackModel(
        config: NativeDriveYoloConfig,
    ): Boolean {
      val backend = config.runtimeBackend.trim().lowercase()
      if (!backend.contains("qnn")) return false
      return !NativeDriveYoloModelCatalog.isQnnLoweredReference(config.modelVariant)
    }

    private fun buildOfflineQnnModelMismatchResult(
        config: NativeDriveYoloConfig,
        path: String,
        reason: String,
        positionMs: Long? = null,
        decodedWidth: Int? = null,
        decodedHeight: Int? = null,
        videoDurationMs: Long? = null,
        videoSampleTimesMs: List<Long>? = null,
    ): Map<String, Any?> {
      val suggestedQnnWireValue =
          NativeDriveYoloModelCatalog.suggestedQnnWireValueFor(config.modelVariant)
      val suggestedQnnAssetFile =
          suggestedQnnWireValue?.let { "$it.pte" }
      Log.w(
          NATIVE_VIDEO_TAG,
          "Offline playback blocked reason=$reason backend=${config.runtimeBackend} " +
              "model=${config.modelVariant} path=$path positionMs=${positionMs ?: -1L}",
      )
      val state =
          NativeDriveYoloRuntimeSnapshot(
                  runtimeReady = false,
                  pixelPathReady = false,
                  stage = "awaiting_qnn_lowered_model",
                  blocker = "qnn_model_not_lowered",
                  backend = config.runtimeBackend,
                  backendAvailable = true,
                  backendReason = "qnn_model_not_lowered",
                  modelVariant = config.modelVariant,
                  lastError =
                      buildString {
                        append(
                            "Generic ExecuTorch/XNNPACK .pte is not safe for offline playback when " +
                                "runtimeBackend=${config.runtimeBackend}; export or select a " +
                                "QNN-lowered model",
                        )
                        if (!suggestedQnnAssetFile.isNullOrBlank()) {
                          append(" such as $suggestedQnnAssetFile")
                        }
                        append(".")
                      },
              )
              .toPayload()
              .toMutableMap()
      state["reason"] = reason
      state["syncSource"] = "developer_playback"
      state["inputPath"] = path
      state["decodedWidth"] = decodedWidth ?: config.sourceWidth
      state["decodedHeight"] = decodedHeight ?: config.sourceHeight
      state["videoDurationMs"] = videoDurationMs
      state["videoSampleTimesMs"] = videoSampleTimesMs
      state["positionMs"] = positionMs
      state["playbackRequestedPositionMs"] = positionMs
      state["framesSeen"] = 0
      state["framesSampled"] = 0
      state["framesSkipped"] = 0
      state["lastFrameId"] = -1
      state["lastFramePtsUs"] = 0L
      state["playbackFrameId"] = -1
      state["playbackFramePtsUs"] = 0L
      state["playbackFrameToken"] = null
      state["samplePeriodMs"] = config.samplePeriodMs
      state["lastSkipReason"] = "qnn_model_not_lowered"
      state["copyInFlight"] = false
      state["copyRequests"] = 0
      state["copySuccesses"] = 0
      state["copyFailures"] = 0
      state["copySkippedBusy"] = 0
      state["lastCopyResult"] = "offline_qnn_model_blocked"
      state["sessionMode"] = "video_playback"
      state["sessionFrameCounter"] = 0
      state["suggestedQnnModelVariant"] = suggestedQnnWireValue
      state["suggestedQnnAssetFile"] = suggestedQnnAssetFile
      return mapOf(
          "config" to config.toPayload(),
          "state" to state,
      )
    }

    fun emit(event: Map<String, Any?>) {
      mainHandler.post {
        eventSink?.success(event)
      }
    }

    private fun runOfflineDebugAsync(
        result: MethodChannel.Result,
        work: () -> Any?,
    ) {
      offlineDebugHandler.post {
        try {
          val payload = work()
          mainHandler.post { result.success(payload) }
        } catch (t: Throwable) {
          val message =
              t.stackTraceToString().lineSequence().firstOrNull()?.trim().orEmpty().ifBlank {
                t.message ?: t::class.java.simpleName
              }
          mainHandler.post { result.error("offline_debug_failed", message, null) }
        }
      }
    }

    private fun prepareOfflineRuntimeForPlayback(
        runtime: NativeDriveYoloRuntime,
        config: NativeDriveYoloConfig,
    ) {
      val backend = config.runtimeBackend.trim().lowercase()
      // LiteRT runtimes initialize on their own inference thread; no main-thread dispatch needed.
      // The main-thread QNN init path only applies to the ExecuTorch QNN backend.
      if (!backend.contains("qnn") || runtime !is NativeDriveExecuTorchRuntime) {
        runtime.updateConfig(config)
        return
      }
      if (Looper.myLooper() == Looper.getMainLooper()) {
        runtime.updateConfig(config)
        return
      }
      val latch = CountDownLatch(1)
      var failure: Throwable? = null
      mainHandler.post {
        try {
          runtime.updateConfig(config)
        } catch (t: Throwable) {
          failure = t
        } finally {
          latch.countDown()
        }
      }
      val completed = latch.await(8, TimeUnit.SECONDS)
      if (!completed) {
        throw IllegalStateException("offline_qnn_runtime_prepare_timeout")
      }
      failure?.let { throw it }
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

    fun updateYoloConfig(viewId: Int, yoloConfig: Map<String, Any?>?): Boolean {
      val view = views[viewId] ?: return false
      return view.updateYoloConfig(yoloConfig)
    }

    fun getYoloState(viewId: Int): Map<String, Any?>? {
      val view = views[viewId] ?: return null
      return view.getYoloState()
    }

    fun clearYoloDebugVideoSession(): Boolean {
      synchronized(offlineVideoDebugSessionLock) {
        releaseOfflineVideoDebugSessionLocked()
      }
      return true
    }

    fun runYoloDebugImageFile(
        path: String,
        yoloConfig: Map<String, Any?>?,
    ): Map<String, Any?>? {
      val context = appContext ?: return null
      val sourceBitmap = BitmapFactory.decodeFile(path) ?: return null
      var scaledBitmap: Bitmap? = null
      val baseConfig = NativeDriveYoloConfig.fromPayload(yoloConfig)
      val activeConfig =
          baseConfig.copy(
              enabled = true,
              sourceWidth = sourceBitmap.width,
              sourceHeight = sourceBitmap.height,
          )
      if (requiresQnnLoweredPlaybackModel(activeConfig)) {
        return buildOfflineQnnModelMismatchResult(
            config = activeConfig,
            path = path,
            reason = "offline_image_qnn_model_blocked",
            decodedWidth = sourceBitmap.width,
            decodedHeight = sourceBitmap.height,
        )
      }
      val runtime = createNativeDriveYoloRuntime(context, activeConfig.runtimeBackend)
      return try {
        prepareOfflineRuntimeForPlayback(runtime, activeConfig)
        val frame =
            NativeDriveYoloFrame(
                frameId = 1,
                ptsUs = System.nanoTime() / 1000L,
                camera = activeConfig.camera,
                sourceWidth = sourceBitmap.width,
                sourceHeight = sourceBitmap.height,
                fpsHint = 30f,
            )
        runtime.onSampledFrame(frame)
        scaledBitmap =
            if (sourceBitmap.width == activeConfig.inputWidth &&
                sourceBitmap.height == activeConfig.inputHeight) {
              sourceBitmap
            } else {
              Bitmap.createScaledBitmap(
                  sourceBitmap,
                  activeConfig.inputWidth.coerceAtLeast(32),
                  activeConfig.inputHeight.coerceAtLeast(32),
                  true,
              )
            }
        runtime.onPixelFrame(frame, scaledBitmap!!)
        val state = runtime.snapshot().toPayload().toMutableMap()
        state["reason"] = "offline_image_debug"
        state["inputPath"] = path
        state["decodedWidth"] = sourceBitmap.width
        state["decodedHeight"] = sourceBitmap.height
        state["framesSeen"] = 1
        state["framesSampled"] = 1
        state["framesSkipped"] = 0
        state["lastFrameId"] = frame.frameId
        state["lastFramePtsUs"] = frame.ptsUs
        state["samplePeriodMs"] = activeConfig.samplePeriodMs
        state["lastSkipReason"] = "offline_image_debug"
        state["copyInFlight"] = false
        state["copyRequests"] = 0
        state["copySuccesses"] = 0
        state["copyFailures"] = 0
        state["copySkippedBusy"] = 0
        state["lastCopyResult"] = "offline_debug_bypass"
        mapOf(
            "config" to activeConfig.toPayload(),
            "state" to state,
        )
      } finally {
        runtime.release()
        if (scaledBitmap != null && scaledBitmap !== sourceBitmap && !scaledBitmap!!.isRecycled) {
          scaledBitmap!!.recycle()
        }
        if (!sourceBitmap.isRecycled) {
          sourceBitmap.recycle()
        }
      }
    }

    fun runYoloDebugVideoFile(
        path: String,
        yoloConfig: Map<String, Any?>?,
        sampleFrames: Int = 3,
    ): Map<String, Any?>? {
      val context = appContext ?: return null
      val retriever = MediaMetadataRetriever()
      val baseConfig = NativeDriveYoloConfig.fromPayload(yoloConfig)
      val runtime = createNativeDriveYoloRuntime(context, baseConfig.runtimeBackend)
      var sourceWidth = 0
      var sourceHeight = 0
      return try {
        retriever.setDataSource(path)
        val durationMs =
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?.coerceAtLeast(1L) ?: 1L
        sourceWidth =
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
        sourceHeight =
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0

        val activeConfig =
            baseConfig.copy(
                enabled = true,
                sourceWidth = sourceWidth.coerceAtLeast(baseConfig.sourceWidth),
                sourceHeight = sourceHeight.coerceAtLeast(baseConfig.sourceHeight),
            )
        val requestedSamples = sampleFrames.coerceIn(1, 8)
        val sampleTimesMs =
            if (requestedSamples <= 1) {
              listOf(durationMs / 2L)
            } else {
              (0 until requestedSamples).map { index ->
                val fraction = (index + 1).toDouble() / (requestedSamples + 1).toDouble()
                (durationMs * fraction).toLong().coerceIn(0L, durationMs)
              }
            }
        if (requiresQnnLoweredPlaybackModel(activeConfig)) {
          return buildOfflineQnnModelMismatchResult(
              config = activeConfig,
              path = path,
              reason = "offline_video_qnn_model_blocked",
              decodedWidth = sourceWidth,
              decodedHeight = sourceHeight,
              videoDurationMs = durationMs,
              videoSampleTimesMs = sampleTimesMs,
          )
        }
        prepareOfflineRuntimeForPlayback(runtime, activeConfig)

        var actualFrames = 0
        var lastFrameId = -1
        var lastPtsUs = 0L

        for ((index, sampleMs) in sampleTimesMs.withIndex()) {
          val bitmap =
              retriever.getFrameAtTime(
                  sampleMs * 1000L,
                  MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
              ) ?: continue
          val frame =
              NativeDriveYoloFrame(
                  frameId = index + 1,
                  ptsUs = sampleMs * 1000L,
                  camera = activeConfig.camera,
                  sourceWidth = bitmap.width,
                  sourceHeight = bitmap.height,
                  fpsHint = 30f,
              )
          lastFrameId = frame.frameId
          lastPtsUs = frame.ptsUs
          runtime.onSampledFrame(frame)
          val scaledBitmap =
              if (bitmap.width == activeConfig.inputWidth &&
                  bitmap.height == activeConfig.inputHeight) {
                bitmap
              } else {
                Bitmap.createScaledBitmap(
                    bitmap,
                    activeConfig.inputWidth.coerceAtLeast(32),
                    activeConfig.inputHeight.coerceAtLeast(32),
                    true,
                )
              }
          try {
            runtime.onPixelFrame(frame, scaledBitmap)
            actualFrames += 1
          } finally {
            if (scaledBitmap !== bitmap && !scaledBitmap.isRecycled) {
              scaledBitmap.recycle()
            }
            if (!bitmap.isRecycled) {
              bitmap.recycle()
            }
          }
        }

        val state = runtime.snapshot().toPayload().toMutableMap()
        state["reason"] = "offline_video_debug"
        state["inputPath"] = path
        state["decodedWidth"] = sourceWidth
        state["decodedHeight"] = sourceHeight
        state["videoDurationMs"] = durationMs
        state["videoSampleTimesMs"] = sampleTimesMs
        state["framesSeen"] = actualFrames
        state["framesSampled"] = actualFrames
        state["framesSkipped"] = 0
        state["lastFrameId"] = lastFrameId
        state["lastFramePtsUs"] = lastPtsUs
        state["samplePeriodMs"] = activeConfig.samplePeriodMs
        state["lastSkipReason"] = if (actualFrames > 0) "offline_video_debug" else "video_frame_missing"
        state["copyInFlight"] = false
        state["copyRequests"] = 0
        state["copySuccesses"] = 0
        state["copyFailures"] = 0
        state["copySkippedBusy"] = 0
        state["lastCopyResult"] = "offline_debug_bypass"
        mapOf(
            "config" to activeConfig.toPayload(),
            "state" to state,
        )
      } finally {
        runtime.release()
        try {
          retriever.release()
        } catch (_: Throwable) {
        }
      }
    }

    fun runYoloDebugVideoFrame(
        path: String,
        yoloConfig: Map<String, Any?>?,
        positionMs: Long,
    ): Map<String, Any?>? {
      val context = appContext ?: return null
      val baseConfig = NativeDriveYoloConfig.fromPayload(yoloConfig).copy(enabled = true)
      Log.i(
          NATIVE_VIDEO_TAG,
          "runYoloDebugVideoFrame backend=${baseConfig.runtimeBackend} " +
              "model=${baseConfig.modelVariant} positionMs=$positionMs path=$path",
      )
      if (requiresQnnLoweredPlaybackModel(baseConfig)) {
        return buildOfflineQnnModelMismatchResult(
            config = baseConfig,
            path = path,
            reason = "offline_video_frame_qnn_model_blocked",
            positionMs = positionMs,
        )
      }
      val session =
          synchronized(offlineVideoDebugSessionLock) {
            obtainOfflineVideoDebugSessionLocked(path, baseConfig, context)
          }
      val sourceBitmap =
          session.retriever.getFrameAtTime(
              positionMs.coerceAtLeast(0L) * 1000L,
              MediaMetadataRetriever.OPTION_CLOSEST,
          )
      if (sourceBitmap == null) {
        synchronized(offlineVideoDebugSessionLock) {
          session.framesSkipped += 1
          session.lastSkipReason = "video_frame_missing"
          return buildOfflineVideoFrameDebugResultLocked(
              session = session,
              activeConfig = session.activeConfig,
              positionMs = positionMs,
              reason = "offline_video_frame_missing",
          )
        }
      }
      val activeConfig =
          baseConfig.copy(
              sourceWidth = sourceBitmap.width,
              sourceHeight = sourceBitmap.height,
          )
      val scaledBitmap =
          if (sourceBitmap.width == activeConfig.inputWidth &&
              sourceBitmap.height == activeConfig.inputHeight) {
            sourceBitmap
          } else {
            Bitmap.createScaledBitmap(
                sourceBitmap,
                activeConfig.inputWidth.coerceAtLeast(32),
                activeConfig.inputHeight.coerceAtLeast(32),
                true,
            )
          }
      try {
        synchronized(offlineVideoDebugSessionLock) {
          session.activeConfig = activeConfig
          session.sourceWidth = sourceBitmap.width
          session.sourceHeight = sourceBitmap.height
          session.runtime.updateConfig(activeConfig)
          val frame =
              NativeDriveYoloFrame(
                  frameId = session.frameCounter + 1,
                  ptsUs = positionMs.coerceAtLeast(0L) * 1000L,
                  camera = activeConfig.camera,
                  sourceWidth = sourceBitmap.width,
                  sourceHeight = sourceBitmap.height,
                  fpsHint = 30f,
              )
          session.frameCounter = frame.frameId
          session.framesSeen += 1
          session.framesSampled += 1
          session.lastFrameId = frame.frameId
          session.lastFramePtsUs = frame.ptsUs
          session.runtime.onSampledFrame(frame)
          session.runtime.onPixelFrame(frame, scaledBitmap)
          session.lastSkipReason = "offline_video_playback_debug"
          return buildOfflineVideoFrameDebugResultLocked(
              session = session,
              activeConfig = activeConfig,
              positionMs = positionMs,
              reason = "offline_video_playback_debug",
          )
        }
      } finally {
        if (scaledBitmap !== sourceBitmap && !scaledBitmap.isRecycled) {
          scaledBitmap.recycle()
        }
        if (!sourceBitmap.isRecycled) {
          sourceBitmap.recycle()
        }
      }
    }

    private fun obtainOfflineVideoDebugSessionLocked(
        path: String,
        baseConfig: NativeDriveYoloConfig,
        context: Context,
    ): OfflineVideoDebugSession {
      val signature = buildOfflineVideoDebugConfigSignature(baseConfig)
      val existing = offlineVideoDebugSession
      if (existing != null &&
          existing.path == path &&
          existing.baseSignature == signature) {
        return existing
      }
      releaseOfflineVideoDebugSessionLocked()
      val retriever = MediaMetadataRetriever().apply { setDataSource(path) }
      val sourceWidth =
          retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
              ?.toIntOrNull() ?: 0
      val sourceHeight =
          retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
              ?.toIntOrNull() ?: 0
      val session =
          OfflineVideoDebugSession(
              path = path,
              baseSignature = signature,
              runtime = createNativeDriveYoloRuntime(context, baseConfig.runtimeBackend),
              retriever = retriever,
              activeConfig = baseConfig,
              sourceWidth = sourceWidth,
              sourceHeight = sourceHeight,
          )
      return try {
        prepareOfflineRuntimeForPlayback(session.runtime, baseConfig)
        session.also { offlineVideoDebugSession = it }
      } catch (t: Throwable) {
        try {
          session.runtime.release()
        } catch (_: Throwable) {
        }
        try {
          session.retriever.release()
        } catch (_: Throwable) {
        }
        throw t
      }
    }

    private fun releaseOfflineVideoDebugSessionLocked() {
      val existing = offlineVideoDebugSession ?: return
      try {
        existing.runtime.release()
      } catch (_: Throwable) {
      }
      try {
        existing.retriever.release()
      } catch (_: Throwable) {
      }
      offlineVideoDebugSession = null
    }

    private fun buildOfflineVideoDebugConfigSignature(
        config: NativeDriveYoloConfig,
    ): String {
      return listOf(
              config.enabled,
              config.showBoxes,
              config.showLabels,
              config.showTrafficLights,
              config.showStats,
              config.unsafeRuntimeEnabled,
              config.runtimeBackend,
              config.modelVariant,
              config.camera,
              config.inputWidth,
              config.inputHeight,
              config.samplePeriodMs,
          )
          .joinToString("|")
    }

    private fun buildOfflineVideoFrameDebugResultLocked(
        session: OfflineVideoDebugSession,
        activeConfig: NativeDriveYoloConfig,
        positionMs: Long,
        reason: String,
    ): Map<String, Any?> {
      val state = session.runtime.snapshot().toPayload().toMutableMap()
      val playbackFrameId = session.lastFrameId
      val playbackFramePtsUs = session.lastFramePtsUs
      state["reason"] = reason
      state["syncSource"] = "developer_playback"
      state["inputPath"] = session.path
      state["positionMs"] = positionMs
      state["playbackRequestedPositionMs"] = positionMs
      state["decodedWidth"] = session.sourceWidth.coerceAtLeast(activeConfig.sourceWidth)
      state["decodedHeight"] = session.sourceHeight.coerceAtLeast(activeConfig.sourceHeight)
      state["framesSeen"] = session.framesSeen
      state["framesSampled"] = session.framesSampled
      state["framesSkipped"] = session.framesSkipped
      state["lastFrameId"] = playbackFrameId
      state["lastFramePtsUs"] = playbackFramePtsUs
      state["playbackFrameId"] = playbackFrameId
      state["playbackFramePtsUs"] = playbackFramePtsUs
      state["playbackFrameToken"] = "video_playback:$playbackFramePtsUs:$playbackFrameId"
      state["samplePeriodMs"] = activeConfig.samplePeriodMs
      state["lastSkipReason"] = session.lastSkipReason
      state["copyInFlight"] = false
      state["copyRequests"] = 0
      state["copySuccesses"] = 0
      state["copyFailures"] = 0
      state["copySkippedBusy"] = 0
      state["lastCopyResult"] = "offline_video_playback_debug"
      state["sessionMode"] = "video_playback"
      state["sessionFrameCounter"] = session.frameCounter
      return mapOf(
          "config" to activeConfig.toPayload(),
          "state" to state,
      )
    }

    fun clearOverlay(viewId: Int): Boolean {
      val view = views[viewId] ?: return false
      return view.clearOverlay()
    }
  }

  private var controlChannel: MethodChannel? = null

  fun register(context: Context, registry: PlatformViewRegistry) {
    appContext = context.applicationContext
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
                result.success(updateOverlay(viewId, overlay))
              }

              "updateYoloConfig" -> {
                val viewId = (call.argument<Number>("viewId") ?: -1).toInt()
                @Suppress("UNCHECKED_CAST")
                val yoloConfig = call.argument<Map<String, Any?>>("yoloConfig")
                result.success(updateYoloConfig(viewId, yoloConfig))
              }

              "clearOverlay" -> {
                val viewId = (call.argument<Number>("viewId") ?: -1).toInt()
                result.success(clearOverlay(viewId))
              }

              "getYoloState" -> {
                val viewId = (call.argument<Number>("viewId") ?: -1).toInt()
                result.success(getYoloState(viewId))
              }

              "runYoloDebugImageFile" -> {
                val path = call.argument<String>("path")?.trim().orEmpty()
                @Suppress("UNCHECKED_CAST")
                val yoloConfig = call.argument<Map<String, Any?>>("yoloConfig")
                if (path.isBlank()) {
                  result.error("invalid_path", "path is blank", null)
                } else {
                  runOfflineDebugAsync(result) { runYoloDebugImageFile(path, yoloConfig) }
                }
              }

              "runYoloDebugVideoFile" -> {
                val path = call.argument<String>("path")?.trim().orEmpty()
                @Suppress("UNCHECKED_CAST")
                val yoloConfig = call.argument<Map<String, Any?>>("yoloConfig")
                val sampleFrames = (call.argument<Number>("sampleFrames") ?: 3).toInt()
                if (path.isBlank()) {
                  result.error("invalid_path", "path is blank", null)
                } else {
                  runOfflineDebugAsync(result) {
                    runYoloDebugVideoFile(path, yoloConfig, sampleFrames)
                  }
                }
              }

              "runYoloDebugVideoFrame" -> {
                val path = call.argument<String>("path")?.trim().orEmpty()
                @Suppress("UNCHECKED_CAST")
                val yoloConfig = call.argument<Map<String, Any?>>("yoloConfig")
                val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                if (path.isBlank()) {
                  result.error("invalid_path", "path is blank", null)
                } else {
                  runOfflineDebugAsync(result) {
                    runYoloDebugVideoFrame(path, yoloConfig, positionMs)
                  }
                }
              }

              "clearYoloDebugVideoSession" -> {
                result.success(clearYoloDebugVideoSession())
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
  private val yoloController =
      NativeDriveYoloController(
          surfaceView = surfaceView,
          onStateChanged = { payload ->
            emitYoloState(payload)
          },
          runtimeFactory = { backend -> createNativeDriveYoloRuntime(context, backend) },
          initialRuntime =
              createNativeDriveYoloRuntime(
                  context,
                  NativeDriveYoloConfig.DEFAULT_RUNTIME_BACKEND,
              ),
          initialRuntimeBackend = NativeDriveYoloConfig.DEFAULT_RUNTIME_BACKEND,
      )
  private val reconnectHandler = Handler(Looper.getMainLooper())
  private val decodeThread = HandlerThread("CarrotNativeDecode-$viewId").apply { start() }
  private val decodeHandler = Handler(decodeThread.looper)
  private val okHttpClient =
      OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build()

  @Volatile private var webSocket: WebSocket? = null
  @Volatile private var surface: Surface? = null
  @Volatile private var codec: MediaCodec? = null
  @Volatile private var codecConfigured = false
  @Volatile private var waitingKeyFrame = true
  @Volatile private var closed = false
  @Volatile private var lastSourceFrameId = -1
  @Volatile private var nextRenderedFrameId = 0
  @Volatile private var currentWidth = 0
  @Volatile private var currentHeight = 0
  @Volatile private var connectAttempts = 0
  @Volatile private var lastPacketAtMs = 0L
  @Volatile private var lastDecodedAtMs = 0L
  @Volatile private var lastFrameEmitAtMs = 0L
  @Volatile private var firstDecodedWithoutSyncAtMs = 0L
  private val pendingFrames: ArrayDeque<PendingFrame> = ArrayDeque()
  @Volatile private var pendingSyncFrameCount = 0
  private val pendingDecodeTasks = AtomicInteger(0)
  @Volatile private var frameStallStrikes = 0
  @Volatile private var startupSyncFrameStrikes = 0
  @Volatile private var decodeBacklogDropCount = 0
  @Volatile private var missingSourceFrameIdCount = 0
  @Volatile private var syntheticFrameEmitCount = 0
  @Volatile private var syntheticSyncActive = false
  @Volatile private var lastSourceFrameKey = ""
  @Volatile private var lastSourceFrameCandidates = ""
  @Volatile private var lastMetaKeySummary = ""
  @Volatile private var lastParsedMetaPreview = ""
  @Volatile private var lastParsedMetaLength = -1
  @Volatile private var lastParsedFrameIdRaw = ""
  @Volatile private var lastParsedFrameFieldSummary = ""

  private var reconnectRunnable: Runnable? = null
  private var frameWatchdogRunnable: Runnable? = null
  private val cameraName: String = parseCameraName(wsUrl)
  private val surfaceInitialConnectDebounceMs = 140L
  private val frameWatchdogIntervalMs = 700L
  private val frameStallTimeoutMs = 7000L
  private val frameDecodeStallTimeoutMs = 6500L
  private val frameStallStrikeLimit = 4
  private val frameHardReconnectMs = 24000L
  private val frameDecodeHardReconnectMs = 18000L
  private val startupFirstFrameSoftTimeoutMs = 2500L
  private val startupFirstFrameHardTimeoutMs = 5000L
  private val startupSyncFrameSoftTimeoutMs = 1400L
  private val startupSyncFrameHardTimeoutMs = 2600L
  private val startupSyncFrameStrikeLimit = 2
  private val frameStallStateEmitEvery = 2
  private val decodeTaskBacklogLimit = 1
  private val codecBacklogLimit = 1
  private val decodeBacklogStateEmitEvery = 24
  private val diagIntervalMs = 1000L
  @Volatile private var hintedFrameRate = 30f
  @Volatile private var performanceHintTargetNs = 33_333_333L
  @Volatile private var performanceHintSession: PerformanceHintManager.Session? = null
  @Volatile private var currentStateLabel = "init"
  @Volatile private var stateEnteredAtMs = System.currentTimeMillis()
  @Volatile private var lastErrorReason: String? = null
  @Volatile private var lastErrorAtMs = 0L
  @Volatile private var packetsWindow = 0
  @Volatile private var decodedWindow = 0
  @Volatile private var dropsWindow = 0
  @Volatile private var packetBytesWindow = 0L
  private var diagRunnable: Runnable? = null

  private data class PendingFrame(
      val yoloFrameId: Int,
      val syncFrameId: Int?,
  )

  private data class SourceFrameIdResult(
      val frameId: Int,
      val key: String?,
      val candidatesSummary: String,
  )

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
    startDiagSummary()
    emitState("init")
  }

  override fun getView(): View = rootView

  override fun dispose() {
    closed = true
    clearReconnect()
    stopFrameWatchdog()
    stopDiagSummary()
    closeSocket()
    clearSurfaceFrameRateHint()
    closePerformanceHintSession()
    releaseDecoder()
    yoloController.release()
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
    scheduleReconnect(surfaceInitialConnectDebounceMs)
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
    startupSyncFrameStrikes = 0
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
                startupSyncFrameStrikes = 0
                startFrameWatchdog()
                emitState("connected")
              }

              override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                if (!isCurrentSocket(webSocket)) return
                lastPacketAtMs = System.currentTimeMillis()
                val copy = bytes.toByteArray()
                packetsWindow += 1
                packetBytesWindow += copy.size.toLong()
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
                scheduleReconnect(450)
              }

              override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!isCurrentSocket(webSocket)) return
                stopFrameWatchdog()
                this@NativeDriveVideoView.webSocket = null
                emitState("closed:$code")
                scheduleReconnect(450)
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
    lastFrameEmitAtMs = 0L
    firstDecodedWithoutSyncAtMs = 0L
    frameStallStrikes = 0
    startupSyncFrameStrikes = 0
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
            val elapsedSynclessDecodeMs =
                if (firstDecodedWithoutSyncAtMs <= 0L) {
                  -1L
                } else {
                  now - firstDecodedWithoutSyncAtMs
                }
            val packetStalled = elapsedPacketMs > frameStallTimeoutMs
            val decodeStalled = codecConfigured && elapsedDecodedMs > frameDecodeStallTimeoutMs
            val waitingFirstFrame = codecConfigured && waitingKeyFrame
            val startupFirstFrameStalled =
                waitingFirstFrame && elapsedDecodedMs > startupFirstFrameSoftTimeoutMs
            val startupSyncFrameStalled =
                codecConfigured &&
                    !waitingKeyFrame &&
                    lastFrameEmitAtMs <= 0L &&
                    elapsedSynclessDecodeMs > startupSyncFrameSoftTimeoutMs
            val ordinaryStall = packetStalled || decodeStalled || startupFirstFrameStalled
            if (webSocket != null &&
                (ordinaryStall || startupSyncFrameStalled)) {
              if (ordinaryStall) {
                frameStallStrikes += 1
              } else {
                frameStallStrikes = 0
              }
              if (startupSyncFrameStalled) {
                startupSyncFrameStrikes += 1
              } else {
                startupSyncFrameStrikes = 0
              }
              val activeStrikes =
                  if (startupSyncFrameStalled && !ordinaryStall) {
                    startupSyncFrameStrikes
                  } else {
                    frameStallStrikes
                  }
              if (activeStrikes == 1 || activeStrikes % frameStallStateEmitEvery == 0) {
                if (startupFirstFrameStalled) {
                  emitState("waiting_keyframe_${elapsedDecodedMs}ms")
                } else if (startupSyncFrameStalled) {
                  emitState("waiting_sync_frame_${elapsedSynclessDecodeMs}ms")
                } else {
                  emitState("stalling_pkt_${elapsedPacketMs}ms_dec_${elapsedDecodedMs}ms")
                }
              }
              val packetHardStall = elapsedPacketMs > frameHardReconnectMs
              val decodeHardStall = codecConfigured && elapsedDecodedMs > frameDecodeHardReconnectMs
              val startupFirstFrameHardStall =
                  waitingFirstFrame && elapsedDecodedMs > startupFirstFrameHardTimeoutMs
              val startupSyncFrameHardStall =
                  codecConfigured &&
                      !waitingKeyFrame &&
                      lastFrameEmitAtMs <= 0L &&
                      elapsedSynclessDecodeMs > startupSyncFrameHardTimeoutMs
              val strikeLimit =
                  if (startupSyncFrameHardStall) startupSyncFrameStrikeLimit else frameStallStrikeLimit
              if ((packetHardStall ||
                      decodeHardStall ||
                      startupFirstFrameHardStall ||
                      startupSyncFrameHardStall) &&
                  activeStrikes >= strikeLimit) {
                if (startupFirstFrameHardStall) {
                  emitError("startup_keyframe_timeout_${elapsedDecodedMs}ms")
                } else if (startupSyncFrameHardStall) {
                  emitError("startup_sync_frame_timeout_${elapsedSynclessDecodeMs}ms")
                } else {
                  emitError("frame_stall_pkt_${elapsedPacketMs}ms_dec_${elapsedDecodedMs}ms")
                }
                stopFrameWatchdog()
                closeSocket()
                releaseDecoder()
                scheduleReconnect(
                    if (startupFirstFrameHardStall || startupSyncFrameHardStall) 250 else 350)
                return
              }
            } else {
              if (frameStallStrikes > 0 || startupSyncFrameStrikes > 0) {
                emitState("recovered")
              }
              frameStallStrikes = 0
              startupSyncFrameStrikes = 0
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

  fun updateYoloConfig(yoloConfig: Map<String, Any?>?): Boolean {
    if (closed) return false
    val parsed = NativeDriveYoloConfig.fromPayload(yoloConfig)
    overlayView.updateYoloConfig(parsed)
    yoloController.updateConfig(parsed)
    emitYoloConfig(parsed)
    return true
  }

  fun getYoloState(): Map<String, Any?> {
    return yoloController.snapshot(reason = "method_fetch")
  }

  fun clearOverlay(): Boolean {
    overlayView.clearOverlay()
    return true
  }

  private fun releaseDecoder() {
    codecConfigured = false
    waitingKeyFrame = true
    lastSourceFrameId = -1
    nextRenderedFrameId = 0
    lastFrameEmitAtMs = 0L
    firstDecodedWithoutSyncAtMs = 0L
    frameStallStrikes = 0
    startupSyncFrameStrikes = 0
    missingSourceFrameIdCount = 0
    syntheticFrameEmitCount = 0
    syntheticSyncActive = false
    lastSourceFrameKey = ""
    lastSourceFrameCandidates = ""
    lastMetaKeySummary = ""
    lastParsedMetaPreview = ""
    lastParsedMetaLength = -1
    lastParsedFrameIdRaw = ""
    lastParsedFrameFieldSummary = ""
    pendingDecodeTasks.set(0)
    pendingFrames.clear()
    pendingSyncFrameCount = 0
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
      val metaText: String,
  )

  private fun noteBacklogDrop(reason: String, backlog: Int) {
    decodeBacklogDropCount += 1
    dropsWindow += 1
    if (decodeBacklogDropCount == 1 || decodeBacklogDropCount % decodeBacklogStateEmitEvery == 0) {
      emitState("drop_${reason}_n${decodeBacklogDropCount}_b$backlog")
    }
  }

  private fun handlePacket(packet: ByteArray) {
    if (closed) return
    if (surface == null || !surface!!.isValid) return

    val parsed = parsePacket(packet) ?: return
    val meta = parsed.meta
    rememberParsedMeta(meta, parsed.metaText)
    val sourceFrame = extractSourceFrameId(meta)
    val sourceFrameId = sourceFrame.frameId
    lastSourceFrameCandidates = sourceFrame.candidatesSummary
    if (!sourceFrame.key.isNullOrBlank()) {
      lastSourceFrameKey = sourceFrame.key
    } else {
      missingSourceFrameIdCount += 1
      if (lastMetaKeySummary.isBlank() || missingSourceFrameIdCount <= 3) {
        lastMetaKeySummary = summarizeMetaKeys(meta)
      }
    }
    if (sourceFrameId >= 0 && lastSourceFrameId >= 0 && sourceFrameId <= lastSourceFrameId) {
      return
    }
    val frameId = if (sourceFrameId >= 0) sourceFrameId else nextRenderedFrameId++
    val keyByMeta =
        meta.optBoolean("keyFrame", false) || ((meta.optInt("flags", 0) and 0x8) != 0)
    val annexb =
        toAnnexB(
            parsed.payload,
            keyByMeta || looksLikeAvcDecoderConfig(parsed.payload),
        ) ?: return
    val keyByBitstream = isAnnexBKeyFrame(annexb)
    val isKey = keyByMeta || keyByBitstream
    val queuedTasks = pendingDecodeTasks.get()
    if (queuedTasks > (decodeTaskBacklogLimit + 1) && !isKey) {
      noteBacklogDrop("task", queuedTasks)
      return
    }
    if (pendingSyncFrameCount >= codecBacklogLimit && !isKey) {
      noteBacklogDrop("codec", pendingSyncFrameCount)
      return
    }
    if (sourceFrameId >= 0) {
      lastSourceFrameId = sourceFrameId
    }

    val width = meta.optInt("width", 0).coerceAtLeast(0)
    val height = meta.optInt("height", 0).coerceAtLeast(0)
    updateFrameRateHintFromMeta(meta)
    if (width > 0 && height > 0 && (width != currentWidth || height != currentHeight)) {
      currentWidth = width
      currentHeight = height
      emitMeta(width, height)
    }


    if (!codecConfigured) {
      if (!isKey) return
      val w = if (width > 0) width else 1928
      val h = if (height > 0) height else 1208
      if (!configureDecoder(w, h)) {
        emitError("decoder_init_failed")
        return
      }
    }

    if (waitingKeyFrame && !isKey) return
    waitingKeyFrame = false

    val ts =
        when {
          meta.has("timestampEof") -> meta.optLong("timestampEof")
          meta.has("timestampSof") -> meta.optLong("timestampSof")
          else -> System.nanoTime()
        }
    val ptsUs = if (ts > 0L) ts / 1000L else (System.nanoTime() / 1000L)
    queueFrame(
      frame = annexb,
      ptsUs = ptsUs,
      yoloFrameId = frameId,
      syncFrameId = if (sourceFrameId >= 0) sourceFrameId else null,
    )
  }

  private fun configureDecoder(width: Int, height: Int): Boolean {
    releaseDecoder()
    val s = surface ?: return false
    return try {
      val localCodec = MediaCodec.createDecoderByType("video/avc")
      // Hardware H.264 decoders (Snapdragon, Exynos) require dimensions aligned to
      // a multiple of 16. Non-aligned heights like 760 cause the decoder to silently
      // accept input but produce no output frames. Round up to the nearest 16-byte
      // boundary to avoid this issue; the SPS/PPS in the bitstream remains authoritative.
      val alignedWidth = (width + 15) and 15.inv()
      val alignedHeight = (height + 15) and 15.inv()
      val format = MediaFormat.createVideoFormat("video/avc", alignedWidth, alignedHeight)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
      }
      format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, alignedWidth * alignedHeight)
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

  private fun queueFrame(
      frame: ByteArray,
      ptsUs: Long,
      yoloFrameId: Int,
      syncFrameId: Int?,
  ) {
    val localCodec = codec ?: return
    try {
      val inputIndex = localCodec.dequeueInputBuffer(0)
      if (inputIndex < 0) {
        noteBacklogDrop("input", pendingSyncFrameCount)
        return
      }
      val input = localCodec.getInputBuffer(inputIndex) ?: return
      input.clear()
      input.put(frame)
      localCodec.queueInputBuffer(inputIndex, 0, frame.size, ptsUs, 0)
      pendingFrames.addLast(
          PendingFrame(
              yoloFrameId = yoloFrameId,
              syncFrameId = syncFrameId,
          ))
      if (syncFrameId != null && syncFrameId >= 0) {
        pendingSyncFrameCount += 1
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
          decodedWindow += 1
          reportPerformanceActualWork((System.nanoTime() - decodeStartNs).coerceAtLeast(1_000_000L))
          val renderedFrame =
              if (pendingFrames.isEmpty()) null else pendingFrames.removeFirst()
          val yoloFrameId = renderedFrame?.yoloFrameId ?: -1
          val syncFrameId = renderedFrame?.syncFrameId
          if (syncFrameId != null && syncFrameId >= 0) {
            pendingSyncFrameCount = (pendingSyncFrameCount - 1).coerceAtLeast(0)
            lastFrameEmitAtMs = lastDecodedAtMs
            firstDecodedWithoutSyncAtMs = 0L
            startupSyncFrameStrikes = 0
            if (syntheticSyncActive) {
              syntheticSyncActive = false
              emitState("sync_frame_restored")
            }
            emitFrame(syncFrameId, synthetic = false)
          } else if (lastFrameEmitAtMs <= 0L && firstDecodedWithoutSyncAtMs <= 0L) {
            firstDecodedWithoutSyncAtMs = lastDecodedAtMs
          }
          val synclessDecodeMs =
              if (firstDecodedWithoutSyncAtMs > 0L) {
                (lastDecodedAtMs - firstDecodedWithoutSyncAtMs).coerceAtLeast(0L)
              } else {
                -1L
              }
          if (syncFrameId == null &&
              yoloFrameId >= 0 &&
              (syntheticSyncActive || synclessDecodeMs >= startupSyncFrameSoftTimeoutMs)) {
            syntheticSyncActive = true
            syntheticFrameEmitCount += 1
            lastFrameEmitAtMs = lastDecodedAtMs
            startupSyncFrameStrikes = 0
            if (syntheticFrameEmitCount == 1) {
              emitState("synthetic_sync_frame_${synclessDecodeMs.coerceAtLeast(0L)}ms")
            }
            emitFrame(yoloFrameId, synthetic = true)
          }
          if (yoloFrameId >= 0) {
            yoloController.onFrameRendered(
                NativeDriveYoloFrame(
                    frameId = yoloFrameId,
                    ptsUs = info.presentationTimeUs,
                    camera = cameraName,
                    sourceWidth = currentWidth,
                    sourceHeight = currentHeight,
                    fpsHint = hintedFrameRate,
                ))
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
      ParsedPacket(meta, payload, metaText)
    } catch (_: Throwable) {
      null
    }
  }

  private fun rememberParsedMeta(meta: JSONObject, metaText: String) {
    lastParsedMetaLength = metaText.length
    val compact = metaText.replace('\n', ' ').replace('\r', ' ').trim()
    lastParsedMetaPreview = if (compact.length <= 240) compact else "${compact.take(237)}..."
    lastParsedFrameIdRaw =
        if (meta.has("frameId")) {
          summarizeMetaValue(meta.opt("frameId"))
        } else {
          "<absent>"
        }
    val keys =
        arrayOf(
            "frameId",
            "frame_id",
            "cameraFrameId",
            "camera",
            "width",
            "height",
            "keyFrame",
            "flags",
            "encodeId",
            "segmentId",
            "timestampSof",
            "timestampEof",
        )
    val parts = mutableListOf<String>()
    for (key in keys) {
      if (!meta.has(key)) continue
      parts.add("$key=${summarizeMetaValue(meta.opt(key))}")
      if (parts.size >= 8) break
    }
    lastParsedFrameFieldSummary = parts.joinToString("|")
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

  private fun looksLikeAvcDecoderConfig(data: ByteArray): Boolean {
    return data.size >= 7 && data[0].toInt() == 1
  }

  private fun isAnnexBKeyFrame(data: ByteArray): Boolean {
    var i = 0
    while (i + 4 < data.size) {
      var startLen = 0
      if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
        if (data[i + 2] == 1.toByte()) {
          startLen = 3
        } else if (i + 3 < data.size &&
            data[i + 2] == 0.toByte() &&
            data[i + 3] == 1.toByte()) {
          startLen = 4
        }
      }
      if (startLen == 0) {
        i += 1
        continue
      }
      val nalIndex = i + startLen
      if (nalIndex >= data.size) break
      when (data[nalIndex].toInt() and 0x1F) {
        5, 7, 8 -> return true
      }
      i = nalIndex + 1
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

  private fun emitFrame(frameId: Int, synthetic: Boolean = false) {
    NativeDriveVideoPlugin.emit(
        mapOf(
            "viewId" to viewId,
            "type" to "camera_frame",
            "camera" to cameraName,
            "frameId" to frameId,
            "synthetic" to synthetic,
        ))
  }

  private fun extractSourceFrameId(meta: JSONObject): SourceFrameIdResult {
    val keys =
        arrayOf(
            "frameId",
            "frame_id",
            "cameraFrameId",
            "camera_frame_id",
            "roadFrameId",
            "road_frame_id",
            "frameIndex",
            "frame_index",
            "index",
        )
    val candidates = mutableListOf<String>()
    for (key in keys) {
      if (!meta.has(key)) continue
      val raw = meta.opt(key)
      val parsed = parseIntLike(raw)
      if (candidates.size < 8) {
        candidates.add(
            if (parsed != null) {
              "$key=${summarizeMetaValue(raw)}->$parsed"
            } else {
              "$key=${summarizeMetaValue(raw)}"
            })
      }
      if (parsed != null && parsed >= 0) {
        return SourceFrameIdResult(parsed, key, candidates.joinToString("|"))
      }
    }
    return SourceFrameIdResult(-1, null, candidates.joinToString("|"))
  }

  private fun parseIntLike(value: Any?): Int? {
    return when (value) {
      null -> null
      is Number -> value.toInt()
      is String -> value.trim().toIntOrNull()
      else -> null
    }
  }

  private fun summarizeMetaKeys(meta: JSONObject, limit: Int = 8): String {
    val keys = mutableListOf<String>()
    val iterator = meta.keys()
    while (iterator.hasNext() && keys.size < limit) {
      keys.add(iterator.next())
    }
    keys.sort()
    return keys.joinToString(",")
  }

  private fun summarizeMetaValue(value: Any?): String {
    return when (value) {
      null, JSONObject.NULL -> "null"
      is String -> {
        val trimmed = value.trim()
        if (trimmed.length <= 40) {
          "\"$trimmed\""
        } else {
          "\"${trimmed.take(37)}...\""
        }
      }
      is Number, is Boolean -> value.toString()
      else -> {
        val raw = value.toString().trim()
        if (raw.length <= 40) raw else "${raw.take(37)}..."
      }
    }
  }

  private fun emitError(reason: String) {
    lastErrorReason = reason
    lastErrorAtMs = System.currentTimeMillis()
    NativeDriveVideoPlugin.emit(
        mapOf(
            "viewId" to viewId,
            "type" to "camera_error",
            "camera" to cameraName,
            "reason" to reason,
        ))
  }

  private fun emitState(state: String) {
    currentStateLabel = state
    stateEnteredAtMs = System.currentTimeMillis()
    NativeDriveVideoPlugin.emit(
        mapOf(
            "viewId" to viewId,
            "type" to "camera_state",
            "camera" to cameraName,
            "state" to state,
            "attempt" to connectAttempts,
        ))
  }

  private fun startDiagSummary() {
    stopDiagSummary()
    diagRunnable =
        object : Runnable {
          override fun run() {
            if (closed) return
            emitDiagSummary()
            reconnectHandler.postDelayed(this, diagIntervalMs)
          }
        }
    reconnectHandler.postDelayed(diagRunnable!!, diagIntervalMs)
  }

  private fun stopDiagSummary() {
    diagRunnable?.let { reconnectHandler.removeCallbacks(it) }
    diagRunnable = null
  }

  private fun emitDiagSummary() {
    val now = System.currentTimeMillis()
    val packetAgeMs = if (lastPacketAtMs <= 0L) -1L else (now - lastPacketAtMs)
    val decodeAgeMs = if (lastDecodedAtMs <= 0L) -1L else (now - lastDecodedAtMs)
    val stateAgeMs = (now - stateEnteredAtMs).coerceAtLeast(0L)
    val errorAgeMs = if (lastErrorAtMs <= 0L) -1L else (now - lastErrorAtMs)
    val packets = packetsWindow
    val decoded = decodedWindow
    val drops = dropsWindow
    val packetBytes = packetBytesWindow
    packetsWindow = 0
    decodedWindow = 0
    dropsWindow = 0
    packetBytesWindow = 0L
    NativeDriveVideoPlugin.emit(
        mapOf(
            "viewId" to viewId,
            "type" to "camera_diag",
            "camera" to cameraName,
            "state" to currentStateLabel,
            "stateAgeMs" to stateAgeMs,
            "packetAgeMs" to packetAgeMs,
            "decodeAgeMs" to decodeAgeMs,
            "decodeBacklog" to pendingDecodeTasks.get(),
            "codecBacklog" to pendingSyncFrameCount,
            "dropsTotal" to decodeBacklogDropCount,
            "dropsWindow" to drops,
            "packetsWindow" to packets,
            "decodedWindow" to decoded,
            "packetBytesWindow" to packetBytes,
            "connectAttempts" to connectAttempts,
            "socketConnected" to (webSocket != null),
            "surfaceValid" to (surface?.isValid == true),
            "codecConfigured" to codecConfigured,
            "waitingKeyFrame" to waitingKeyFrame,
            "currentWidth" to currentWidth,
            "currentHeight" to currentHeight,
            "pendingFrames" to pendingFrames.size,
            "lastSourceFrameId" to lastSourceFrameId,
            "lastSourceFrameKey" to lastSourceFrameKey,
            "sourceFrameCandidates" to lastSourceFrameCandidates,
            "missingSourceFrameIds" to missingSourceFrameIdCount,
            "syntheticSyncActive" to syntheticSyncActive,
            "syntheticFrameEmits" to syntheticFrameEmitCount,
            "startupSyncFrameStrikes" to startupSyncFrameStrikes,
            "lastFrameEmitAgeMs" to if (lastFrameEmitAtMs <= 0L) -1L else (now - lastFrameEmitAtMs),
            "firstDecodedWithoutSyncAgeMs" to
                if (firstDecodedWithoutSyncAtMs <= 0L) -1L else (now - firstDecodedWithoutSyncAtMs),
            "metaKeySummary" to lastMetaKeySummary,
            "parsedMetaLength" to lastParsedMetaLength,
            "parsedMetaPreview" to lastParsedMetaPreview,
            "parsedFrameIdRaw" to lastParsedFrameIdRaw,
            "parsedMetaFields" to lastParsedFrameFieldSummary,
            "lastError" to lastErrorReason,
            "lastErrorAgeMs" to errorAgeMs,
        ))
  }

  private fun emitYoloConfig(config: NativeDriveYoloConfig) {
    val payload = mutableMapOf<String, Any?>(
        "viewId" to viewId,
        "type" to "yolo_config",
        "camera" to cameraName,
    )
    payload.putAll(config.toPayload())
    NativeDriveVideoPlugin.emit(
        payload)
  }

  private fun emitYoloState(state: Map<String, Any?>) {
    val payload = mutableMapOf<String, Any?>(
        "viewId" to viewId,
        "type" to "yolo_state",
        "camera" to cameraName,
    )
    payload.putAll(state)
    NativeDriveVideoPlugin.emit(payload)
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
  @Volatile private var yoloConfig: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
  private val overlayRenderer = NativeDriveOverlayCanvasRenderer()

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

  fun updateYoloConfig(config: NativeDriveYoloConfig) {
    yoloConfig = config
    postInvalidateOnAnimation()
  }

  fun clearOverlay() {
    overlayPayload = null
    postInvalidateOnAnimation()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val overlay = overlayPayload
    if (overlay == null) return
    val drawWidth = width.toFloat()
    val drawHeight = height.toFloat()
    if (drawWidth <= 1f || drawHeight <= 1f) return
    overlayRenderer.draw(canvas, overlay, drawWidth, drawHeight)
  }
}
