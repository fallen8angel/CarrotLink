package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import org.json.JSONObject
import org.pytorch.executorch.EValue
import org.pytorch.executorch.Module
import org.pytorch.executorch.Tensor
import java.io.File
import java.nio.FloatBuffer
import kotlin.math.min

internal data class NativeDriveYoloModelResolution(
    val modelPath: String? = null,
    val modelSource: String? = null,
    val candidatePaths: List<String> = emptyList(),
) {
  val found: Boolean
    get() = !modelPath.isNullOrBlank()
}

internal data class NativeDriveYoloModelMetadata(
    val metadataPath: String? = null,
    val metadataSource: String? = null,
    val candidatePaths: List<String> = emptyList(),
    val outputName: String? = null,
    val weights: String? = null,
    val soc: String? = null,
    val qnnSdkVersion: String? = null,
    val executorchRef: String? = null,
    val useFp16: Boolean? = null,
    val onlinePrepare: Boolean? = null,
    val imgsz: Int? = null,
    val batch: Int? = null,
    val parseError: String? = null,
) {
  val present: Boolean
    get() = !metadataPath.isNullOrBlank()
}

internal object NativeDriveYoloModelLocator {
  private const val extractedDirName = "carrotlink_yolo_models"

  fun resolve(
      context: Context,
      config: NativeDriveYoloConfig,
  ): NativeDriveYoloModelResolution {
    val requested = config.modelVariant.trim().ifEmpty { NativeDriveYoloConfig.DEFAULT_MODEL_VARIANT }
    val candidatePaths = linkedSetOf<String>()

    // Allow a direct absolute path override for quick bring-up testing.
    if (requested.contains("/") || requested.contains("\\")) {
      val direct = File(requested)
      candidatePaths += direct.absolutePath
      if (direct.isFile) {
        return NativeDriveYoloModelResolution(
            modelPath = direct.absolutePath,
            modelSource = "direct_path",
            candidatePaths = candidatePaths.toList(),
        )
      }
    }

    val fileNames =
        linkedSetOf<String>().apply {
          for (baseName in NativeDriveYoloModelCatalog.candidateBaseNamesFor(requested)) {
            add(if (baseName.endsWith(".pte", ignoreCase = true)) baseName else "$baseName.pte")
            add(baseName)
          }
        }

    fun addFileCandidates(label: String, dir: File?) {
      if (dir == null) return
      for (fileName in fileNames) {
        val candidate = File(dir, fileName)
        candidatePaths += candidate.absolutePath
        if (candidate.isFile) {
          throw FoundModel(
              NativeDriveYoloModelResolution(
                  modelPath = candidate.absolutePath,
                  modelSource = label,
                  candidatePaths = candidatePaths.toList(),
              ))
        }
      }
    }

    try {
      addFileCandidates("app_files_yolo", File(context.filesDir, "yolo"))
      addFileCandidates("app_files_models", File(context.filesDir, "models"))
      addFileCandidates("no_backup_yolo", File(context.noBackupFilesDir, "yolo"))
      addFileCandidates("no_backup_models", File(context.noBackupFilesDir, "models"))
      addFileCandidates("cache_yolo", File(context.cacheDir, "yolo"))
      addFileCandidates("cache_models", File(context.cacheDir, "models"))
      addFileCandidates("external_files_yolo", context.getExternalFilesDir("yolo"))
      addFileCandidates("external_files_models", context.getExternalFilesDir("models"))
      addFileCandidates("tmp_carrotlink_models", File("/data/local/tmp/carrotlink/models"))
      addFileCandidates("tmp_carrotlink_yolo", File("/data/local/tmp/carrotlink/yolo"))
      addFileCandidates("tmp_root", File("/data/local/tmp"))
    } catch (found: FoundModel) {
      return found.resolution
    }

    val assetCandidates =
        listOf(
          "yolo",
          "models",
          "flutter_assets/assets/yolo",
          "flutter_assets/assets/models",
        )
    for (assetDir in assetCandidates) {
      for (fileName in fileNames) {
        val assetPath = "$assetDir/$fileName"
        val extracted = extractAssetIfPresent(context, assetPath, fileName)
        if (extracted != null) {
          candidatePaths += extracted.absolutePath
          // Also refresh the sibling metadata file so resolveMetadata() always
          // reads a current copy — prevents stale on-device cache after re-export.
          val metaName = fileName.removeSuffix(".pte") + ".metadata.json"
          if (metaName != fileName) {
            extractAssetIfPresent(context, "$assetDir/$metaName", metaName)
          }
          return NativeDriveYoloModelResolution(
              modelPath = extracted.absolutePath,
              modelSource = "asset:$assetPath",
              candidatePaths = candidatePaths.toList(),
          )
        }
      }
    }

    return NativeDriveYoloModelResolution(candidatePaths = candidatePaths.toList())
  }

