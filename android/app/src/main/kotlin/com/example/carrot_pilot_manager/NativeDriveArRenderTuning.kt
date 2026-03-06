package com.example.carrot_pilot_manager

internal data class NativeDriveArBlendParams(
    val riseAlpha: Float,
    val fallAlpha: Float,
)

internal object NativeDriveArRenderTuning {
    const val clutterThreshold = 0.58f
    const val veryClutteredThreshold = 0.82f
    const val lowAnchorBudgetClampThreshold = 0.22f
    const val shellAnchorStrongThreshold = 0.34f
    const val shellAnchorMediumThreshold = 0.24f
    const val shellAnchorWeakThreshold = 0.14f
    const val preferAnchoredStatusThreshold = 0.18f
    const val allowAnchoredGuideThreshold = 0.30f
    const val drawRibbonThreshold = 0.42f
    const val drawGateChipThreshold = 0.30f

    fun overlayComplexityBlend(): NativeDriveArBlendParams = NativeDriveArBlendParams(0.30f, 0.14f)

    fun anchorQualityBlend(scenePresent: Boolean): NativeDriveArBlendParams =
        NativeDriveArBlendParams(0.24f, if (scenePresent) 0.12f else 0.22f)

    fun anchorStabilityBlend(scenePresent: Boolean): NativeDriveArBlendParams =
        NativeDriveArBlendParams(0.26f, if (scenePresent) 0.18f else 0.24f)

    fun stabilizerBudgetBlend(): NativeDriveArBlendParams = NativeDriveArBlendParams(0.34f, 0.18f)

    fun stabilizerAnchoredAlphaBlend(): NativeDriveArBlendParams = NativeDriveArBlendParams(0.24f, 0.18f)

    fun stabilizerAnchoredPlacementBlend(): NativeDriveArBlendParams = NativeDriveArBlendParams(0.20f, 0.16f)

    fun stabilizerShellAlphaBlend(): NativeDriveArBlendParams = NativeDriveArBlendParams(0.24f, 0.16f)

    fun stabilizerGuideAlphaBlend(): NativeDriveArBlendParams = NativeDriveArBlendParams(0.26f, 0.18f)

    fun stabilizerTrailAlphaBlend(): NativeDriveArBlendParams = NativeDriveArBlendParams(0.30f, 0.16f)

    fun stabilizerHoldFrames(key: String): Int =
        when (key) {
            "card" -> 6
            "gate_chip" -> 4
            "status_pill" -> 3
            "anchored_status" -> 6
            "anchored_guide" -> 5
            "ribbon" -> 4
            "trail" -> 4
            "guide_secondary" -> 3
            else -> 0
        }

    fun anchoredAlphaMultiplierFloor(
        immediate: Boolean,
        arrival: Boolean,
    ): Float =
        when {
            arrival -> 0.72f
            immediate -> 0.68f
            else -> 0.54f
        }

    fun anchoredPlacementBlendFloor(
        immediate: Boolean,
        arrival: Boolean,
    ): Float =
        when {
            arrival -> 0.58f
            immediate -> 0.52f
            else -> 0.40f
        }

    fun shellBudgetScale(budget: Int): Float =
        when (budget) {
            0 -> 0.80f
            1 -> 0.88f
            2 -> 0.96f
            else -> 1f
        }

    fun shellClutterScale(
        cluttered: Boolean,
        veryCluttered: Boolean,
        immediate: Boolean,
        arrival: Boolean,
    ): Float =
        when {
            veryCluttered -> if (immediate || arrival) 0.90f else 0.74f
            cluttered -> if (immediate || arrival) 0.96f else 0.86f
            else -> 1f
        }

    fun shellAnchorScale(
        wideMonitor: Boolean,
        showGuidePrimitive: Boolean,
        anchorQuality: Float,
    ): Float =
        when {
            wideMonitor -> 0.92f
            !showGuidePrimitive -> 1f
            anchorQuality >= shellAnchorStrongThreshold -> 1f
            anchorQuality >= shellAnchorMediumThreshold -> 0.92f
            anchorQuality >= shellAnchorWeakThreshold -> 0.82f
            else -> 0.72f
        }

    fun guideAlphaMultiplier(
        budget: Int,
        cluttered: Boolean,
        veryCluttered: Boolean,
        wideMonitor: Boolean,
        anchorQuality: Float,
        immediate: Boolean,
        arrival: Boolean,
    ): Float =
        when {
            budget <= 0 -> 0f
            veryCluttered -> if (immediate || arrival) 0.82f else 0.68f
            cluttered -> if (immediate || arrival) 0.92f else 0.82f
            wideMonitor -> 0.86f
            anchorQuality < 0.26f -> 0.76f
            else -> 1f
        }

