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
    val actualBackend: String? = null,
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
    val inferenceInFlight: Boolean = false,
    val inferenceSkippedBusy: Int = 0,
    val modelPath: String? = null,
    val modelSource: String? = null,
    val modelSearchPaths: List<String> = emptyList(),
    val modelMetadataPath: String? = null,
    val modelMetadataSource: String? = null,
    val modelMetadataOutputName: String? = null,
    val modelMetadataSoc: String? = null,
    val modelMetadataExecutorchRef: String? = null,
    val modelMetadataUseFp16: Boolean? = null,
    val modelMetadataOnlinePrepare: Boolean? = null,
    val modelMetadataImgsz: Int? = null,
    val modelMetadataBatch: Int? = null,
    val modelMetadataParseError: String? = null,
    val lastError: String? = null,
    val lastFailureStage: String? = null,
    val initAttempts: Int = 0,
    val gpuInitAttempts: Int = 0,
    val gpuInitFailures: Int = 0,
    val gpuBufferAllocFailures: Int = 0,
    val cpuFallbackCount: Int = 0,
    val forwardSuccesses: Int = 0,
    val forwardFailures: Int = 0,
    val inputTransferMode: String? = null,
    val directBitmapFrames: Int = 0,
    val clonedBitmapFrames: Int = 0,
    val lastInputAcquireMs: Double? = null,
    val lastPreprocessMs: Double? = null,
    val lastForwardMs: Double? = null,
    val lastPipelineMs: Double? = null,
    val lastOutputReadMs: Double? = null,
    val lastParseMs: Double? = null,
    val lastPayloadBuildMs: Double? = null,
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
    val lastInferenceFrameId: Int = -1,
    val lastInferencePtsUs: Long = 0L,
    val lastInferenceElapsedMs: Double? = null,
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
        "actualBackend" to actualBackend,
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
        "inferenceInFlight" to inferenceInFlight,
        "inferenceSkippedBusy" to inferenceSkippedBusy,
        "modelPath" to modelPath,
        "modelSource" to modelSource,
        "modelSearchPaths" to modelSearchPaths,
        "modelMetadataPath" to modelMetadataPath,
        "modelMetadataSource" to modelMetadataSource,
        "modelMetadataOutputName" to modelMetadataOutputName,
        "modelMetadataSoc" to modelMetadataSoc,
        "modelMetadataExecutorchRef" to modelMetadataExecutorchRef,
        "modelMetadataUseFp16" to modelMetadataUseFp16,
        "modelMetadataOnlinePrepare" to modelMetadataOnlinePrepare,
        "modelMetadataImgsz" to modelMetadataImgsz,
        "modelMetadataBatch" to modelMetadataBatch,
        "modelMetadataParseError" to modelMetadataParseError,
        "lastError" to lastError,
        "lastFailureStage" to lastFailureStage,
        "initAttempts" to initAttempts,
        "gpuInitAttempts" to gpuInitAttempts,
        "gpuInitFailures" to gpuInitFailures,
        "gpuBufferAllocFailures" to gpuBufferAllocFailures,
        "cpuFallbackCount" to cpuFallbackCount,
        "forwardSuccesses" to forwardSuccesses,
        "forwardFailures" to forwardFailures,
        "inputTransferMode" to inputTransferMode,
        "directBitmapFrames" to directBitmapFrames,
        "clonedBitmapFrames" to clonedBitmapFrames,
        "lastInputAcquireMs" to lastInputAcquireMs,
        "lastPreprocessMs" to lastPreprocessMs,
        "lastForwardMs" to lastForwardMs,
        "lastPipelineMs" to lastPipelineMs,
        "lastOutputReadMs" to lastOutputReadMs,
        "lastParseMs" to lastParseMs,
        "lastPayloadBuildMs" to lastPayloadBuildMs,
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
        "lastInferenceFrameId" to lastInferenceFrameId,
        "lastInferencePtsUs" to lastInferencePtsUs,
        "lastInferenceElapsedMs" to lastInferenceElapsedMs,
    )
  }
}

interface NativeDriveYoloRuntime {
  fun updateConfig(config: NativeDriveYoloConfig)

  fun onSampledFrame(frame: NativeDriveYoloFrame)

  fun onPixelFrame(frame: NativeDriveYoloFrame, bitmap: Bitmap)

  fun onPixelFrame(
      frame: NativeDriveYoloFrame,
      bitmap: Bitmap,
      releaseBitmap: (() -> Unit)?,
  ) {
    onPixelFrame(frame, bitmap)
  }

  fun snapshot(): NativeDriveYoloRuntimeSnapshot

  /** Called when inference pipeline becomes idle and is ready for the next frame. */
  fun setOnInferenceReadyCallback(callback: (() -> Unit)?) {}

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
