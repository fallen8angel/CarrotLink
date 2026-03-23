package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode

import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.google.ai.edge.litert.Accelerator
import com.google.ai.edge.litert.BuiltinNpuAcceleratorProvider
import com.google.ai.edge.litert.CompiledModel
import com.google.ai.edge.litert.TensorBuffer
import java.io.File
import java.io.FileOutputStream
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
        val candidateBaseNames =
            NativeDriveYoloModelCatalog.candidateTfliteBaseNamesFor(
                requested,
                config.inputWidth,
                config.inputHeight,
            )

        val assetDirs =
            listOf(
                "yolo",
                "models",
                "flutter_assets/assets/yolo",
                "flutter_assets/assets/models",
            )

        for (assetDir in assetDirs) {
            for (baseName in candidateBaseNames) {
                val fileName = "$baseName.tflite"
                val assetPath = "$assetDir/$fileName"
                candidatePaths.add("assets:$assetPath")
                try {
                    val bytes = context.assets.open(assetPath).use { it.readBytes() }
                    val cached = File(cacheDir, fileName)
                    FileOutputStream(cached).use { it.write(bytes) }
                    Log.d(
                        LITERT_TAG,
                        "Model extracted from assets: $assetPath -> ${cached.absolutePath}",
                    )
                    return NativeDriveLiteRtModelResolution(
                        modelPath = cached.absolutePath,
                        modelSource = "assets:$assetPath",
                        candidatePaths = candidatePaths.toList(),
                    )
                } catch (_: Exception) {
                    // try next candidate
                }
            }
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

// LiteRT runtime using the modern CompiledModel API.
//
// Backend mapping:
//   litert_npu -> CompiledModel(Accelerator.NPU) only
//   litert_gpu -> CompiledModel(Accelerator.GPU) only
//   litert_cpu -> CompiledModel(Accelerator.CPU)
//
// Input:  NHWC [1, H, W, 3] float32, values in [0.0, 1.0]
// Output: [1, 84, anchors] float32 for YOLO26 detect exports
internal class NativeDriveLiteRtRuntime(private val context: Context) : NativeDriveYoloRuntime {

    @Volatile private var onInferenceReadyCallback: (() -> Unit)? = null

    override fun setOnInferenceReadyCallback(callback: (() -> Unit)?) {
        onInferenceReadyCallback = callback
    }

    private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
    private var modelResolution: NativeDriveLiteRtModelResolution? = null

    private var compiledModel: CompiledModel? = null
    private var inputBuffers: List<TensorBuffer>? = null
    private var outputBuffers: List<TensorBuffer>? = null
    private var actualBackend: String = "litert_cpu"
    private var backendRuntimeDirPath: String? = null
    private var backendEnvInitialized = false

    private var inferenceRequests = 0
    private var lastRequestedFrameId = -1
    private var pixelFramesConsumed = 0
    private var lastInferenceFrameId = -1
    private var lastInferencePtsUs = 0L
    private var lastInferenceElapsedMs: Double? = null
    private var forwardSuccesses = 0
    private var forwardFailures = 0
    private var inputTransferMode: String? = null
    private var directBitmapFrames = 0
    private var clonedBitmapFrames = 0
    private var lastInputAcquireMs: Double? = null
    private var lastPreprocessMs: Double? = null
    private var lastForwardMs: Double? = null
    private var lastPipelineMs: Double? = null
    private var lastOutputReadMs: Double? = null
    private var lastParseMs: Double? = null
    private var lastPayloadBuildMs: Double? = null
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
    private var inferenceSkippedBusy = 0
    private var cachedParserStrategy: String? = null
    private val inferenceInFlight = AtomicBoolean(false)

    // Double-buffering: hold one pending frame while inference runs.
    private data class PendingFrame(
        val frame: NativeDriveYoloFrame,
        val bitmap: Bitmap,
        val releaseBitmap: (() -> Unit)?,
    )
    private val pendingLock = Any()
    @Volatile private var pendingFrame: PendingFrame? = null
    private var reusablePixels: IntArray? = null
    private var reusableInputFloats: FloatArray? = null
    private var reusableScaledBitmap: Bitmap? = null
    private var reusableScaledCanvas: Canvas? = null
    private var reusableScaledRect: android.graphics.RectF? = null
    private val preprocessPaint = Paint(Paint.FILTER_BITMAP_FLAG).apply {
        // SRC xfermode: fully overwrite destination — skips alpha blending.
        xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC)
    }
    private val normalizedByteToFloat = FloatArray(256) { index -> index / 255.0f }
    @Volatile private var lastLetterbox: LetterboxTransform = LetterboxTransform.IDENTITY
    @Volatile private var lastBitmapFingerprint = 0L
    @Volatile private var duplicateFramesSkipped = 0

    private var stage = "idle"
    private var blocker: String? = null
    private var lastError: String? = null
    private var lastFailureStage: String? = null

    private var backendAvailable = false
    private var backendReason: String? = null
    private var initAttempts = 0
    private var gpuInitAttempts = 0
    private var gpuInitFailures = 0
    private var gpuBufferAllocFailures = 0
    private var cpuFallbackCount = 0

    private val inferenceExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "CarrotLiteRtInference").apply { isDaemon = true }
    }
    private var pendingInit: Future<*>? = null
    private val initializing = AtomicBoolean(false)
    private var previousConfig: NativeDriveYoloConfig? = null

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
            teardownRuntime()
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
        onPixelFrame(frame, bitmap, null)
    }

    override fun onPixelFrame(
        frame: NativeDriveYoloFrame,
        bitmap: Bitmap,
        releaseBitmap: (() -> Unit)?,
    ) {
        if (!config.enabled) {
            releaseBitmap?.invoke()
            return
        }
        pixelFramesConsumed += 1
        lastRequestedFrameId = frame.frameId
        runInference(frame, bitmap, releaseBitmap)
    }

    override fun snapshot(): NativeDriveYoloRuntimeSnapshot {
        return NativeDriveYoloRuntimeSnapshot(
            runtimeReady = compiledModel != null && blocker == null,
            pixelPathReady = pixelFramesConsumed > 0,
            stage = stage,
            blocker = blocker,
            backend = config.runtimeBackend,
            backendAvailable = backendAvailable,
            backendReason = backendReason,
            actualBackend = actualBackend,
            backendNativeLibs = emptyList(),
            backendNativeLibDir = null,
            backendPackagingMode = "maven",
            backendAssetFiles = emptyList(),
            backendRuntimeDir = backendRuntimeDirPath,
            backendEnvReady = backendEnvInitialized,
            modelVariant = config.modelVariant,
            inferenceRequests = inferenceRequests,
            lastRequestedFrameId = lastRequestedFrameId,
            pixelFramesConsumed = pixelFramesConsumed,
            inferenceInFlight = inferenceInFlight.get(),
            inferenceSkippedBusy = inferenceSkippedBusy,
            modelPath = modelResolution?.modelPath,
            modelSource = modelResolution?.modelSource,
            modelSearchPaths = modelResolution?.candidatePaths ?: emptyList(),
            lastError = lastError,
            lastFailureStage = lastFailureStage,
            initAttempts = initAttempts,
            gpuInitAttempts = gpuInitAttempts,
            gpuInitFailures = gpuInitFailures,
            gpuBufferAllocFailures = gpuBufferAllocFailures,
            cpuFallbackCount = cpuFallbackCount,
            forwardSuccesses = forwardSuccesses,
            forwardFailures = forwardFailures,
            inputTransferMode = inputTransferMode,
            directBitmapFrames = directBitmapFrames,
            clonedBitmapFrames = clonedBitmapFrames,
            lastInputAcquireMs = lastInputAcquireMs,
            lastPreprocessMs = lastPreprocessMs,
            lastForwardMs = lastForwardMs,
            lastPipelineMs = lastPipelineMs,
            lastOutputReadMs = lastOutputReadMs,
            lastParseMs = lastParseMs,
            lastPayloadBuildMs = lastPayloadBuildMs,
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
        config = NativeDriveYoloConfig.disabled
        synchronized(pendingLock) {
            pendingFrame?.releaseBitmap?.invoke()
            pendingFrame = null
        }
        teardownRuntime()
        resetStats()
        stage = "idle"
        blocker = "released"
    }

    private fun scheduleInit() {
        if (!initializing.compareAndSet(false, true)) return
        pendingInit?.cancel(false)
        pendingInit = inferenceExecutor.submit {
            try {
                initAttempts += 1
                doInit(config)
            } catch (e: Exception) {
                Log.e(LITERT_TAG, "Init failed: ${e.message}", e)
                stage = "error"
                blocker = "litert_init_failed"
                lastError = summarizeThrowable(e)
                lastFailureStage = "init"
            } finally {
                initializing.set(false)
            }
        }
    }

    private fun doInit(cfg: NativeDriveYoloConfig) {
        Log.d(LITERT_TAG, "Initializing LiteRT CompiledModel: backend=${cfg.runtimeBackend} variant=${cfg.modelVariant}")

        val resolution = NativeDriveLiteRtModelLocator.resolve(context, cfg)
        modelResolution = resolution
        if (!resolution.found) {
            stage = "error"
            blocker = "litert_model_not_found"
            lastError =
                "No .tflite model file found. Searched: ${resolution.candidatePaths}"
            backendAvailable = false
            backendReason = "model_not_found"
            return
        }

        stage = "loading_model"
        val modelFile = File(resolution.modelPath!!)
        val backend = cfg.runtimeBackend.trim().lowercase()
        val wantNpu = backend == "litert_npu" || backend == "litert_npu_only"
        val wantGpu = backend == "litert_gpu" || backend == "litert"
        if (wantGpu && isKnownBrokenCompiledGpuDevice()) {
            stage = "error"
            blocker = "litert_gpu_known_native_crash_risk"
            lastError =
                "Blocked CompiledModel GPU on this Samsung q7q device because LiteRT native createInputBuffers() is known to SIGBUS-crash here. Use NPU or a non-CompiledModel GPU path."
            lastFailureStage = "device_guard"
            backendAvailable = false
            backendReason = "compiled_gpu_device_blocked_known_native_createinputbuffers_sigbus"
            actualBackend = "litert_gpu"
            Log.e(
                LITERT_TAG,
                "Blocking CompiledModel GPU on device=${Build.DEVICE} model=${Build.MODEL} fingerprint=${Build.FINGERPRINT}",
            )
            return
        }
        if (wantNpu) {
            val npuProvider = BuiltinNpuAcceleratorProvider(context)
            if (!npuProvider.isDeviceSupported()) {
                stage = "error"
                blocker = "litert_npu_unsupported_device"
                lastError = "LiteRT NPU provider reports this device is not supported."
                lastFailureStage = "npu_compatibility_check"
                backendAvailable = false
                backendReason = "compiled_npu_device_unsupported"
                actualBackend = "litert_npu"
                backendRuntimeDirPath = null
                backendEnvInitialized = false
                return
            }
            if (!npuProvider.isLibraryReady()) {
                stage = "error"
                blocker = "litert_npu_library_not_ready"
                lastError =
                    "LiteRT NPU libraries are not ready. BuiltinNpuAcceleratorProvider requires built-in or install-time delivered NPU runtime libraries."
                lastFailureStage = "npu_library_ready"
                backendAvailable = false
                backendReason = "compiled_npu_library_not_ready"
                actualBackend = "litert_npu"
                backendRuntimeDirPath = try {
                    npuProvider.getLibraryDir()
                } catch (_: Exception) {
                    null
                }
                backendEnvInitialized = false
                return
            }
            backendRuntimeDirPath =
                try {
                    npuProvider.getLibraryDir()
                } catch (_: Exception) {
                    null
                }
            backendEnvInitialized = true
        } else {
            backendRuntimeDirPath = null
            backendEnvInitialized = false
        }
        if (wantGpu) {
            gpuInitAttempts += 1
        }

        val createdModel: CompiledModel
        actualBackend =
            when {
                wantNpu -> "litert_npu"
                wantGpu -> "litert_gpu"
                else -> "litert_cpu"
            }
        try {
            if (wantNpu) {
                createdModel =
                    CompiledModel.create(
                        modelFile.absolutePath,
                        CompiledModel.Options(Accelerator.NPU),
                    )
            } else if (wantGpu) {
                createdModel =
                    try {
                        CompiledModel.create(
                            modelFile.absolutePath,
                            CompiledModel.Options(Accelerator.GPU),
                        )
                    } catch (gpuError: Exception) {
                        gpuInitFailures += 1
                        throw gpuError
                    }
            } else {
                createdModel =
                    CompiledModel.create(
                        modelFile.absolutePath,
                        CompiledModel.Options(Accelerator.CPU),
                    )
            }
        } catch (e: Exception) {
            Log.e(LITERT_TAG, "CompiledModel creation failed: ${e.message}", e)
            stage = "error"
            blocker =
                when {
                    wantNpu -> "litert_npu_init_failed"
                    wantGpu -> "litert_gpu_init_failed"
                    else -> "litert_compiled_model_load_failed"
                }
            lastError = summarizeThrowable(e)
            lastFailureStage = "compiled_model_create"
            backendAvailable = false
            backendReason =
                when {
                    wantNpu -> "compiled_npu_init_failed"
                    wantGpu -> "compiled_gpu_init_failed"
                    else -> "compiled_model_load_failed"
                }
            return
        }

        val createdInputs: List<TensorBuffer> =
            try {
                createdModel.createInputBuffers()
            } catch (bufferError: Exception) {
                handleBufferAllocFailure(
                    model = createdModel,
                    error = bufferError,
                    wantNpu = wantNpu,
                    wantGpu = wantGpu,
                    failureStage =
                        when {
                            wantNpu -> "npu_input_buffer_alloc"
                            wantGpu -> "gpu_input_buffer_alloc"
                            else -> "input_buffer_alloc"
                        },
                    failureReason =
                        when {
                            wantNpu -> "compiled_npu_input_buffer_alloc_failed"
                            wantGpu -> "compiled_gpu_input_buffer_alloc_failed"
                            else -> "input_buffer_alloc_failed"
                        },
                )
                return
            }

        val createdOutputs: List<TensorBuffer> =
            try {
                createdModel.createOutputBuffers()
            } catch (bufferError: Exception) {
                handleBufferAllocFailure(
                    model = createdModel,
                    error = bufferError,
                    wantNpu = wantNpu,
                    wantGpu = wantGpu,
                    failureStage =
                        when {
                            wantNpu -> "npu_output_buffer_alloc"
                            wantGpu -> "gpu_output_buffer_alloc"
                            else -> "output_buffer_alloc"
                        },
                    failureReason =
                        when {
                            wantNpu -> "compiled_npu_output_buffer_alloc_failed"
                            wantGpu -> "compiled_gpu_output_buffer_alloc_failed"
                            else -> "output_buffer_alloc_failed"
                        },
                )
                return
            }

        compiledModel = createdModel
        inputBuffers = createdInputs
        outputBuffers = createdOutputs
        backendAvailable = true
        backendReason =
            when (actualBackend) {
                "litert_npu" -> "compiled_npu_ok"
                "litert_gpu" -> "compiled_gpu_ok"
                else -> "compiled_cpu_ok"
            }
        stage = "ready"
        blocker = null
        lastError = null
        lastFailureStage = null
        Log.i(LITERT_TAG, "LiteRT CompiledModel ready: actualBackend=$actualBackend")
    }

    private fun isKnownBrokenCompiledGpuDevice(): Boolean {
        val manufacturer = Build.MANUFACTURER.orEmpty().lowercase()
        val brand = Build.BRAND.orEmpty().lowercase()
        val device = Build.DEVICE.orEmpty().lowercase()
        val model = Build.MODEL.orEmpty().lowercase()
        val fingerprint = Build.FINGERPRINT.orEmpty().lowercase()
        if (manufacturer != "samsung" && brand != "samsung") {
            return false
        }
        return device.startsWith("q7q") ||
            fingerprint.contains("/q7q:") ||
            fingerprint.contains("q7qksx") ||
            model.contains("f966")
    }

    private fun handleBufferAllocFailure(
        model: CompiledModel,
        error: Exception,
        wantNpu: Boolean,
        wantGpu: Boolean,
        failureStage: String,
        failureReason: String,
    ) {
        if (wantGpu && actualBackend == "litert_gpu") {
            gpuBufferAllocFailures += 1
        }
        try {
            model.close()
        } catch (_: Exception) {}
        Log.e(LITERT_TAG, "CompiledModel buffer allocation failed: ${error.message}", error)
        stage = "error"
        blocker = "litert_buffer_alloc_failed"
        lastError = summarizeThrowable(error)
        lastFailureStage = failureStage
        backendAvailable = false
        backendReason = failureReason
    }

    private fun drainPendingFrame() {
        val next = synchronized(pendingLock) {
            val p = pendingFrame
            pendingFrame = null
            p
        }
        if (next != null) {
            runInference(next.frame, next.bitmap, next.releaseBitmap)
        } else {
            // Pipeline idle — signal controller to capture next frame immediately.
            try { onInferenceReadyCallback?.invoke() } catch (_: Throwable) {}
        }
    }

    private fun runInference(
        frame: NativeDriveYoloFrame,
        bitmap: Bitmap,
        releaseBitmap: (() -> Unit)?,
    ) {
        val model = compiledModel
        if (model == null || stage != "ready") {
            releaseBitmap?.invoke()
            return
        }
        if (!inferenceInFlight.compareAndSet(false, true)) {
            // Double-buffer: stash this frame so it runs immediately after
            // the current inference finishes, instead of being lost.
            synchronized(pendingLock) {
                val old = pendingFrame
                pendingFrame = PendingFrame(frame, bitmap, releaseBitmap)
                // Release previously pending frame if any.
                old?.releaseBitmap?.invoke()
            }
            inferenceSkippedBusy += 1
            return
        }
        val inputAcquireStart = SystemClock.elapsedRealtimeNanos()
        val useDirectBitmap = releaseBitmap != null
        val inferenceBitmap =
            if (useDirectBitmap) {
                inputTransferMode = "bitmap_pool_direct"
                directBitmapFrames += 1
                bitmap
            } else {
                try {
                    inputTransferMode = "bitmap_clone_fallback"
                    clonedBitmapFrames += 1
                    cloneBitmapForInference(bitmap)
                } catch (e: Exception) {
                    Log.e(LITERT_TAG, "Bitmap snapshot failed: ${e.message}", e)
                    forwardFailures += 1
                    lastError = summarizeThrowable(e)
                    inferenceInFlight.set(false)
                    return
                }
            }
        lastInputAcquireMs = (SystemClock.elapsedRealtimeNanos() - inputAcquireStart) / 1_000_000.0

        inferenceExecutor.submit {
            try {
                doInference(model, frame, inferenceBitmap)
            } catch (e: Exception) {
                Log.e(LITERT_TAG, "Inference error: ${e.message}", e)
                forwardFailures += 1
                lastError = summarizeThrowable(e)
            } finally {
                if (useDirectBitmap) {
                    releaseBitmap?.invoke()
                } else if (!inferenceBitmap.isRecycled) {
                    inferenceBitmap.recycle()
                }
                inferenceInFlight.set(false)
                // Double-buffer: immediately process pending frame.
                drainPendingFrame()
            }
        }
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

    private fun doInference(model: CompiledModel, frame: NativeDriveYoloFrame, bitmap: Bitmap) {
        val inputWidth = config.inputWidth.coerceAtLeast(32)
        val inputHeight = config.inputHeight.coerceAtLeast(32)
        val liveRoadMode = isLiveRoadFastPath(frame)

        // Skip duplicate frames: if bitmap content is identical to last inference, reuse results.
        val fingerprint = bitmapFingerprint(bitmap)
        if (fingerprint != 0L && fingerprint == lastBitmapFingerprint && parsedDetections.isNotEmpty()) {
            duplicateFramesSkipped += 1
            lastInferenceFrameId = frame.frameId
            lastInferencePtsUs = frame.ptsUs
            return
        }
        lastBitmapFingerprint = fingerprint

        val pipelineStart = SystemClock.elapsedRealtimeNanos()
        lastOutputReadMs = null
        lastParseMs = null
        lastPayloadBuildMs = null
        val localInputs = inputBuffers ?: error("litert_input_buffers_missing")
        val localOutputs = outputBuffers ?: error("litert_output_buffers_missing")
        if (localInputs.isEmpty() || localOutputs.isEmpty()) {
            throw IllegalStateException("litert_compiled_buffers_empty")
        }

        val preprocessStart = SystemClock.elapsedRealtimeNanos()
        val inputValues = preprocessBitmap(bitmap, inputWidth, inputHeight)
        lastPreprocessMs = (SystemClock.elapsedRealtimeNanos() - preprocessStart) / 1_000_000.0

        val forwardStart = SystemClock.elapsedRealtimeNanos()
        localInputs[0].writeFloat(inputValues)
        model.run(localInputs, localOutputs)
        lastForwardMs = (SystemClock.elapsedRealtimeNanos() - forwardStart) / 1_000_000.0
        forwardSuccesses += 1

        val outputReadStart = SystemClock.elapsedRealtimeNanos()
        val outputBuffer = localOutputs[0].readFloat()
        lastOutputReadMs = (SystemClock.elapsedRealtimeNanos() - outputReadStart) / 1_000_000.0
        val outShape = inferOutputShape(outputBuffer.size)
        val longShape = outShape.map { it.toLong() }.toLongArray()
        lastOutputShapes = listOf(longShape.joinToString(prefix = "[", postfix = "]"))
        lastOutputDtypes = listOf("FLOAT32")
        lastOutputPreview = listOf(outputBuffer.take(4).joinToString { ((it * 10000).toInt() / 10000.0).toString() })

        val parseStart = SystemClock.elapsedRealtimeNanos()
        val parseResult = NativeDriveYoloParser.parse(
            outputShapes = listOf(longShape),
            outputTensors = listOf(outputBuffer),
            inputWidth = inputWidth,
            inputHeight = inputHeight,
            strategyHint = cachedParserStrategy,
            liveRoadMode = liveRoadMode,
            includeTrafficLights = config.showTrafficLights,
            modelVariant = config.modelVariant,
        )
        lastParseMs = (SystemClock.elapsedRealtimeNanos() - parseStart) / 1_000_000.0
        if (parseResult != null) {
            cachedParserStrategy = parseResult.strategy
            parsedCandidateCount = parseResult.candidateCount
            parsedDetectionCount = parseResult.acceptedCount
            parserStrategy =
                buildString {
                    append(parseResult.strategy)
                    append("/")
                    append(parseResult.coordinateMode)
                    if (liveRoadMode) {
                        append("/live_road")
                    }
                }
            parserScoreThreshold = parseResult.scoreThreshold.toDouble()
            parserAboveThresholdCount = parseResult.aboveThresholdCount
            parserMaxClassScore = parseResult.maxClassScore.toDouble()
            val payloadBuildStart = SystemClock.elapsedRealtimeNanos()
            parsedDetectionsPreview = parseResult.detections.take(3).map { d ->
                "${d.label}(${((d.score * 100).toInt())})"
            }
            parsedDetections = parseResult.detections.map { d ->
                d.toPayload(
                    sourceWidth = frame.sourceWidth,
                    sourceHeight = frame.sourceHeight,
                    inputWidth = inputWidth,
                    inputHeight = inputHeight,
                    letterbox = lastLetterbox,
                )
            }
            lastPayloadBuildMs = (SystemClock.elapsedRealtimeNanos() - payloadBuildStart) / 1_000_000.0
        } else {
            parsedCandidateCount = 0
            parsedDetectionCount = 0
            parsedDetections = emptyList()
            parsedDetectionsPreview = emptyList()
            lastPayloadBuildMs = 0.0
        }
        lastPipelineMs = (SystemClock.elapsedRealtimeNanos() - pipelineStart) / 1_000_000.0
        lastInferenceFrameId = frame.frameId
        lastInferencePtsUs = frame.ptsUs
        lastInferenceElapsedMs = lastPipelineMs
    }

    private fun preprocessBitmap(bitmap: Bitmap, width: Int, height: Int): FloatArray {
        ensureInputBuffers(width, height)
        val preparedBitmap = prepareBitmapForInput(bitmap, width, height)
        val pixels = reusablePixels ?: error("litert_pixel_buffer_unavailable")
        val floats = reusableInputFloats ?: error("litert_float_buffer_unavailable")
        preparedBitmap.getPixels(pixels, 0, width, 0, 0, width, height)

        val lut = normalizedByteToFloat
        val count = pixels.size
        val unrolledEnd = count - (count % 4)
        var i = 0
        var o = 0
        // Process 4 pixels per iteration to reduce loop overhead.
        while (i < unrolledEnd) {
            val p0 = pixels[i]
            val p1 = pixels[i + 1]
            val p2 = pixels[i + 2]
            val p3 = pixels[i + 3]
            floats[o]     = lut[(p0 shr 16) and 0xFF]
            floats[o + 1] = lut[(p0 shr 8) and 0xFF]
            floats[o + 2] = lut[p0 and 0xFF]
            floats[o + 3] = lut[(p1 shr 16) and 0xFF]
            floats[o + 4] = lut[(p1 shr 8) and 0xFF]
            floats[o + 5] = lut[p1 and 0xFF]
            floats[o + 6] = lut[(p2 shr 16) and 0xFF]
            floats[o + 7] = lut[(p2 shr 8) and 0xFF]
            floats[o + 8] = lut[p2 and 0xFF]
            floats[o + 9] = lut[(p3 shr 16) and 0xFF]
            floats[o + 10] = lut[(p3 shr 8) and 0xFF]
            floats[o + 11] = lut[p3 and 0xFF]
            i += 4
            o += 12
        }
        // Remainder.
        while (i < count) {
            val p = pixels[i++]
            floats[o]     = lut[(p shr 16) and 0xFF]
            floats[o + 1] = lut[(p shr 8) and 0xFF]
            floats[o + 2] = lut[p and 0xFF]
            o += 3
        }
        return floats
    }

    private fun ensureInputBuffers(width: Int, height: Int) {
        val pixelCount = width * height
        val currentPixels = reusablePixels
        if (currentPixels == null || currentPixels.size != pixelCount) {
            reusablePixels = IntArray(pixelCount)
        }
        val requiredFloats = pixelCount * 3
        val currentFloats = reusableInputFloats
        if (currentFloats == null || currentFloats.size != requiredFloats) {
            reusableInputFloats = FloatArray(requiredFloats)
        }
    }

    private fun prepareBitmapForInput(bitmap: Bitmap, width: Int, height: Int): Bitmap {
        if (bitmap.width == width && bitmap.height == height) {
            lastLetterbox = LetterboxTransform.IDENTITY
            return bitmap
        }
        val lb = LetterboxTransform.compute(bitmap.width, bitmap.height, width, height)
        lastLetterbox = lb
        val target = obtainReusableScaledBitmap(width, height)
        val canvas = reusableScaledCanvas ?: error("litert_scaled_bitmap_canvas_unavailable")
        // Fill with YOLO letterbox gray (114/255 ≈ 0.447).
        target.eraseColor(android.graphics.Color.rgb(114, 114, 114))
        val scaledW = bitmap.width * lb.scale
        val scaledH = bitmap.height * lb.scale
        val dstRect = reusableScaledRect
            ?: android.graphics.RectF().also { reusableScaledRect = it }
        dstRect.set(lb.padLeft, lb.padTop, lb.padLeft + scaledW, lb.padTop + scaledH)
        canvas.drawBitmap(bitmap, null, dstRect, preprocessPaint)
        return target
    }

    private fun obtainReusableScaledBitmap(width: Int, height: Int): Bitmap {
        val existing = reusableScaledBitmap
        if (existing != null &&
            !existing.isRecycled &&
            existing.width == width &&
            existing.height == height) {
            return existing
        }
        if (existing != null && !existing.isRecycled) {
            existing.recycle()
        }
        val scaledBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        reusableScaledBitmap = scaledBitmap
        reusableScaledCanvas = Canvas(scaledBitmap)
        reusableScaledRect = null
        return scaledBitmap
    }

    private fun isLiveRoadFastPath(frame: NativeDriveYoloFrame): Boolean {
        return frame.camera.equals("road", ignoreCase = true) &&
            frame.sourceWidth >= 1000 &&
            frame.sourceHeight >= 600
    }

    private fun inferOutputShape(flatCount: Int): IntArray {
        if (flatCount <= 0) {
            throw IllegalArgumentException("litert_output_empty")
        }
        if (flatCount % 84 == 0) {
            return intArrayOf(1, 84, flatCount / 84)
        }
        return intArrayOf(1, flatCount)
    }

    private fun cloneBitmapForInference(bitmap: Bitmap): Bitmap {
        check(!bitmap.isRecycled) { "source_bitmap_recycled" }
        return bitmap.copy(Bitmap.Config.ARGB_8888, false)
            ?: throw IllegalStateException("bitmap_copy_failed")
    }

    private fun teardownRuntime() {
        try { inputBuffers?.forEach { it.close() } } catch (_: Exception) {}
        try { outputBuffers?.forEach { it.close() } } catch (_: Exception) {}
        try { compiledModel?.close() } catch (_: Exception) {}
        inputBuffers = null
        outputBuffers = null
        compiledModel = null
        backendRuntimeDirPath = null
        backendEnvInitialized = false
        inferenceInFlight.set(false)
        cachedParserStrategy = null
        reusablePixels = null
        reusableInputFloats = null
        val scaledBitmap = reusableScaledBitmap
        if (scaledBitmap != null && !scaledBitmap.isRecycled) {
            scaledBitmap.recycle()
        }
        reusableScaledBitmap = null
        reusableScaledCanvas = null
        reusableScaledRect = null
    }

    private fun resetStats() {
        inferenceRequests = 0
        lastRequestedFrameId = -1
        pixelFramesConsumed = 0
        inferenceSkippedBusy = 0
        forwardSuccesses = 0
        forwardFailures = 0
        inputTransferMode = null
        directBitmapFrames = 0
        clonedBitmapFrames = 0
        lastInputAcquireMs = null
        lastPreprocessMs = null
        lastForwardMs = null
        lastPipelineMs = null
        lastOutputReadMs = null
        lastParseMs = null
        lastPayloadBuildMs = null
        lastOutputShapes = emptyList()
        lastOutputDtypes = emptyList()
        lastOutputPreview = emptyList()
        parsedCandidateCount = 0
        parsedDetectionCount = 0
        parserStrategy = null
        parserScoreThreshold = null
        parserAboveThresholdCount = 0
        parserMaxClassScore = null
        parsedDetections = emptyList()
        parsedDetectionsPreview = emptyList()
        cachedParserStrategy = null
    }

    private fun needsReinit(prev: NativeDriveYoloConfig?, next: NativeDriveYoloConfig): Boolean {
        if (compiledModel == null) return true
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
            val message =
                t.message
                    ?.replace(Regex("\\s+"), " ")
                    ?.trim()
                    ?.take(600)
            sb.append("${t.javaClass.simpleName}($message)")
            t = t.cause
            depth++
        }
        return sb.toString()
    }
}
