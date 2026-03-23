package com.example.carrot_pilot_manager

import android.os.Handler
import android.os.Looper

private const val YOLO_STATE_EMIT_INTERVAL_MS = 300L

class NativeDriveYoloController(
    surfaceView: android.view.SurfaceView,
    private val onStateChanged: (Map<String, Any?>) -> Unit,
    private val runtimeFactory: ((String) -> NativeDriveYoloRuntime)? = null,
    initialRuntime: NativeDriveYoloRuntime = NativeDriveYoloStubRuntime(),
    initialRuntimeBackend: String = NativeDriveYoloConfig.DEFAULT_RUNTIME_BACKEND,
) {
  private var runtime: NativeDriveYoloRuntime = initialRuntime
  private var runtimeBackend: String = initialRuntimeBackend
  private val mainHandler = Handler(Looper.getMainLooper())
  private val pixelSampler =
      NativeDriveYoloPixelSampler(
          surfaceView = surfaceView,
          onPixelSampled = { frame, bitmap, releaseBitmap ->
            if (config.enabled) {
              runtime.onPixelFrame(frame, bitmap, releaseBitmap)
              lastSkipReason = "pixel_ready"
              emitState(force = true, reason = "pixel_sample_ready")
            } else {
              releaseBitmap()
            }
          },
      )
  private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
  private var framesSeen = 0
  private var framesSampled = 0
  private var framesSkipped = 0
  private var lastFrameId = -1
  private var lastFramePtsUs = 0L
  private var lastSamplePtsUs = Long.MIN_VALUE
  private var lastSkipReason = "disabled"
  private var lastEffectiveSamplePeriodMs =
      NativeDriveYoloConfig.disabled.samplePeriodMs.coerceAtLeast(33)
  private var lastEmitAtMs = 0L
  private var lastEmitSignature = 0

  // Stash the latest rendered frame for inference-ready resample.
  @Volatile private var lastRenderedFrame: NativeDriveYoloFrame? = null
  @Volatile private var inferenceReadyResamplePending = false

  init {
    attachInferenceReadyCallback(runtime)
  }

  fun updateConfig(next: NativeDriveYoloConfig) {
    val wasEnabled = config.enabled
    maybeSwapRuntime(next)
    config = next
    runtime.updateConfig(next)
    pixelSampler.updateConfig(next)
    if (!next.enabled) {
      framesSeen = 0
      framesSampled = 0
      framesSkipped = 0
      lastFrameId = -1
      lastFramePtsUs = 0L
      lastSamplePtsUs = Long.MIN_VALUE
      lastSkipReason = "disabled"
      lastEffectiveSamplePeriodMs = NativeDriveYoloConfig.disabled.samplePeriodMs.coerceAtLeast(33)
      smoothedForwardMs = 0.0
      lastRenderedFrame = null
    } else if (!wasEnabled) {
      lastSamplePtsUs = Long.MIN_VALUE
      lastSkipReason = "awaiting_rendered_frame_feed"
      lastEffectiveSamplePeriodMs = next.samplePeriodMs.coerceAtLeast(33)
    }
    emitState(force = true, reason = "config_updated")
  }

  fun onFrameRendered(frame: NativeDriveYoloFrame) {
    if (!config.enabled) {
      return
    }
    framesSeen += 1
    lastFrameId = frame.frameId
    lastFramePtsUs = frame.ptsUs
    lastRenderedFrame = frame
    if (frame.sourceWidth < 32 || frame.sourceHeight < 32) {
      framesSkipped += 1
      lastSkipReason = "source_size_missing"
      emitState(reason = "source_size_missing")
      return
    }
    val effectiveSamplePeriodMs = effectiveSamplePeriodMs(frame)
    lastEffectiveSamplePeriodMs = effectiveSamplePeriodMs
    val samplePeriodUs = (effectiveSamplePeriodMs * 1000L)
    if (lastSamplePtsUs != Long.MIN_VALUE) {
      val deltaUs = frame.ptsUs - lastSamplePtsUs
      if (deltaUs in 0 until samplePeriodUs) {
        framesSkipped += 1
        lastSkipReason = "sample_throttled"
        emitState(reason = "sample_throttled")
        return
      }
    }

    lastSamplePtsUs = frame.ptsUs
    runtime.onSampledFrame(frame)
    if (pixelSampler.trySample(frame)) {
      framesSampled += 1
      lastSkipReason = "pixel_requested"
      emitState(force = true, reason = "pixel_sample_requested")
      return
    }
    framesSkipped += 1
    lastSkipReason = pixelSampler.snapshot().lastCopyResult
    emitState(reason = "pixel_sample_skipped")
  }

  fun snapshot(reason: String? = null): Map<String, Any?> {
    val runtimeSnapshot = runtime.snapshot()
    val pixelSnapshot = pixelSampler.snapshot()
    val effectiveStageAndBlocker =
        deriveEffectiveStageAndBlocker(
            runtimeSnapshot = runtimeSnapshot,
            pixelSnapshot = pixelSnapshot,
        )
    val payload = mutableMapOf<String, Any?>(
        "enabled" to config.enabled,
        "yoloBoxes" to config.showBoxes,
        "yoloLabels" to config.showLabels,
        "yoloTrafficLights" to config.showTrafficLights,
        "yoloStats" to config.showStats,
        "runtimeBackend" to config.runtimeBackend,
        "modelVariant" to config.modelVariant,
        "camera" to config.camera,
        "sourceWidth" to config.sourceWidth,
        "sourceHeight" to config.sourceHeight,
        "framesSeen" to framesSeen,
        "framesSampled" to framesSampled,
        "framesSkipped" to framesSkipped,
        "lastFrameId" to lastFrameId,
        "lastFramePtsUs" to lastFramePtsUs,
        "samplePeriodMs" to lastEffectiveSamplePeriodMs,
        "lastSkipReason" to lastSkipReason,
    )
    payload.putAll(pixelSnapshot.toPayload())
    payload.putAll(runtimeSnapshot.toPayload())
    payload["runtimeStage"] = runtimeSnapshot.stage
    payload["runtimeBlocker"] = runtimeSnapshot.blocker
    payload["stage"] = effectiveStageAndBlocker.first
    payload["blocker"] = effectiveStageAndBlocker.second
    payload["pixelPathReady"] = pixelSnapshot.pixelPathReady || runtimeSnapshot.pixelPathReady
    if (!reason.isNullOrBlank()) {
      payload["reason"] = reason
    }
    return payload
  }

  fun release() {
    runtime.setOnInferenceReadyCallback(null)
    runtime.release()
    pixelSampler.release()
    lastRenderedFrame = null
    emitState(force = true, reason = "released")
  }

  private fun emitState(force: Boolean = false, reason: String? = null) {
    val payload = snapshot(reason = reason)
    val nowMs = System.currentTimeMillis()
    val signature = payload.toString().hashCode()
    val emitDue = (nowMs - lastEmitAtMs) >= YOLO_STATE_EMIT_INTERVAL_MS
    if (!force && !emitDue && signature == lastEmitSignature) {
      return
    }
    if (!force && !emitDue) {
      return
    }
    lastEmitAtMs = nowMs
    lastEmitSignature = signature
    onStateChanged(payload)
  }

  private fun maybeSwapRuntime(next: NativeDriveYoloConfig) {
    val factory = runtimeFactory ?: return
    val requestedBackend = next.runtimeBackend.trim().ifEmpty {
      NativeDriveYoloConfig.DEFAULT_RUNTIME_BACKEND
    }
    if (requestedBackend == runtimeBackend && runtime !is NativeDriveYoloStubRuntime) {
      return
    }
    runtime.setOnInferenceReadyCallback(null)
    val replacement = factory(requestedBackend)
    runtime.release()
    runtime = replacement
    runtimeBackend = requestedBackend
    attachInferenceReadyCallback(replacement)
  }

  private fun attachInferenceReadyCallback(target: NativeDriveYoloRuntime) {
    target.setOnInferenceReadyCallback {
      // Post to main thread for thread-safe SurfaceView access in PixelCopy.
      if (!inferenceReadyResamplePending && config.enabled) {
        inferenceReadyResamplePending = true
        mainHandler.post { handleInferenceReady() }
      }
    }
  }

  private fun handleInferenceReady() {
    inferenceReadyResamplePending = false
    if (!config.enabled) return
    val frame = lastRenderedFrame ?: return
    if (frame.sourceWidth < 32 || frame.sourceHeight < 32) return
    // Bypass the normal sample throttle — inference is idle, capture immediately.
    if (pixelSampler.trySample(frame)) {
      lastSamplePtsUs = frame.ptsUs
      framesSampled += 1
      lastSkipReason = "pixel_requested_inference_ready"
      emitState(force = true, reason = "inference_ready_resample")
    }
  }

  private fun deriveEffectiveStageAndBlocker(
      runtimeSnapshot: NativeDriveYoloRuntimeSnapshot,
      pixelSnapshot: NativeDriveYoloPixelSamplerSnapshot,
  ): Pair<String, String?> {
    if (!config.enabled) {
      return "idle" to "disabled"
    }
    if (framesSeen <= 0) {
      return "awaiting_rendered_frame_feed" to "render_frame_missing"
    }
    if (framesSampled <= 0) {
      return when (lastSkipReason) {
        "source_size_missing" -> "awaiting_valid_source_size" to "source_size_missing"
        "surface_not_ready" -> "awaiting_surface_ready" to "surface_not_ready"
        "copy_in_flight" -> "awaiting_pixel_copy" to "copy_in_flight"
        "sample_throttled" -> "awaiting_sample_window" to "sample_throttled"
        "pixel_requested" -> "awaiting_pixel_copy_result" to "pixel_copy_pending"
        else -> "awaiting_pixel_copy_request" to lastSkipReason
      }
    }
    if (pixelSnapshot.copyRequests > 0 && pixelSnapshot.copySuccesses <= 0) {
      return "awaiting_pixel_copy_result" to pixelSnapshot.lastCopyResult
    }
    if (pixelSnapshot.copySuccesses > 0 && !runtimeSnapshot.pixelPathReady) {
      return "awaiting_runtime_pixel_consume" to "runtime_pixel_consume_missing"
    }
    return runtimeSnapshot.stage to runtimeSnapshot.blocker
  }

  private var smoothedForwardMs: Double = 0.0

  private fun effectiveSamplePeriodMs(frame: NativeDriveYoloFrame): Int {
    val configured = config.samplePeriodMs.coerceAtLeast(33)
    val liveRoadFastPath =
        frame.camera.equals("road", ignoreCase = true) &&
            frame.sourceWidth >= 1000 &&
            frame.sourceHeight >= 600

    val basePeriod = if (liveRoadFastPath) minOf(configured, 60) else configured

    // Adaptive: use forward (inference-only) time instead of full pipeline time,
    // since PixelCopy and preprocessing overlap with the previous inference cycle
    // thanks to the inference-ready callback and double-buffering.
    val snapshot = runtime.snapshot()
    val rawForwardMs = snapshot.lastForwardMs
    if (rawForwardMs != null && rawForwardMs > 0) {
      smoothedForwardMs = if (smoothedForwardMs <= 0.0) {
        rawForwardMs
      } else {
        (smoothedForwardMs * 0.70) + (rawForwardMs * 0.30)
      }
      val adaptivePeriod = (smoothedForwardMs * 1.15).toInt().coerceAtLeast(basePeriod)
      return adaptivePeriod.coerceAtMost(160)
    }
    return basePeriod
  }
}
