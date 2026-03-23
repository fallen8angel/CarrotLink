package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Bitmap
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
  private data class NativeDriveYoloBackendSupport(
      val available: Boolean = false,
      val reason: String? = null,
      val nativeLibs: List<String> = emptyList(),
      val nativeLibDir: String? = null,
      val packagingMode: String = BuildConfig.EXECUTORCH_PACKAGING_MODE,
      val assetFiles: List<String> = emptyList(),
  )

  @Volatile private var onInferenceReadyCallback: (() -> Unit)? = null

  override fun setOnInferenceReadyCallback(callback: (() -> Unit)?) {
    onInferenceReadyCallback = callback
  }

  private val appContext = context.applicationContext
  private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
  private var module: Module? = null
  private var modelPath: String? = null
  private var modelSource: String? = null
  private var candidatePaths: List<String> = emptyList()
  private var modelMetadata: NativeDriveYoloModelMetadata = NativeDriveYoloModelMetadata()
  private var backendSupport = NativeDriveYoloBackendSupport()
  private var lastError: String? = null
  private var stage: String = "idle"
  private var blocker: String? = "disabled"
  private var inferenceRequests = 0
  private var lastRequestedFrameId = -1
  private var pixelFramesConsumed = 0
  private var lastInferenceFrameId = -1
  private var lastInferencePtsUs = 0L
  private var lastInferenceElapsedMs: Double? = null
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
  private var reusableInputBuffer: FloatBuffer? = null
  private var reusablePixels: IntArray? = null
  private var reusableInputShape: LongArray = longArrayOf(1, 3, 0, 0)
  private var reusableScaledBitmap: android.graphics.Bitmap? = null
  private var reusableScaledCanvas: android.graphics.Canvas? = null
  @Volatile private var lastLetterbox: LetterboxTransform = LetterboxTransform.IDENTITY
  @Volatile private var lastBitmapFingerprint = 0L
  @Volatile private var duplicateFramesSkipped = 0

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
      return
    }
    if (!backendSupport.available) {
      releaseModule()
      stage = "backend_unavailable"
      blocker = backendSupport.reason ?: "backend_unavailable"
      lastError = null
      candidatePaths = emptyList()
      modelMetadata = NativeDriveYoloModelMetadata()
      reusableInputBuffer = null
      reusablePixels = null
      reusableInputShape = longArrayOf(1, 3, 0, 0)
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
    pixelFramesConsumed += 1
    lastRequestedFrameId = frame.frameId
    if (module == null) {
      ensureModuleLoaded(forceReload = false)
      return
    }
    // Skip duplicate frames: if bitmap content is identical to last inference, reuse results.
    val fingerprint = bitmapFingerprint(bitmap)
    if (fingerprint != 0L && fingerprint == lastBitmapFingerprint && parsedDetections.isNotEmpty()) {
      duplicateFramesSkipped += 1
      lastInferenceFrameId = frame.frameId
      lastInferencePtsUs = frame.ptsUs
      return
    }
    lastBitmapFingerprint = fingerprint
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
              modelVariant = config.modelVariant,
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
                      "thr=${((parseResult.scoreThreshold * 100).toInt())} " +
                      "above=${parseResult.aboveThresholdCount} " +
                      "max=${((parseResult.maxClassScore * 1000).toInt() / 1000.0)}",
              )
              addAll(
                  parseResult.detections.take(5).map { detection ->
                    "${detection.label}:${((detection.score * 100).toInt())}@" +
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
                  letterbox = lastLetterbox,
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
        stage = "preprocess_failed"
        blocker = "preprocess_error"
      } else {
        stage = "inference_failed"
        blocker = "executorch_forward_failed"
      }
      parsedDetections = emptyList()
    }
    lastInferenceFrameId = frame.frameId
    lastInferencePtsUs = frame.ptsUs
    lastInferenceElapsedMs = lastForwardMs
    // Pipeline idle — signal controller to capture next frame immediately.
    try { onInferenceReadyCallback?.invoke() } catch (_: Throwable) {}
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
        backendRuntimeDir = null,
        backendEnvReady = false,
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
        lastInferenceFrameId = lastInferenceFrameId,
        lastInferencePtsUs = lastInferencePtsUs,
        lastInferenceElapsedMs = lastInferenceElapsedMs,
    )
  }

  override fun release() {
    onInferenceReadyCallback = null
    releaseModule()
    config = NativeDriveYoloConfig.disabled
    stage = "idle"
    blocker = "disabled"
    candidatePaths = emptyList()
    modelMetadata = NativeDriveYoloModelMetadata()
    backendSupport = NativeDriveYoloBackendSupport()
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
      reusableInputBuffer = null
    reusablePixels = null
    reusableInputShape = longArrayOf(1, 3, 0, 0)
    reusableScaledBitmap?.let { if (!it.isRecycled) it.recycle() }
    reusableScaledBitmap = null
    reusableScaledCanvas = null
    lastLetterbox = LetterboxTransform.IDENTITY
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
      return
    }
    if (!backendSupport.available) {
      releaseModule()
      stage = "backend_unavailable"
      blocker = backendSupport.reason ?: "backend_unavailable"
      lastError = null
      modelMetadata = NativeDriveYoloModelMetadata()
      return
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
      stage = "awaiting_preprocess_pipeline"
      blocker = "preprocess_missing"
    } catch (t: Throwable) {
      releaseModule()
      lastError = summarizeThrowable(t)
      stage = "module_load_failed"
      blocker = "executorch_module_load_failed"
    }
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
    val nativeLibs =
        File(nativeDirPath)
            .listFiles()
            ?.mapNotNull { it.name.takeIf { name -> name.endsWith(".so") } }
            ?.sorted()
            ?: emptyList()
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
    val prepared = prepareBitmapForInput(bitmap, width, height)

    val pixels = reusablePixels ?: error("pixel_buffer_unavailable")
    prepared.getPixels(pixels, 0, width, 0, 0, width, height)

    val inputBuffer = reusableInputBuffer ?: error("input_buffer_unavailable")
    val planeSize = width * height
    // Write each colour plane sequentially for better cache locality.
    val inv = 1.0f / 255.0f
    val rOff = 0
    val gOff = planeSize
    val bOff = planeSize * 2
    val unrolledEnd = planeSize - (planeSize % 4)
    var i = 0
    while (i < unrolledEnd) {
      val a0 = pixels[i]; val a1 = pixels[i + 1]; val a2 = pixels[i + 2]; val a3 = pixels[i + 3]
      inputBuffer.put(rOff + i,     ((a0 shr 16) and 0xFF) * inv)
      inputBuffer.put(rOff + i + 1, ((a1 shr 16) and 0xFF) * inv)
      inputBuffer.put(rOff + i + 2, ((a2 shr 16) and 0xFF) * inv)
      inputBuffer.put(rOff + i + 3, ((a3 shr 16) and 0xFF) * inv)
      inputBuffer.put(gOff + i,     ((a0 shr 8) and 0xFF) * inv)
      inputBuffer.put(gOff + i + 1, ((a1 shr 8) and 0xFF) * inv)
      inputBuffer.put(gOff + i + 2, ((a2 shr 8) and 0xFF) * inv)
      inputBuffer.put(gOff + i + 3, ((a3 shr 8) and 0xFF) * inv)
      inputBuffer.put(bOff + i,     (a0 and 0xFF) * inv)
      inputBuffer.put(bOff + i + 1, (a1 and 0xFF) * inv)
      inputBuffer.put(bOff + i + 2, (a2 and 0xFF) * inv)
      inputBuffer.put(bOff + i + 3, (a3 and 0xFF) * inv)
      i += 4
    }
    while (i < planeSize) {
      val argb = pixels[i]
      inputBuffer.put(rOff + i, ((argb shr 16) and 0xFF) * inv)
      inputBuffer.put(gOff + i, ((argb shr 8) and 0xFF) * inv)
      inputBuffer.put(bOff + i, (argb and 0xFF) * inv)
      i++
    }
    inputBuffer.rewind()
    return Tensor.fromBlob(inputBuffer, reusableInputShape)
  }

  private fun bitmapFingerprint(bitmap: Bitmap): Long {
    val w = bitmap.width
    val h = bitmap.height
    if (w < 8 || h < 8) return 0L
    var hash = w.toLong() * 31 + h.toLong()
    val stepX = w / 4
    val stepY = h / 4
    for (i in 0 until 4) {
      for (j in 0 until 4) {
        val x = (stepX * i + stepX / 2).coerceIn(0, w - 1)
        val y = (stepY * j + stepY / 2).coerceIn(0, h - 1)
        hash = hash * 31 + bitmap.getPixel(x, y).toLong()
      }
    }
    return hash
  }

  private fun prepareBitmapForInput(bitmap: Bitmap, width: Int, height: Int): Bitmap {
    if (bitmap.width == width && bitmap.height == height) {
      lastLetterbox = LetterboxTransform.IDENTITY
      return bitmap
    }
    val lb = LetterboxTransform.compute(bitmap.width, bitmap.height, width, height)
    lastLetterbox = lb
    var target = reusableScaledBitmap
    if (target == null || target.isRecycled || target.width != width || target.height != height) {
      target?.let { if (!it.isRecycled) it.recycle() }
      target = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
      reusableScaledBitmap = target
      reusableScaledCanvas = android.graphics.Canvas(target)
    }
    target.eraseColor(android.graphics.Color.rgb(114, 114, 114))
    val canvas = reusableScaledCanvas ?: android.graphics.Canvas(target).also { reusableScaledCanvas = it }
    val scaledW = bitmap.width * lb.scale
    val scaledH = bitmap.height * lb.scale
    val dstRect = android.graphics.RectF(lb.padLeft, lb.padTop, lb.padLeft + scaledW, lb.padTop + scaledH)
    canvas.drawBitmap(bitmap, null, dstRect, null)
    return target
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
              val v = floats[sampleIndex]
              val intPart = v.toInt()
              val fracPart = ((v - intPart) * 10000).toInt().let { if (it < 0) -it else it }
              "$intPart.${fracPart.toString().padStart(4, '0')}"
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
    val intPart = this.toInt()
    val frac = ((this - intPart) * 10).toInt().let { if (it < 0) -it else it }
    return "$intPart.$frac"
  }
}
