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
            runtime.onPixelFrame(frame, bitmap)
            lastSkipReason = "pixel_ready"
            emitState(force = true, reason = "pixel_sample_ready")
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
    config = next
    runtime.updateConfig(next)
    pixelSampler.updateConfig(next)
    if (!next.enabled) {
      lastSamplePtsUs = Long.MIN_VALUE
      lastSkipReason = "disabled"
    }
    emitState(force = true, reason = "config_updated")
  }

  fun onFrameRendered(frame: NativeDriveYoloFrame) {
    framesSeen += 1
    lastFrameId = frame.frameId
    lastFramePtsUs = frame.ptsUs

    if (!config.enabled) {
      lastSkipReason = "disabled"
      emitState(reason = "disabled")
      return
    }
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
}
