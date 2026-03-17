package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean

private const val LITERT_TAG = "CarrotLiteRt"

// Locates .tflite model files from assets or absolute paths.
// Mirrors the search logic of NativeDriveYoloModelLocator but for the .tflite format.
internal object NativeDriveLiteRtModelLocator {
    private const val extractedDirName = "carrotlink_yolo_litert_models"

    fun resolve(context: Context, config: NativeDriveYoloConfig): NativeDriveLiteRtModelResolution {
        val requested = config.modelVariant.trim().ifEmpty { NativeDriveYoloConfig.DEFAULT_MODEL_VARIANT }
        val candidatePaths = linkedSetOf<String>()

        // Direct absolute path override (.tflite extension required)
        if (requested.startsWith("/") && requested.endsWith(".tflite")) {
            candidatePaths.add(requested)
            val f = File(requested)
            if (f.exists()) {
                return NativeDriveLiteRtModelResolution(
                    modelPath = f.absolutePath,
                    modelSource = "direct_path",
                    candidatePaths = candidatePaths.toList(),
                )
            }
        }

        val cacheDir = File(context.cacheDir, extractedDirName).also { it.mkdirs() }
        val candidateBaseNames = NativeDriveYoloModelCatalog.candidateTfliteBaseNamesFor(requested)

        // Search assets/models/ directory
        for (baseName in candidateBaseNames) {
            val assetPath = "models/$baseName.tflite"
            candidatePaths.add("assets:$assetPath")
            try {
                val bytes = context.assets.open(assetPath).use { it.readBytes() }
                val cached = File(cacheDir, "$baseName.tflite")
                FileOutputStream(cached).use { it.write(bytes) }
                Log.d(LITERT_TAG, "Model extracted from assets: $assetPath -> ${cached.absolutePath}")
                return NativeDriveLiteRtModelResolution(
                    modelPath = cached.absolutePath,
                    modelSource = "assets:$assetPath",
                    candidatePaths = candidatePaths.toList(),
                )
            } catch (_: Exception) { /* try next candidate */ }
        }

        return NativeDriveLiteRtModelResolution(candidatePaths = candidatePaths.toList())
    }
}

internal data class NativeDriveLiteRtModelResolution(
    val modelPath: String? = null,
    val modelSource: String? = null,
    val candidatePaths: List<String> = emptyList(),
) {
    val found: Boolean get() = !modelPath.isNullOrBlank()
}

// LiteRT (Google AI Edge) runtime implementing NativeDriveYoloRuntime.
//
// Delegate priority:
//   litert_gpu  -> GpuDelegate (OpenCL, Adreno) -> CPU fallback if GPU unavailable
//   litert_cpu  -> Interpreter default (XNNPACK thread pool)
//
// Model format: .tflite (FP16 for GPU, INT8 for future HTP path)
// Input:  NHWC [1, H, W, 3] float32, values in [0.0, 1.0]
// Output: [1, 84, anchors] float32  (same as ExecuTorch YOLO26 export)
internal class NativeDriveLiteRtRuntime(private val context: Context) : NativeDriveYoloRuntime {

    // ── State ─────────────────────────────────────────────────────────────────

    private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
    private var modelResolution: NativeDriveLiteRtModelResolution? = null

    // LiteRT core objects
    private var interpreter: Interpreter? = null
    private var gpuDelegate: GpuDelegate? = null
    private var actualBackend: String = "litert_cpu"

    // Inference stats
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

    // Stage / error tracking
    private var stage = "idle"
    private var blocker: String? = null
    private var lastError: String? = null

    // Backend availability
    private var backendAvailable = false
    private var backendReason: String? = null
    private var gpuCompatible = false

