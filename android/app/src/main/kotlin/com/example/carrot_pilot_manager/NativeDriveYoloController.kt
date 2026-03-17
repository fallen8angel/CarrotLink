package com.example.carrot_pilot_manager

private const val YOLO_STATE_EMIT_INTERVAL_MS = 1_000L

class NativeDriveYoloController(
    surfaceView: android.view.SurfaceView,
    private val onStateChanged: (Map<String, Any?>) -> Unit,
    private val runtime: NativeDriveYoloRuntime = NativeDriveYoloStubRuntime(),
) {
  private val pixelSampler =
      NativeDriveYoloPixelSampler(
          surfaceView = surfaceView,
          onPixelSampled = { frame, bitmap ->
            if (config.enabled) {
              runtime.onPixelFrame(frame, bitmap)
              lastSkipReason = "pixel_ready"
              emitState(force = true, reason = "pixel_sample_ready")
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
  private var lastEmitAtMs = 0L
  private var lastEmitSignature = 0

  fun updateConfig(next: NativeDriveYoloConfig) {
    val wasEnabled = config.enabled
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
    } else if (!wasEnabled) {
      lastSamplePtsUs = Long.MIN_VALUE
      lastSkipReason = "awaiting_rendered_frame_feed"
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
    if (frame.sourceWidth < 32 || frame.sourceHeight < 32) {
      framesSkipped += 1
      lastSkipReason = "source_size_missing"
      emitState(reason = "source_size_missing")
      return
    }
    val samplePeriodUs = (config.samplePeriodMs.coerceAtLeast(33) * 1000L)
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
        "samplePeriodMs" to config.samplePeriodMs.coerceAtLeast(33),
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
    runtime.release()
    pixelSampler.release()
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
}
