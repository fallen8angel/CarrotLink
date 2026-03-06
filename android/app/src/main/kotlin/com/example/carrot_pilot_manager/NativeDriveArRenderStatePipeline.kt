package com.example.carrot_pilot_manager

internal data class NativeDriveArRenderFrame(
    val scene: NativeDriveArScene?,
    val policy: NativeDriveArRenderPolicy?,
    val debug: Map<String, Any?>?,
)

internal class NativeDriveArRenderStatePipeline {
    private val sceneRetainer = NativeDriveArSceneRetainer()
    private val anchorSmoother = NativeDriveArAnchorSmoother()
    private val sceneSanitizer = NativeDriveArSceneSanitizer()
    private val renderSmoother = NativeDriveArRenderSmoother()
    private val renderStabilizer = NativeDriveArRenderStabilizer()
    private val renderStatsTracker = NativeDriveArRenderStatsTracker()

    private var preparedScene: NativeDriveArScene? = null
    private var lastDebug: Map<String, Any?>? = null

    fun updateScene(scene: NativeDriveArScene?) {
        val retainedScene = sceneRetainer.update(scene)
        val smoothedScene = anchorSmoother.update(retainedScene)
        preparedScene = sceneSanitizer.sanitize(smoothedScene)
    }

    fun clear() {
        preparedScene = null
        lastDebug = null
        sceneRetainer.reset()
        anchorSmoother.reset()
        sceneSanitizer.sanitize(null)
        renderSmoother.reset()
        renderStabilizer.reset()
        renderStatsTracker.reset()
    }

    fun currentScene(): NativeDriveArScene? = preparedScene

    fun currentDebug(): Map<String, Any?>? = lastDebug

    fun resolveFrame(
        overlay: NativeDriveOverlayPayload?,
        drawWidth: Float,
    ): NativeDriveArRenderFrame {
        val scene = preparedScene
        val renderInputs =
            renderSmoother.update(
                scene = scene,
                overlay = overlay,
                anchorStabilityOverride = anchorSmoother.currentStabilityScore(),
            )
        val rawRenderPolicy =
            scene?.let {
                NativeDriveArRenderPolicy.resolve(
                    scene = it,
                    drawWidth = drawWidth,
                    overlayComplexity = renderInputs.smoothedOverlayComplexity,
                    anchorQualityOverride = renderInputs.effectiveAnchorQuality,
                )
            }
        val stabilizedRenderPolicy = rawRenderPolicy?.let { renderStabilizer.stabilize(it) }
        val baseDebug =
            renderSmoother.buildDebugMap(
                scene = scene,
                inputs = renderInputs,
                rawPolicy = rawRenderPolicy,
                stabilizedPolicy = stabilizedRenderPolicy,
                stabilizerDebug = renderStabilizer.buildDebugMap(rawRenderPolicy, stabilizedRenderPolicy),
                retentionDebug = sceneRetainer.buildDebugMap(),
                anchorSmoothingDebug = anchorSmoother.buildDebugMap(),
                sanitizerDebug = sceneSanitizer.buildDebugMap(),
            )
        lastDebug = renderStatsTracker.attach(baseDebug, hasScene = scene != null)
        return NativeDriveArRenderFrame(
            scene = scene,
            policy = stabilizedRenderPolicy,
            debug = lastDebug,
        )
    }
}