    // Single-thread executor for model init and inference
    private val inferenceExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "CarrotLiteRtInference").apply { isDaemon = true }
    }
    private var pendingInit: Future<*>? = null
    private val initializing = AtomicBoolean(false)
    private var previousConfig: NativeDriveYoloConfig? = null

    // ── NativeDriveYoloRuntime implementation ─────────────────────────────────

    override fun updateConfig(config: NativeDriveYoloConfig) {
        val prev = previousConfig
        this.config = config
        if (!config.enabled) {
            resetStats()
            stage = "idle"
            blocker = "disabled"
            return
        }
        if (needsReinit(prev, config)) {
            teardownInterpreter()
            stage = "initializing"
            blocker = null
            scheduleInit()
        }
        previousConfig = config
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
        runInference(frame, bitmap)
    }

    override fun snapshot(): NativeDriveYoloRuntimeSnapshot {
        return NativeDriveYoloRuntimeSnapshot(
            runtimeReady = interpreter != null && blocker == null,
            pixelPathReady = pixelFramesConsumed > 0,
            stage = stage,
            blocker = blocker,
            backend = config.runtimeBackend,
            backendAvailable = backendAvailable,
            backendReason = backendReason,
            backendNativeLibs = emptyList(),
            backendNativeLibDir = null,
            backendPackagingMode = "maven",
            backendAssetFiles = emptyList(),
            backendRuntimeDir = null,
            backendEnvReady = interpreter != null,
            modelVariant = config.modelVariant,
            inferenceRequests = inferenceRequests,
            lastRequestedFrameId = lastRequestedFrameId,
            pixelFramesConsumed = pixelFramesConsumed,
            modelPath = modelResolution?.modelPath,
            modelSource = modelResolution?.modelSource,
            modelSearchPaths = modelResolution?.candidatePaths ?: emptyList(),
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
        config = NativeDriveYoloConfig.disabled
        teardownInterpreter()
        resetStats()
        stage = "idle"
        blocker = "released"
    }

    // ── Initialization ────────────────────────────────────────────────────────

    private fun scheduleInit() {
        if (!initializing.compareAndSet(false, true)) return
        pendingInit?.cancel(false)
        pendingInit = inferenceExecutor.submit {
            try {
                doInit(config)
            } catch (e: Exception) {
                Log.e(LITERT_TAG, "Init failed: ${e.message}", e)
                stage = "error"
                blocker = "litert_init_failed"
                lastError = summarizeThrowable(e)
            } finally {
                initializing.set(false)
            }
        }
    }

    private fun doInit(cfg: NativeDriveYoloConfig) {
        Log.d(LITERT_TAG, "Initializing LiteRT runtime: backend=${cfg.runtimeBackend} variant=${cfg.modelVariant}")

        // 1. Check GPU compatibility
        val compatList = CompatibilityList()
        gpuCompatible = compatList.isDelegateSupportedOnThisDevice
        Log.d(LITERT_TAG, "GPU delegate compatible: $gpuCompatible")

        // 2. Locate model file
        stage = "resolving_model"
        val resolution = NativeDriveLiteRtModelLocator.resolve(context, cfg)
        modelResolution = resolution
        if (!resolution.found) {
            Log.e(LITERT_TAG, "Model file not found. Searched: ${resolution.candidatePaths}")
            stage = "error"
            blocker = "litert_model_not_found"
            lastError = "No .tflite model file found. Searched: ${resolution.candidatePaths}"
            backendAvailable = false
            backendReason = "model_not_found"
            return
        }
        Log.d(LITERT_TAG, "Model resolved: ${resolution.modelPath} (${resolution.modelSource})")

        // 3. Build Interpreter with optional GPU delegate
        stage = "loading_model"
        val modelFile = File(resolution.modelPath!!)
        val backend = cfg.runtimeBackend.trim().lowercase()
        val wantGpu = backend == "litert_gpu" || backend == "litert"
        val useGpu = wantGpu && gpuCompatible

        val options = Interpreter.Options()
        var newGpuDelegate: GpuDelegate? = null
        if (useGpu) {
            try {
                newGpuDelegate = GpuDelegate(compatList.bestOptionsForThisDevice)
                options.addDelegate(newGpuDelegate)
                actualBackend = "litert_gpu"
                Log.d(LITERT_TAG, "GpuDelegate created successfully")
            } catch (e: Exception) {
                Log.w(LITERT_TAG, "GpuDelegate creation failed, falling back to CPU: ${e.message}")
                newGpuDelegate?.close()
                newGpuDelegate = null
                actualBackend = "litert_cpu"
            }
        } else {
            if (wantGpu) Log.w(LITERT_TAG, "GPU not compatible on this device, using CPU")
            actualBackend = "litert_cpu"
        }
        options.setNumThreads(4)

        val newInterpreter: Interpreter
        try {
            newInterpreter = Interpreter(modelFile, options)
        } catch (e: Exception) {
            Log.e(LITERT_TAG, "Interpreter creation failed: ${e.message}", e)
            newGpuDelegate?.close()
            stage = "error"
            blocker = "litert_interpreter_load_failed"
            lastError = summarizeThrowable(e)
            backendAvailable = false
            backendReason = "interpreter_load_failed"
            return
        }

        // 4. Log tensor shapes for diagnostics
        try {
            val inShape = newInterpreter.getInputTensor(0).shape()
            val outShape = newInterpreter.getOutputTensor(0).shape()
            Log.d(LITERT_TAG, "Input tensor shape: ${inShape.toList()}")
            Log.d(LITERT_TAG, "Output tensor shape: ${outShape.toList()}")
        } catch (e: Exception) {
            Log.w(LITERT_TAG, "Could not read tensor shapes: ${e.message}")
        }

        // 5. Commit state
        gpuDelegate = newGpuDelegate
        interpreter = newInterpreter
        backendAvailable = true
        backendReason = if (newGpuDelegate != null) "gpu_delegate_ok" else "cpu_fallback"
        stage = "ready"
        blocker = null
        lastError = null
        Log.i(LITERT_TAG, "LiteRT runtime ready: actualBackend=$actualBackend")
    }

    // ── Inference ─────────────────────────────────────────────────────────────

    private fun runInference(frame: NativeDriveYoloFrame, bitmap: Bitmap) {
        val interp = interpreter ?: return
        if (stage != "ready") return

        inferenceExecutor.submit {
            try {
                doInference(interp, frame, bitmap)
            } catch (e: Exception) {
                Log.e(LITERT_TAG, "Inference error: ${e.message}", e)
                forwardFailures += 1
                lastError = summarizeThrowable(e)
            }
        }
    }

    private fun doInference(interp: Interpreter, frame: NativeDriveYoloFrame, bitmap: Bitmap) {
        val inputWidth = config.inputWidth.coerceAtLeast(32)
        val inputHeight = config.inputHeight.coerceAtLeast(32)

        // Preprocess: bitmap -> NHWC [1, H, W, 3] float32 ByteBuffer, values [0.0, 1.0]
        val preprocessStart = SystemClock.elapsedRealtimeNanos()
        val inputBuffer = preprocessBitmap(bitmap, inputWidth, inputHeight)
        lastPreprocessMs = (SystemClock.elapsedRealtimeNanos() - preprocessStart) / 1_000_000.0

        // Allocate output buffer
        val outTensor = interp.getOutputTensor(0)
        val outShape = outTensor.shape()
        val outSize = outShape.fold(1) { acc, dim -> acc * dim }
        val outputBuffer = FloatArray(outSize)

        // Run inference
        val forwardStart = SystemClock.elapsedRealtimeNanos()
        interp.run(inputBuffer, outputBuffer)
        lastForwardMs = (SystemClock.elapsedRealtimeNanos() - forwardStart) / 1_000_000.0
        forwardSuccesses += 1

        // Record output metadata
        val longShape = outShape.map { it.toLong() }.toLongArray()
        lastOutputShapes = listOf(longShape.joinToString(prefix = "[", postfix = "]"))
        lastOutputDtypes = listOf("float32")
        lastOutputPreview = listOf(outputBuffer.take(4).joinToString { "%.4f".format(it) })

        // Parse detections using the shared parser
        val parseResult = NativeDriveYoloParser.parse(
            outputShapes = listOf(longShape),
            outputTensors = listOf(outputBuffer),
            inputWidth = inputWidth,
            inputHeight = inputHeight,
        )
        if (parseResult != null) {
            parsedCandidateCount = parseResult.candidateCount
            parsedDetectionCount = parseResult.acceptedCount
            parserStrategy = parseResult.strategy
            parserScoreThreshold = parseResult.scoreThreshold.toDouble()
            parserAboveThresholdCount = parseResult.aboveThresholdCount
            parserMaxClassScore = parseResult.maxClassScore.toDouble()
            parsedDetectionsPreview = parseResult.detections.take(3).map { d ->
                "${d.label}(${"%.2f".format(d.score)})"
            }
            parsedDetections = parseResult.detections.map { d ->
                d.toPayload(
                    sourceWidth = frame.sourceWidth,
                    sourceHeight = frame.sourceHeight,
                    inputWidth = inputWidth,
                    inputHeight = inputHeight,
                )
            }
        } else {
            parsedCandidateCount = 0
            parsedDetectionCount = 0
            parsedDetections = emptyList()
            parsedDetectionsPreview = emptyList()
        }
    }

    // ── Preprocessing ─────────────────────────────────────────────────────────

    // Converts a Bitmap to a NHWC float32 ByteBuffer with values normalized to [0.0, 1.0].
    private fun preprocessBitmap(bitmap: Bitmap, width: Int, height: Int): ByteBuffer {
        val resized = if (bitmap.width == width && bitmap.height == height) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(bitmap, width, height, true)
        }

        // Allocate direct ByteBuffer: 1 * H * W * 3 channels * 4 bytes per float
        val buffer = ByteBuffer.allocateDirect(width * height * 3 * 4)
        buffer.order(ByteOrder.nativeOrder())

        val pixels = IntArray(width * height)
        resized.getPixels(pixels, 0, width, 0, 0, width, height)

        for (pixel in pixels) {
            buffer.putFloat(((pixel shr 16) and 0xFF) / 255.0f)  // R
            buffer.putFloat(((pixel shr 8) and 0xFF) / 255.0f)   // G
            buffer.putFloat((pixel and 0xFF) / 255.0f)            // B
        }

        buffer.rewind()
        if (resized !== bitmap) resized.recycle()
        return buffer
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun teardownInterpreter() {
        try { interpreter?.close() } catch (_: Exception) {}
        try { gpuDelegate?.close() } catch (_: Exception) {}
        interpreter = null
        gpuDelegate = null
    }

    private fun resetStats() {
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
        parsedDetections = emptyList()
        parsedDetectionsPreview = emptyList()
    }

    private fun needsReinit(prev: NativeDriveYoloConfig?, next: NativeDriveYoloConfig): Boolean {
        if (interpreter == null) return true
        if (prev == null) return true
        if (prev.runtimeBackend != next.runtimeBackend) return true
        if (prev.modelVariant != next.modelVariant) return true
        if (prev.inputWidth != next.inputWidth) return true
        if (prev.inputHeight != next.inputHeight) return true
        return false
    }

    private fun summarizeThrowable(e: Throwable): String {
        val sb = StringBuilder()
        var t: Throwable? = e
        var depth = 0
        while (t != null && depth < 4) {
            if (depth > 0) sb.append(" caused by: ")
            sb.append("${t.javaClass.simpleName}(${t.message?.take(200)})")
            t = t.cause
            depth++
        }
        return sb.toString()
    }
}
