package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Bitmap
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
          add(if (requested.endsWith(".pte", ignoreCase = true)) requested else "$requested.pte")
          add(requested)
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

  private fun extractAssetIfPresent(
      context: Context,
      assetPath: String,
      fileName: String,
  ): File? {
    return try {
      context.assets.open(assetPath).use { input ->
        val outDir = File(context.noBackupFilesDir, extractedDirName)
        if (!outDir.exists()) {
          outDir.mkdirs()
        }
        val outFile = File(outDir, fileName)
        if (!outFile.exists() || outFile.length() <= 0L) {
          outFile.outputStream().use { output -> input.copyTo(output) }
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
  private val appContext = context.applicationContext
  private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
  private var module: Module? = null
  private var modelPath: String? = null
  private var modelSource: String? = null
  private var candidatePaths: List<String> = emptyList()
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
  private var parsedDetectionsPreview: List<String> = emptyList()
  private var reusableInputBuffer: FloatBuffer? = null
  private var reusablePixels: IntArray? = null
  private var reusableInputShape: LongArray = longArrayOf(1, 3, 0, 0)

  override fun updateConfig(config: NativeDriveYoloConfig) {
    val previous = this.config
    val reloadRequired = requiresModuleReload(previous, config)
    this.config = config
    if (!config.enabled) {
      releaseModule()
      stage = "idle"
      blocker = "disabled"
      candidatePaths = emptyList()
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
      parsedDetectionsPreview = emptyList()
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
    parsedDetectionsPreview = emptyList()
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
          )
      lastError = null
      if (parseResult != null) {
        parsedCandidateCount = parseResult.candidateCount
        parsedDetectionCount = parseResult.acceptedCount
        parsedDetectionsPreview =
            parseResult.detections.take(5).map { detection ->
              "${detection.label}:${"%.2f".format(detection.score)}@" +
                  "${detection.left.roundDebug()},${detection.top.roundDebug()}," +
                  "${detection.right.roundDebug()},${detection.bottom.roundDebug()}"
            }
        stage = "awaiting_overlay_projection"
        blocker = "overlay_draw_missing"
      } else {
        stage = "awaiting_output_parser"
        blocker = "parser_shape_unsupported"
      }
    } catch (t: Throwable) {
      forwardFailures += 1
      lastError = t.stackTraceToString().lineSequence().firstOrNull()?.trim().orEmpty()
          .ifBlank { t.message ?: t::class.java.simpleName }
      if (!preprocessDone) {
        stage = "preprocess_failed"
        blocker = "preprocess_error"
      } else {
        stage = "inference_failed"
        blocker = "executorch_forward_failed"
      }
    }
  }

  override fun snapshot(): NativeDriveYoloRuntimeSnapshot {
    return NativeDriveYoloRuntimeSnapshot(
        runtimeReady = module != null,
        pixelPathReady = pixelFramesConsumed > 0,
        stage = stage,
        blocker = blocker,
        backend = config.runtimeBackend,
        modelVariant = config.modelVariant,
        inferenceRequests = inferenceRequests,
        lastRequestedFrameId = lastRequestedFrameId,
        pixelFramesConsumed = pixelFramesConsumed,
        modelPath = modelPath,
        modelSource = modelSource,
        modelSearchPaths = candidatePaths,
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
        parsedDetectionsPreview = parsedDetectionsPreview,
    )
  }

  override fun release() {
    releaseModule()
    config = NativeDriveYoloConfig.disabled
    stage = "idle"
    blocker = "disabled"
    candidatePaths = emptyList()
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
    parsedDetectionsPreview = emptyList()
    reusableInputBuffer = null
    reusablePixels = null
    reusableInputShape = longArrayOf(1, 3, 0, 0)
  }

  private fun ensureModuleLoaded(forceReload: Boolean) {
    if (!config.enabled) return
    if (!forceReload && module != null) return

    val resolved = NativeDriveYoloModelLocator.resolve(appContext, config)
    candidatePaths = resolved.candidatePaths
    modelPath = resolved.modelPath
    modelSource = resolved.modelSource

    if (!resolved.found) {
      releaseModule()
      stage = "awaiting_model_asset"
      blocker = "model_asset_missing"
      lastError = null
      return
    }

    if (!forceReload && module != null && modelPath == resolved.modelPath) {
      return
    }

    releaseModule()
    try {
      module = Module.load(resolved.modelPath!!)
      try {
        module?.loadMethod("forward")
      } catch (_: Throwable) {}
      lastError = null
      stage = "awaiting_preprocess_pipeline"
      blocker = "preprocess_missing"
    } catch (t: Throwable) {
      releaseModule()
      lastError = t.message ?: t::class.java.simpleName
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
    if (previous.modelVariant != next.modelVariant) return true
    if (previous.inputWidth != next.inputWidth) return true
    if (previous.inputHeight != next.inputHeight) return true
    return false
  }

  private fun releaseModule() {
    module = null
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