  fun resolveMetadata(
      context: Context,
      config: NativeDriveYoloConfig,
      model: NativeDriveYoloModelResolution,
  ): NativeDriveYoloModelMetadata {
    val candidatePaths = linkedSetOf<String>()
    val sibling =
        model.modelPath
            ?.let { File(it) }
            ?.takeIf { it.isFile }
            ?.parentFile
            ?.resolve("${File(model.modelPath!!).nameWithoutExtension}.metadata.json")
    if (sibling != null) {
      candidatePaths += sibling.absolutePath
      if (sibling.isFile) {
        return parseMetadataFile(
            metadataFile = sibling,
            source = "sibling:${sibling.name}",
            candidatePaths = candidatePaths.toList(),
        )
      }
    }

    val requested = config.modelVariant.trim().ifEmpty { NativeDriveYoloConfig.DEFAULT_MODEL_VARIANT }
    val metadataFileNames =
        linkedSetOf<String>().apply {
          for (baseName in NativeDriveYoloModelCatalog.candidateBaseNamesFor(requested)) {
            val normalized =
                if (baseName.endsWith(".pte", ignoreCase = true)) {
                  baseName.removeSuffix(".pte")
                } else {
                  baseName
                }
            add("$normalized.metadata.json")
          }
        }

    for (dir in searchDirectories(context)) {
      for (fileName in metadataFileNames) {
        val candidate = File(dir, fileName)
        candidatePaths += candidate.absolutePath
        if (candidate.isFile) {
          return parseMetadataFile(
              metadataFile = candidate,
              source = dir.name.ifBlank { "metadata_dir" },
              candidatePaths = candidatePaths.toList(),
          )
        }
      }
    }

    for (assetDir in assetDirectories()) {
      for (fileName in metadataFileNames) {
        val assetPath = "$assetDir/$fileName"
        val extracted = extractAssetIfPresent(context, assetPath, fileName)
        if (extracted != null) {
          candidatePaths += extracted.absolutePath
          return parseMetadataFile(
              metadataFile = extracted,
              source = "asset:$assetPath",
              candidatePaths = candidatePaths.toList(),
          )
        }
      }
    }

    return NativeDriveYoloModelMetadata(candidatePaths = candidatePaths.toList())
  }

  private fun parseMetadataFile(
      metadataFile: File,
      source: String,
      candidatePaths: List<String>,
  ): NativeDriveYoloModelMetadata {
    return try {
      val json = JSONObject(metadataFile.readText(Charsets.UTF_8))
      NativeDriveYoloModelMetadata(
          metadataPath = metadataFile.absolutePath,
          metadataSource = source,
          candidatePaths = candidatePaths,
          outputName = json.optString("output_name").ifBlank { null },
          weights = json.optString("weights").ifBlank { null },
          soc = json.optString("soc").ifBlank { null },
          qnnSdkVersion = json.optString("qnn_sdk_version").ifBlank { null },
          executorchRef = json.optString("executorch_ref").ifBlank { null },
          useFp16 = if (json.has("use_fp16")) json.optBoolean("use_fp16") else null,
          onlinePrepare = if (json.has("online_prepare")) json.optBoolean("online_prepare") else null,
          imgsz = if (json.has("imgsz")) json.optInt("imgsz") else null,
          batch = if (json.has("batch")) json.optInt("batch") else null,
      )
    } catch (t: Throwable) {
      NativeDriveYoloModelMetadata(
          metadataPath = metadataFile.absolutePath,
          metadataSource = source,
          candidatePaths = candidatePaths,
          parseError = t.message ?: t::class.java.simpleName,
      )
    }
  }

  private fun searchDirectories(context: Context): List<File> {
    return listOfNotNull(
        File(context.filesDir, "yolo"),
        File(context.filesDir, "models"),
        File(context.noBackupFilesDir, "yolo"),
        File(context.noBackupFilesDir, "models"),
        File(context.cacheDir, "yolo"),
        File(context.cacheDir, "models"),
        context.getExternalFilesDir("yolo"),
        context.getExternalFilesDir("models"),
        File("/data/local/tmp/carrotlink/models"),
        File("/data/local/tmp/carrotlink/yolo"),
        File("/data/local/tmp"),
    )
  }

  private fun assetDirectories(): List<String> {
    return listOf(
        "yolo",
        "models",
        "flutter_assets/assets/yolo",
        "flutter_assets/assets/models",
    )
  }

  private fun extractAssetIfPresent(
      context: Context,
      assetPath: String,
      fileName: String,
  ): File? {
    return try {
      context.assets.open(assetPath).use { input ->
        val assetBytes = input.readBytes()
        val outDir = File(context.noBackupFilesDir, extractedDirName)
        if (!outDir.exists()) {
          outDir.mkdirs()
        }
        val outFile = File(outDir, fileName)
        val shouldRewrite =
            !outFile.exists() ||
                outFile.length() != assetBytes.size.toLong() ||
                !runCatching { outFile.readBytes().contentEquals(assetBytes) }.getOrDefault(false)
        if (shouldRewrite) {
          outFile.outputStream().use { output -> output.write(assetBytes) }
        }
        outFile
      }
    } catch (_: Throwable) {
      null
    }
  }

  private class FoundModel(val resolution: NativeDriveYoloModelResolution) : RuntimeException()
}