    fun trailAlphaMultiplier(
        budget: Int,
        cluttered: Boolean,
        veryCluttered: Boolean,
        wideMonitor: Boolean,
        immediate: Boolean,
    ): Float =
        when {
            budget <= 1 -> 0f
            veryCluttered -> if (immediate) 0.72f else 0.58f
            cluttered -> 0.84f
            wideMonitor -> 0f
            else -> 1f
        }

    const val anchorResetPathCountDeltaThreshold = 6
    const val gateSnapDistancePx = 120f
    const val statusSnapDistancePx = 160f
    const val pathJumpSnapDistancePx = 180f

    fun pathBaseAlpha(distanceBucket: String): Float =
        when (distanceBucket) {
            "immediate" -> 0.42f
            "near" -> 0.34f
            "arrival" -> 0.38f
            else -> 0.28f
        }

    fun pointBaseAlpha(distanceBucket: String): Float =
        when (distanceBucket) {
            "immediate" -> 0.46f
            "near" -> 0.38f
            "arrival" -> 0.42f
            else -> 0.30f
        }

    fun stabilityPenaltyStart(kind: String): Float =
        when (kind) {
            "gate" -> 8f
            "status" -> 10f
            "path" -> 3f
            else -> 0f
        }

    fun stabilityPenaltyFull(kind: String): Float =
        when (kind) {
            "gate" -> 56f
            "status" -> 68f
            "path" -> 20f
            else -> 1f
        }

    fun retentionHoldBudget(scene: NativeDriveArScene): Int =
        when {
            scene.presentation.layoutProfile == "wide_monitor" -> 2
            scene.presentation.mode == "arrival" -> 5
            scene.presentation.distanceBucket == "immediate" -> 4
            else -> 6
        }

    fun retainedRenderBudget(
        sourceBudget: Int,
        retainedFraction: Float,
    ): Int =
        when {
            retainedFraction >= 0.66f -> (sourceBudget - 1).coerceAtLeast(1)
            retainedFraction >= 0.33f -> (sourceBudget - 2).coerceAtLeast(1)
            else -> 1
        }

    fun retainedGuideScale(retainedFraction: Float): Float =
        when {
            retainedFraction >= 0.66f -> 0.82f
            retainedFraction >= 0.33f -> 0.64f
            else -> 0.44f
        }

    fun retainedTrailScale(retainedFraction: Float): Float =
        when {
            retainedFraction >= 0.66f -> 0.72f
            retainedFraction >= 0.33f -> 0.42f
            else -> 0.0f
        }

    fun retainedShellScale(retainedFraction: Float): Float =
        when {
            retainedFraction >= 0.66f -> 0.88f
            retainedFraction >= 0.33f -> 0.72f
            else -> 0.54f
        }

    fun buildDebugMap(): Map<String, Any?> =
        mapOf(
            "clutterThreshold" to clutterThreshold,
            "veryClutteredThreshold" to veryClutteredThreshold,
            "lowAnchorBudgetClampThreshold" to lowAnchorBudgetClampThreshold,
            "preferAnchoredStatusThreshold" to preferAnchoredStatusThreshold,
            "allowAnchoredGuideThreshold" to allowAnchoredGuideThreshold,
            "drawRibbonThreshold" to drawRibbonThreshold,
            "drawGateChipThreshold" to drawGateChipThreshold,
            "anchorResetPathCountDeltaThreshold" to anchorResetPathCountDeltaThreshold,
            "gateSnapDistancePx" to gateSnapDistancePx,
            "statusSnapDistancePx" to statusSnapDistancePx,
            "pathJumpSnapDistancePx" to pathJumpSnapDistancePx,
            "holdFrames" to
                mapOf(
                    "card" to stabilizerHoldFrames("card"),
                    "gate_chip" to stabilizerHoldFrames("gate_chip"),
                    "status_pill" to stabilizerHoldFrames("status_pill"),
                    "anchored_status" to stabilizerHoldFrames("anchored_status"),
                    "anchored_guide" to stabilizerHoldFrames("anchored_guide"),
                    "ribbon" to stabilizerHoldFrames("ribbon"),
                    "trail" to stabilizerHoldFrames("trail"),
                    "guide_secondary" to stabilizerHoldFrames("guide_secondary"),
                ),
        )
}
