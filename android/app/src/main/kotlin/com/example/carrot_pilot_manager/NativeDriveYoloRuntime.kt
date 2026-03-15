package com.example.carrot_pilot_manager

import android.graphics.Bitmap

data class NativeDriveYoloRuntimeSnapshot(
    val runtimeReady: Boolean = false,
    val pixelPathReady: Boolean = false,
    val stage: String = "idle",
    val blocker: String? = null,
    val backend: String = NativeDriveYoloConfig.DEFAULT_RUNTIME_BACKEND,
    val backendAvailable: Boolean = false,
    val backendReason: String? = null,
    val backendNativeLibs: List<String> = emptyList(),
    val backendNativeLibDir: String? = null,
    val backendPackagingMode: String = "maven",
    val backendAssetFiles: List<String> = emptyList(),
    val backendRuntimeDir: String? = null,
    val backendEnvReady: Boolean = false,
    val modelVariant: String = NativeDriveYoloConfig.DEFAULT_MODEL_VARIANT,
    val inferenceRequests: Int = 0,
    val lastRequestedFrameId: Int = -1,
    val pixelFramesConsumed: Int = 0,
    val modelPath: String? = null,
    val modelSource: String? = null,
    val modelSearchPaths: List<String> = emptyList(),
    val lastError: String? = null,
    val forwardSuccesses: Int = 0,
    val forwardFailures: Int = 0,
    val lastPreprocessMs: Double? = null,
    val lastForwardMs: Double? = null,
    val lastOutputShapes: List<String> = emptyList(),
    val lastOutputDtypes: List<String> = emptyList(),
    val lastOutputPreview: List<String> = emptyList(),
    val parsedCandidateCount: Int = 0,
    val parsedDetectionCount: Int = 0,
    val parserStrategy: String? = null,
    val parserScoreThreshold: Double? = null,
    val parserAboveThresholdCount: Int = 0,
    val parserMaxClassScore: Double? = null,
    val parsedDetectionsPreview: List<String> = emptyList(),
    val parsedDetections: List<Map<String, Any?>> = emptyList(),
) {
  fun toPayload(): Map<String, Any?> {
    return mapOf(
        "runtimeReady" to runtimeReady,
        "pixelPathReady" to pixelPathReady,
        "stage" to stage,
        "blocker" to blocker,
        "runtimeBackend" to backend,
        "backendAvailable" to backendAvailable,
        "backendReason" to backendReason,
        "backendNativeLibs" to backendNativeLibs,
        "backendNativeLibDir" to backendNativeLibDir,
        "backendPackagingMode" to backendPackagingMode,
        "backendAssetFiles" to backendAssetFiles,
        "backendRuntimeDir" to backendRuntimeDir,
        "backendEnvReady" to backendEnvReady,
        "modelVariant" to modelVariant,
        "inferenceRequests" to inferenceRequests,
        "lastRequestedFrameId" to lastRequestedFrameId,
        "pixelFramesConsumed" to pixelFramesConsumed,
        "modelPath" to modelPath,
        "modelSource" to modelSource,
        "modelSearchPaths" to modelSearchPaths,
        "lastError" to lastError,
        "forwardSuccesses" to forwardSuccesses,
        "forwardFailures" to forwardFailures,
        "lastPreprocessMs" to lastPreprocessMs,
        "lastForwardMs" to lastForwardMs,
        "lastOutputShapes" to lastOutputShapes,
        "lastOutputDtypes" to lastOutputDtypes,
        "lastOutputPreview" to lastOutputPreview,
        "parsedCandidateCount" to parsedCandidateCount,
        "parsedDetectionCount" to parsedDetectionCount,
        "parserStrategy" to parserStrategy,
        "parserScoreThreshold" to parserScoreThreshold,
        "parserAboveThresholdCount" to parserAboveThresholdCount,
        "parserMaxClassScore" to parserMaxClassScore,
        "parsedDetectionsPreview" to parsedDetectionsPreview,
        "parsedDetections" to parsedDetections,
    )
  }
}

interface NativeDriveYoloRuntime {
  fun updateConfig(config: NativeDriveYoloConfig)

  fun onSampledFrame(frame: NativeDriveYoloFrame)

  fun onPixelFrame(frame: NativeDriveYoloFrame, bitmap: Bitmap)

  fun snapshot(): NativeDriveYoloRuntimeSnapshot

  fun release()
}

class NativeDriveYoloStubRuntime : NativeDriveYoloRuntime {
  private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
  private var inferenceRequests = 0
  private var lastRequestedFrameId = -1
  private var pixelFramesConsumed = 0

  override fun updateConfig(config: NativeDriveYoloConfig) {
    this.config = config
    if (!config.enabled) {
      inferenceRequests = 0
      lastRequestedFrameId = -1
      pixelFramesConsumed = 0
    }
  }

  override fun onSampledFrame(frame: NativeDriveYoloFrame) {
    if (!config.enabled) return
    inferenceRequests += 1
    lastRequestedFrameId = frame.frameId
  }

  override fun onPixelFrame(frame: NativeDriveYoloFrame, bitmap: Bitmap) {
    if (!config.enabled) return
    pixelFramesConsumed += 1
    lastRequestedFrameId = frame.frameId
  }

  override fun snapshot(): NativeDriveYoloRuntimeSnapshot {
    if (!config.enabled) {
      return NativeDriveYoloRuntimeSnapshot(
          runtimeReady = false,
          pixelPathReady = false,
          stage = "idle",
          blocker = "disabled",
          backend = config.runtimeBackend,
          modelVariant = config.modelVariant,
          inferenceRequests = inferenceRequests,
          lastRequestedFrameId = lastRequestedFrameId,
          pixelFramesConsumed = pixelFramesConsumed,
      )
    }
    return NativeDriveYoloRuntimeSnapshot(
        runtimeReady = false,
        pixelPathReady = pixelFramesConsumed > 0,
        stage =
            if (pixelFramesConsumed > 0) "awaiting_executorch_session"
            else "awaiting_pixel_frame_path",
        blocker =
            if (pixelFramesConsumed > 0) "executorch_session_missing"
            else "pixel_frame_path_missing",
        backend = config.runtimeBackend,
        modelVariant = config.modelVariant,
        inferenceRequests = inferenceRequests,
        lastRequestedFrameId = lastRequestedFrameId,
        pixelFramesConsumed = pixelFramesConsumed,
    )
  }

  override fun release() {
    config = NativeDriveYoloConfig.disabled
    inferenceRequests = 0
    lastRequestedFrameId = -1
  }
}