internal class NativeDriveExecuTorchRuntime(
    context: Context,
) : NativeDriveYoloRuntime {
  private companion object {
    private const val qnnLoweredRuntimeGuardBlocker = "qnn_lowered_runtime_guarded"
    private const val qnnLoweredRuntimeGuardMessage =
        "QNN-lowered runtime is guarded because the current ExecuTorch/QNN stack " +
            "can crash during delegate initialization. Rebuild the export/runtime " +
            "from the same stack and enable it explicitly."
    private const val qnnDelegateInitFailedBlocker = "qnn_delegate_init_failed"
    private const val qnnDspTransportFailedBlocker = "qnn_dsp_transport_failed"
    private const val qnnForwardRetryBackoffMs = 5_000L
    private const val qnnForwardRetryThreshold = 3
  }

  private data class NativeDriveYoloBackendSupport(
      val available: Boolean = false,
      val reason: String? = null,
      val nativeLibs: List<String> = emptyList(),
      val nativeLibDir: String? = null,
      val packagingMode: String = BuildConfig.EXECUTORCH_PACKAGING_MODE,
      val assetFiles: List<String> = emptyList(),
  )

  private val appContext = context.applicationContext
  private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
  private var module: Module? = null
  private var modelPath: String? = null
  private var modelSource: String? = null
  private var candidatePaths: List<String> = emptyList()
  private var modelMetadata: NativeDriveYoloModelMetadata = NativeDriveYoloModelMetadata()
  private var backendSupport = NativeDriveYoloBackendSupport()
  private var qnnRuntimeDir: String? = null
  private var qnnEnvReady: Boolean = false
  private var lastError: String? = null
  private var stage: String = "idle"
  private var blocker: String? = "disabled"
  private var inferenceRequests = 0
  private var lastRequestedFrameId = -1
  private var pixelFramesConsumed = 0
  private var forwardSuccesses = 0
  private var forwardFailures = 0
  private var lastPreprocessMs: Double? = null
  private var lastForwardMs: Double? = null
  private var lastOutputShapes: List<String> = emptyList()
  private var lastOutputDtypes: List<String> = emptyList()
  private var lastOutputPreview: List<String> = emptyList()
  private var parsedCandidateCount = 0
  private var parsedDetectionCount = 0
  private var parserStrategy: String? = null
  private var parserScoreThreshold: Double? = null
  private var parserAboveThresholdCount = 0
  private var parserMaxClassScore: Double? = null
  private var parsedDetectionsPreview: List<String> = emptyList()
  private var parsedDetections: List<Map<String, Any?>> = emptyList()
  private var lastForwardFailureSignature: String? = null
  private var repeatedForwardFailureCount = 0
  private var qnnRetryBlockedUntilElapsedMs = 0L
  private var reusableInputBuffer: FloatBuffer? = null
  private var reusablePixels: IntArray? = null
  private var reusableInputShape: LongArray = longArrayOf(1, 3, 0, 0)

  private fun summarizeThrowable(t: Throwable): String {
    val primary = t.message?.trim().orEmpty()
    val className = t::class.java.simpleName.ifBlank { t::class.java.name }
    val cause = t.cause
    if (cause != null) {
      val causeClass = cause::class.java.simpleName.ifBlank { cause::class.java.name }
      val causeMessage = cause.message?.trim().orEmpty()
      return buildString {
        append(className)
        if (primary.isNotEmpty()) {
          append(": ")
          append(primary)
        }
        append(" | cause=")
        append(causeClass)
        if (causeMessage.isNotEmpty()) {
          append(": ")
          append(causeMessage)
        }
      }
    }
    if (primary.isNotEmpty()) {
      return "$className: $primary"
    }
    return className
  }

  override fun updateConfig(config: NativeDriveYoloConfig) {
    val previous = this.config
    val reloadRequired = requiresModuleReload(previous, config)
    this.config = config
    if (!config.enabled) {
      releaseModule()
      stage = "idle"
      blocker = "disabled"
      candidatePaths = emptyList()
      modelMetadata = NativeDriveYoloModelMetadata()
      backendSupport = NativeDriveYoloBackendSupport()
      qnnRuntimeDir = null
      qnnEnvReady = false
      lastError = null
      inferenceRequests = 0
      lastRequestedFrameId = -1
      pixelFramesConsumed = 0
      forwardSuccesses = 0
      forwardFailures = 0
      lastPreprocessMs = null
      lastForwardMs = null
      lastOutputShapes = emptyList()
      lastOutputDtypes = emptyList()
    lastOutputPreview = emptyList()
    parsedCandidateCount = 0
    parsedDetectionCount = 0
    parserStrategy = null
    parserScoreThreshold = null
    parserAboveThresholdCount = 0
    parserMaxClassScore = null
    parsedDetectionsPreview = emptyList()
    parsedDetections = emptyList()
    resetForwardFailureTracking()
    reusableInputBuffer = null
      reusablePixels = null
      reusableInputShape = longArrayOf(1, 3, 0, 0)
      return
    }
    backendSupport = probeBackendSupport(config)
    if (!config.unsafeRuntimeEnabled) {
      releaseModule()
      stage = "runtime_disabled"
      blocker = "unsafe_runtime_disabled"
      lastError = null
      candidatePaths = emptyList()
      modelMetadata = NativeDriveYoloModelMetadata()
      qnnRuntimeDir = null
      qnnEnvReady = false
      inferenceRequests = 0
      lastRequestedFrameId = -1
      pixelFramesConsumed = 0
      forwardSuccesses = 0
      forwardFailures = 0
      lastPreprocessMs = null
      lastForwardMs = null
      lastOutputShapes = emptyList()
      lastOutputDtypes = emptyList()
      lastOutputPreview = emptyList()
      parsedCandidateCount = 0
      parsedDetectionCount = 0
      parserStrategy = null
      parserScoreThreshold = null
      parserAboveThresholdCount = 0
      parserMaxClassScore = null
      parsedDetectionsPreview = emptyList()
      parsedDetections = emptyList()
      resetForwardFailureTracking()
      reusableInputBuffer = null
      reusablePixels = null
      reusableInputShape = longArrayOf(1, 3, 0, 0)
      return
    }
    if (!backendSupport.available) {
      releaseModule()
      stage = "backend_unavailable"
      blocker = backendSupport.reason ?: "backend_unavailable"
      lastError = null
      candidatePaths = emptyList()
      modelMetadata = NativeDriveYoloModelMetadata()
      qnnRuntimeDir = null
      qnnEnvReady = false
      resetForwardFailureTracking()
      reusableInputBuffer = null
      reusablePixels = null
      reusableInputShape = longArrayOf(1, 3, 0, 0)
      return
    }
    if (shouldGuardQnnLoweredRuntime(config)) {
      applyQnnLoweredRuntimeGuard()
      return
    }
    ensureInputBuffers()
    ensureModuleLoaded(forceReload = reloadRequired)
  }

  override fun onSampledFrame(frame: NativeDriveYoloFrame) {
    if (!config.enabled) return
    if (!config.unsafeRuntimeEnabled) {
      stage = "runtime_disabled"
      blocker = "unsafe_runtime_disabled"
      return
    }
    if (!backendSupport.available) {
      stage = "backend_unavailable"
      blocker = backendSupport.reason ?: "backend_unavailable"
      return
    }
    if (shouldGuardQnnLoweredRuntime(config)) {
      applyQnnLoweredRuntimeGuard()
      return
    }
    inferenceRequests += 1
    lastRequestedFrameId = frame.frameId
    if (module == null) {
      ensureModuleLoaded(forceReload = false)
      return
    }
    stage = "awaiting_preprocess_pipeline"
    blocker = "preprocess_missing"
  }

  override fun onPixelFrame(frame: NativeDriveYoloFrame, bitmap: android.graphics.Bitmap) {
    if (!config.enabled) return
    if (!config.unsafeRuntimeEnabled) {
      stage = "runtime_disabled"
      blocker = "unsafe_runtime_disabled"
      return
    }
    if (!backendSupport.available) {
      stage = "backend_unavailable"
      blocker = backendSupport.reason ?: "backend_unavailable"
      return
    }
    if (shouldGuardQnnLoweredRuntime(config)) {
      applyQnnLoweredRuntimeGuard()
      return
    }
    if (isQnnRetryBackoffActive(config)) {
      applyQnnRetryBackoffState()
      return
    }
    pixelFramesConsumed += 1
    lastRequestedFrameId = frame.frameId
    if (module == null) {
      ensureModuleLoaded(forceReload = false)
      return
    }
    lastPreprocessMs = null
    lastForwardMs = null
    lastOutputShapes = emptyList()
    lastOutputDtypes = emptyList()
    lastOutputPreview = emptyList()
    parsedCandidateCount = 0
    parsedDetectionCount = 0
    parserStrategy = null
    parserScoreThreshold = null
    parserAboveThresholdCount = 0
    parserMaxClassScore = null
    parsedDetectionsPreview = emptyList()
    parsedDetections = emptyList()
    var preprocessDone = false
    try {
      val preprocessStartNs = System.nanoTime()
      val inputTensor = preprocessBitmap(bitmap)
      lastPreprocessMs = elapsedMs(preprocessStartNs)
      preprocessDone = true

      val forwardStartNs = System.nanoTime()
      val outputs = module!!.forward(EValue.from(inputTensor))
      lastForwardMs = elapsedMs(forwardStartNs)
      forwardSuccesses += 1
      resetForwardFailureTracking()
      updateOutputDiagnostics(outputs)
      val parseResult =
          NativeDriveYoloParser.parse(
              outputShapes = outputs.mapNotNull { value ->
                runCatching { if (value.isTensor()) value.toTensor().shape() else null }.getOrNull()
              },
              outputTensors = outputs.mapNotNull { value ->
                runCatching { if (value.isTensor()) value.toTensor().getDataAsFloatArray() else null }
                    .getOrNull()
              },
              inputWidth = config.inputWidth.coerceAtLeast(32),
              inputHeight = config.inputHeight.coerceAtLeast(32),
          )
      lastError = null
      if (parseResult != null) {
        parsedCandidateCount = parseResult.candidateCount
        parsedDetectionCount = parseResult.acceptedCount
        parserStrategy = parseResult.strategy
        parserScoreThreshold = parseResult.scoreThreshold.toDouble()
        parserAboveThresholdCount = parseResult.aboveThresholdCount
        parserMaxClassScore = parseResult.maxClassScore.toDouble()
        parsedDetectionsPreview =
            buildList {
              add(
                  "strategy=${parseResult.strategy} " +
                      "thr=${"%.2f".format(parseResult.scoreThreshold)} " +
                      "above=${parseResult.aboveThresholdCount} " +
                      "max=${"%.3f".format(parseResult.maxClassScore)}",
              )
              addAll(
                  parseResult.detections.take(5).map { detection ->
                    "${detection.label}:${"%.2f".format(detection.score)}@" +
                        "${detection.left.roundDebug()},${detection.top.roundDebug()}," +
                        "${detection.right.roundDebug()},${detection.bottom.roundDebug()}"
                  },
              )
            }
        parsedDetections =
            parseResult.detections.map { detection ->
              detection.toPayload(
                  sourceWidth = config.sourceWidth,
                  sourceHeight = config.sourceHeight,
                  inputWidth = config.inputWidth,
                  inputHeight = config.inputHeight,
              )
            }
        if (parseResult.acceptedCount > 0) {
          stage = "overlay_payload_ready"
          blocker = null
        } else {
          stage = "awaiting_detection_payload"
          blocker = "parser_zero_detections"
        }
      } else {
        parserStrategy = null
        parserScoreThreshold = null
        parserAboveThresholdCount = 0
        parserMaxClassScore = null
        parsedDetections = emptyList()
        stage = "awaiting_output_parser"
        blocker = "parser_shape_unsupported"
      }
    } catch (t: Throwable) {
      forwardFailures += 1
      val failureMessage =
          t.stackTraceToString().lineSequence().firstOrNull()?.trim().orEmpty()
              .ifBlank { t.message ?: t::class.java.simpleName }
      lastError = failureMessage
      if (!preprocessDone) {
        resetForwardFailureTracking()
        stage = "preprocess_failed"
        blocker = "preprocess_error"
      } else {
        val qnnForwardIssue = classifyQnnForwardFailure(config, failureMessage)
        if (qnnForwardIssue != null) {
          noteForwardFailure(qnnForwardIssue.blocker)
          if (repeatedForwardFailureCount >= qnnForwardRetryThreshold) {
            qnnRetryBlockedUntilElapsedMs =
                SystemClock.elapsedRealtime() + qnnForwardRetryBackoffMs
            stage = "backend_unavailable"
            blocker = qnnDspTransportFailedBlocker
            lastError =
                "Repeated QNN delegate failures. " +
                    "Backing off for ${qnnForwardRetryBackoffMs}ms. " +
                    "Last error: $failureMessage"
          } else {
            stage = qnnForwardIssue.stage
            blocker = qnnForwardIssue.blocker
            lastError = qnnForwardIssue.message
          }
        } else {
          resetForwardFailureTracking()
          stage = "inference_failed"
          blocker = "executorch_forward_failed"
        }
      }
      parsedDetections = emptyList()
    }
  }

  override fun snapshot(): NativeDriveYoloRuntimeSnapshot {
    return NativeDriveYoloRuntimeSnapshot(
        runtimeReady = module != null,
        pixelPathReady = pixelFramesConsumed > 0,
        stage = stage,
        blocker = blocker,
        backend = config.runtimeBackend,
        backendAvailable = backendSupport.available,
        backendReason = backendSupport.reason,
        backendNativeLibs = backendSupport.nativeLibs,
        backendNativeLibDir = backendSupport.nativeLibDir,
        backendPackagingMode = backendSupport.packagingMode,
        backendAssetFiles = backendSupport.assetFiles,
        backendRuntimeDir = qnnRuntimeDir,
        backendEnvReady = qnnEnvReady,
        modelVariant = config.modelVariant,
        inferenceRequests = inferenceRequests,
        lastRequestedFrameId = lastRequestedFrameId,
        pixelFramesConsumed = pixelFramesConsumed,
        modelPath = modelPath,
        modelSource = modelSource,
        modelSearchPaths = candidatePaths,
        modelMetadataPath = modelMetadata.metadataPath,
        modelMetadataSource = modelMetadata.metadataSource,
        modelMetadataOutputName = modelMetadata.outputName,
        modelMetadataSoc = modelMetadata.soc,
        modelMetadataQnnSdkVersion = modelMetadata.qnnSdkVersion,
        modelMetadataExecutorchRef = modelMetadata.executorchRef,
        modelMetadataUseFp16 = modelMetadata.useFp16,
        modelMetadataOnlinePrepare = modelMetadata.onlinePrepare,
        modelMetadataImgsz = modelMetadata.imgsz,
        modelMetadataBatch = modelMetadata.batch,
        modelMetadataParseError = modelMetadata.parseError,
        lastError = lastError,
        forwardSuccesses = forwardSuccesses,
        forwardFailures = forwardFailures,
        lastPreprocessMs = lastPreprocessMs,
        lastForwardMs = lastForwardMs,
        lastOutputShapes = lastOutputShapes,
        lastOutputDtypes = lastOutputDtypes,
        lastOutputPreview = lastOutputPreview,
        parsedCandidateCount = parsedCandidateCount,
        parsedDetectionCount = parsedDetectionCount,
        parserStrategy = parserStrategy,
        parserScoreThreshold = parserScoreThreshold,
        parserAboveThresholdCount = parserAboveThresholdCount,
        parserMaxClassScore = parserMaxClassScore,
        parsedDetectionsPreview = parsedDetectionsPreview,
        parsedDetections = parsedDetections,
    )
  }

  override fun release() {
    releaseModule()
    config = NativeDriveYoloConfig.disabled
    stage = "idle"
    blocker = "disabled"
    candidatePaths = emptyList()
    modelMetadata = NativeDriveYoloModelMetadata()
    backendSupport = NativeDriveYoloBackendSupport()
    qnnRuntimeDir = null
    qnnEnvReady = false
    lastError = null
    resetForwardFailureTracking()
    inferenceRequests = 0
    lastRequestedFrameId = -1
    pixelFramesConsumed = 0
    forwardSuccesses = 0
    forwardFailures = 0
    lastPreprocessMs = null
    lastForwardMs = null
    lastOutputShapes = emptyList()
    lastOutputDtypes = emptyList()
      lastOutputPreview = emptyList()
      parsedCandidateCount = 0
      parsedDetectionCount = 0
      parserStrategy = null
      parserScoreThreshold = null
      parserAboveThresholdCount = 0
      parserMaxClassScore = null
      parsedDetectionsPreview = emptyList()
      parsedDetections = emptyList()
      reusableInputBuffer = null
    reusablePixels = null
    reusableInputShape = longArrayOf(1, 3, 0, 0)
  }

  private fun ensureModuleLoaded(forceReload: Boolean) {
    if (!config.enabled) return
    backendSupport = probeBackendSupport(config)
    if (!config.unsafeRuntimeEnabled) {
      releaseModule()
      stage = "runtime_disabled"
      blocker = "unsafe_runtime_disabled"
      lastError = null
      modelMetadata = NativeDriveYoloModelMetadata()
      resetForwardFailureTracking()
      return
    }
    if (!backendSupport.available) {
      releaseModule()
      stage = "backend_unavailable"
      blocker = backendSupport.reason ?: "backend_unavailable"
      lastError = null
      modelMetadata = NativeDriveYoloModelMetadata()
      resetForwardFailureTracking()
      return
    }
    if (shouldGuardQnnLoweredRuntime(config)) {
      applyQnnLoweredRuntimeGuard()
      return
    }
    if (config.runtimeBackend.contains("qnn", ignoreCase = true)) {
      val prepared = NativeDriveQnnRuntimeFiles.prepare(appContext, backendSupport.nativeLibDir)
      qnnRuntimeDir = prepared.runtimeDir
      qnnEnvReady = prepared.envConfigured
      if (!prepared.envConfigured) {
        releaseModule()
        stage = "backend_environment_unavailable"
        blocker = prepared.reason ?: "qnn_environment_unavailable"
        lastError = null
        modelMetadata = NativeDriveYoloModelMetadata()
        resetForwardFailureTracking()
        return
      }
    } else {
      qnnRuntimeDir = null
      qnnEnvReady = false
    }
    if (!forceReload && module != null) return

    val resolved = NativeDriveYoloModelLocator.resolve(appContext, config)
    candidatePaths = resolved.candidatePaths
    modelPath = resolved.modelPath
    modelSource = resolved.modelSource
    modelMetadata = NativeDriveYoloModelLocator.resolveMetadata(appContext, config, resolved)

    if (!resolved.found) {
      releaseModule()
      stage = "awaiting_model_asset"
      blocker = "model_asset_missing"
      lastError = null
      modelMetadata = NativeDriveYoloModelMetadata(candidatePaths = modelMetadata.candidatePaths)
      resetForwardFailureTracking()
      return
    }

    val metadataIssue = validateQnnModelCompatibility(config, modelMetadata)
    if (metadataIssue != null) {
      releaseModule()
      stage = metadataIssue.stage
      blocker = metadataIssue.blocker
      lastError = metadataIssue.message
      resetForwardFailureTracking()
      return
    }

    if (!forceReload && module != null && modelPath == resolved.modelPath) {
      return
    }

    releaseModule()
    try {
      module = Module.load(resolved.modelPath!!)
      // Do not eagerly call loadMethod("forward") here. On-device developer
      // playback can overlap with the stock live runtime during source
      // transitions, and forcing delegate/method initialization up front has
      // produced native SIGSEGV crashes in libexecutorch_jni.so. We keep the
      // module loaded and let the first forward() own method initialization.
      lastError = null
      resetForwardFailureTracking()
      stage = "awaiting_preprocess_pipeline"
      blocker = "preprocess_missing"
    } catch (t: Throwable) {
      releaseModule()
      lastError = summarizeThrowable(t)
      resetForwardFailureTracking()
      stage = "module_load_failed"
      blocker = "executorch_module_load_failed"
    }
  }

  private fun shouldGuardQnnLoweredRuntime(config: NativeDriveYoloConfig): Boolean {
    if (BuildConfig.ENABLE_QNN_LOWERED_RUNTIME) {
      return false
    }
    if (!config.runtimeBackend.contains("qnn", ignoreCase = true)) {
      return false
    }
    return NativeDriveYoloModelCatalog.isQnnLoweredReference(config.modelVariant)
  }

  private data class NativeDriveYoloRuntimeIssue(
      val stage: String,
      val blocker: String,
      val message: String,
  )

  private fun validateQnnModelCompatibility(
      config: NativeDriveYoloConfig,
      metadata: NativeDriveYoloModelMetadata,
  ): NativeDriveYoloRuntimeIssue? {
    if (!config.runtimeBackend.contains("qnn", ignoreCase = true) &&
        NativeDriveYoloModelCatalog.isQnnLoweredReference(config.modelVariant)) {
      return NativeDriveYoloRuntimeIssue(
          stage = "backend_unavailable",
          blocker = "qnn_model_requires_qnn_backend",
          message =
              "QNN-lowered model ${config.modelVariant} requires the ExecuTorch QNN backend.",
      )
    }
    if (!config.runtimeBackend.contains("qnn", ignoreCase = true)) {
      return null
    }
    if (!NativeDriveYoloModelCatalog.isQnnLoweredReference(config.modelVariant)) {
      return null
    }
    if (!metadata.present) {
      return NativeDriveYoloRuntimeIssue(
          stage = "awaiting_model_metadata",
          blocker = "qnn_model_metadata_missing",
          message =
              "QNN model metadata is missing. Re-export the model so " +
                  "<model>.metadata.json is packaged next to the .pte.",
      )
    }
    if (!metadata.parseError.isNullOrBlank()) {
      return NativeDriveYoloRuntimeIssue(
          stage = "awaiting_model_metadata",
          blocker = "qnn_model_metadata_invalid",
          message =
              "QNN model metadata could not be parsed: ${metadata.parseError}",
      )
    }

    val expectedNames =
        NativeDriveYoloModelCatalog
            .candidateBaseNamesFor(config.modelVariant)
            .map { NativeDriveYoloModelCatalog.normalize(it) }
            .toSet()
    val metadataOutputName = NativeDriveYoloModelCatalog.normalize(metadata.outputName)
    if (metadataOutputName.isBlank()) {
      return NativeDriveYoloRuntimeIssue(
          stage = "awaiting_model_metadata",
          blocker = "qnn_model_metadata_incomplete",
          message = "QNN model metadata is missing output_name.",
      )
    }
    if (metadataOutputName !in expectedNames) {
      return NativeDriveYoloRuntimeIssue(
          stage = "awaiting_model_metadata",
          blocker = "qnn_model_variant_mismatch",
          message =
              "QNN model metadata output_name=${metadata.outputName} does not match " +
                  "requested variant=${config.modelVariant}.",
      )
    }

    val exportedSdkVersion = metadata.qnnSdkVersion?.trim().orEmpty()
    if (exportedSdkVersion.isBlank()) {
      return NativeDriveYoloRuntimeIssue(
          stage = "awaiting_model_metadata",
          blocker = "qnn_model_metadata_incomplete",
          message = "QNN model metadata is missing qnn_sdk_version.",
      )
    }

    val packagedSdkVersion = BuildConfig.QNN_SDK_VERSION.trim()
    if (packagedSdkVersion.isNotEmpty() && packagedSdkVersion != exportedSdkVersion) {
      return NativeDriveYoloRuntimeIssue(
          stage = "backend_unavailable",
          blocker = "qnn_sdk_version_mismatch",
          message =
              "QNN export/runtime mismatch. Model was lowered with QNN SDK " +
                  "$exportedSdkVersion but the app packages $packagedSdkVersion.",
      )
    }

    return null
  }

  private fun classifyQnnForwardFailure(
      config: NativeDriveYoloConfig,
      failureMessage: String,
  ): NativeDriveYoloRuntimeIssue? {
    if (!config.runtimeBackend.contains("qnn", ignoreCase = true)) {
      return null
    }
    if (!NativeDriveYoloModelCatalog.isQnnLoweredReference(config.modelVariant)) {
      return null
    }
    val normalized = failureMessage.lowercase()
    if (!normalized.contains("execution failed for method: forward") &&
        !normalized.contains("internal error")) {
      return null
    }
    return NativeDriveYoloRuntimeIssue(
        stage = "inference_failed",
        blocker = qnnDelegateInitFailedBlocker,
        message =
            "QNN delegate initialization failed during forward(). " +
                "If this persists, inspect device logcat for QnnDsp transport/skel load errors.",
    )
  }

  private fun noteForwardFailure(signature: String) {
    if (lastForwardFailureSignature == signature) {
      repeatedForwardFailureCount += 1
    } else {
      lastForwardFailureSignature = signature
      repeatedForwardFailureCount = 1
    }
  }

  private fun resetForwardFailureTracking() {
    lastForwardFailureSignature = null
    repeatedForwardFailureCount = 0
    qnnRetryBlockedUntilElapsedMs = 0L
  }

  private fun isQnnRetryBackoffActive(config: NativeDriveYoloConfig): Boolean {
    if (!config.runtimeBackend.contains("qnn", ignoreCase = true)) {
      return false
    }
    if (!NativeDriveYoloModelCatalog.isQnnLoweredReference(config.modelVariant)) {
      return false
    }
    val until = qnnRetryBlockedUntilElapsedMs
    if (until <= 0L) {
      return false
    }
    val now = SystemClock.elapsedRealtime()
    if (now >= until) {
      qnnRetryBlockedUntilElapsedMs = 0L
      repeatedForwardFailureCount = 0
      lastForwardFailureSignature = null
      return false
    }
    return true
  }

  private fun applyQnnRetryBackoffState() {
    val remainingMs =
        (qnnRetryBlockedUntilElapsedMs - SystemClock.elapsedRealtime()).coerceAtLeast(0L)
    stage = "backend_unavailable"
    blocker = qnnDspTransportFailedBlocker
    lastError =
        "QNN delegate retries are temporarily paused after repeated failures. " +
            "Retrying in ${remainingMs}ms."
  }

  private fun applyQnnLoweredRuntimeGuard() {
    releaseModule()
    modelMetadata = NativeDriveYoloModelMetadata()
    lastError = qnnLoweredRuntimeGuardMessage
    resetForwardFailureTracking()
    stage = "backend_unavailable"
    blocker = qnnLoweredRuntimeGuardBlocker
  }

  private fun requiresModuleReload(
      previous: NativeDriveYoloConfig,
      next: NativeDriveYoloConfig,
  ): Boolean {
    if (!previous.enabled && next.enabled) return true
    if (previous.enabled != next.enabled) return true
    if (previous.runtimeBackend != next.runtimeBackend) return true
    if (previous.unsafeRuntimeEnabled != next.unsafeRuntimeEnabled) return true
    if (previous.modelVariant != next.modelVariant) return true
    if (previous.inputWidth != next.inputWidth) return true
    if (previous.inputHeight != next.inputHeight) return true
    return false
  }

  private fun releaseModule() {
    module = null
  }

  private fun probeBackendSupport(
      config: NativeDriveYoloConfig,
  ): NativeDriveYoloBackendSupport {
    val nativeDirPath = appContext.applicationInfo.nativeLibraryDir
    val nativeLibs = NativeDriveQnnRuntimeFiles.listPackagedNativeLibs(appContext)
    val packagingMode = BuildConfig.EXECUTORCH_PACKAGING_MODE
    val backend = config.runtimeBackend.trim().lowercase()
    if (backend.isBlank()) {
      return NativeDriveYoloBackendSupport(
          available = false,
          reason = "backend_unspecified",
          nativeLibs = nativeLibs,
          nativeLibDir = nativeDirPath,
          packagingMode = packagingMode,
      )
    }
    if (backend.contains("qnn")) {
      val normalizedLibs = nativeLibs.map { it.lowercase() }
      val packagedSkels = NativeDriveQnnRuntimeFiles.listPackagedSkels(appContext)
      val hasQnnBackendBridge =
          normalizedLibs.any { name ->
            name == "libqnn_executorch_backend.so"
          }
      val hasQnnHtpLib =
          normalizedLibs.any { name ->
            name == "libqnnhtp.so"
          }
      val hasQnnSystemLib =
          normalizedLibs.any { name ->
            name == "libqnnsystem.so"
          }
      val hasQnnStubLib =
          normalizedLibs.any { name ->
            name.startsWith("libqnnhtpv") && name.endsWith("stub.so")
          }
      return if (
          hasQnnBackendBridge &&
              hasQnnHtpLib &&
              hasQnnSystemLib &&
              hasQnnStubLib &&
              packagedSkels.isNotEmpty()) {
        NativeDriveYoloBackendSupport(
            available = true,
            nativeLibs = nativeLibs,
            nativeLibDir = nativeDirPath,
            packagingMode = packagingMode,
            assetFiles = packagedSkels,
        )
      } else {
        NativeDriveYoloBackendSupport(
            available = false,
            reason =
                if (!hasQnnBackendBridge) {
                  if (BuildConfig.USE_LOCAL_EXECUTORCH_AAR) {
                    "qnn_backend_bridge_missing"
                  } else {
                    "qnn_backend_not_packaged"
                  }
                } else if (!hasQnnHtpLib) {
                  "qnn_htp_runtime_missing"
                } else if (!hasQnnSystemLib) {
                  "qnn_system_runtime_missing"
                } else if (!hasQnnStubLib) {
                  "qnn_htp_stub_missing"
                } else if (packagedSkels.isEmpty()) {
                  "qnn_skel_assets_missing"
                } else if (BuildConfig.USE_LOCAL_EXECUTORCH_AAR) {
                  "qnn_runtime_libs_missing"
                } else {
                  "qnn_backend_not_packaged"
                },
            nativeLibs = nativeLibs,
            nativeLibDir = nativeDirPath,
            packagingMode = packagingMode,
            assetFiles = packagedSkels,
        )
      }
    }
    if (backend.contains("xnnpack")) {
      return NativeDriveYoloBackendSupport(
          available = true,
          nativeLibs = nativeLibs,
          nativeLibDir = nativeDirPath,
          packagingMode = packagingMode,
      )
    }
    return NativeDriveYoloBackendSupport(
        available = false,
        reason = "backend_unimplemented",
        nativeLibs = nativeLibs,
        nativeLibDir = nativeDirPath,
        packagingMode = packagingMode,
    )
  }

  private fun ensureInputBuffers() {
    val width = config.inputWidth.coerceAtLeast(32)
    val height = config.inputHeight.coerceAtLeast(32)
    val numel = width * height * 3
    val currentBuffer = reusableInputBuffer
    if (currentBuffer == null || currentBuffer.capacity() != numel) {
      reusableInputBuffer = Tensor.allocateFloatBuffer(numel)
    }
    val currentPixels = reusablePixels
    if (currentPixels == null || currentPixels.size != width * height) {
      reusablePixels = IntArray(width * height)
    }
    reusableInputShape = longArrayOf(1, 3, height.toLong(), width.toLong())
  }

  private fun preprocessBitmap(bitmap: Bitmap): Tensor {
    ensureInputBuffers()
    val width = config.inputWidth.coerceAtLeast(32)
    val height = config.inputHeight.coerceAtLeast(32)
    require(bitmap.width == width && bitmap.height == height) {
      "bitmap_size_mismatch:${bitmap.width}x${bitmap.height} expected=${width}x${height}"
    }

    val pixels = reusablePixels ?: error("pixel_buffer_unavailable")
    bitmap.getPixels(pixels, 0, width, 0, 0, width, height)

    val inputBuffer = reusableInputBuffer ?: error("input_buffer_unavailable")
    val planeSize = width * height
    for (index in 0 until planeSize) {
      val argb = pixels[index]
      inputBuffer.put(index, ((argb shr 16) and 0xFF) / 255.0f)
      inputBuffer.put(index + planeSize, ((argb shr 8) and 0xFF) / 255.0f)
      inputBuffer.put(index + (planeSize * 2), (argb and 0xFF) / 255.0f)
    }
    inputBuffer.rewind()
    return Tensor.fromBlob(inputBuffer, reusableInputShape)
  }

  private fun updateOutputDiagnostics(outputs: Array<EValue>) {
    val shapes = mutableListOf<String>()
    val dtypes = mutableListOf<String>()
    val preview = mutableListOf<String>()

    outputs.forEachIndexed { index, value ->
      if (!value.isTensor()) {
        shapes += "[$index]:non_tensor"
        dtypes += "[$index]:-"
        return@forEachIndexed
      }
      val tensor = value.toTensor()
      val shapeText = tensor.shape().joinToString(prefix = "[", postfix = "]")
      shapes += "[$index]$shapeText"
      dtypes += "[$index]:${tensor.dtype()}"

      val floats = runCatching { tensor.getDataAsFloatArray() }.getOrNull()
      if (floats != null && floats.isNotEmpty()) {
        val sampleCount = min(6, floats.size)
        val sampleText =
            (0 until sampleCount).joinToString(
                prefix = "[$index]:",
                separator = ",",
            ) { sampleIndex ->
              "%.4f".format(floats[sampleIndex])
            }
        preview += sampleText
      } else {
        preview += "[$index]:dtype=${tensor.dtype()} numel=${tensor.numel()}"
      }
    }

    lastOutputShapes = shapes
    lastOutputDtypes = dtypes
    lastOutputPreview = preview
  }

  private fun elapsedMs(startNs: Long): Double {
    return ((System.nanoTime() - startNs).coerceAtLeast(0L)) / 1_000_000.0
  }

  private fun Float.roundDebug(): String {
    return "%.1f".format(this)
  }
}
