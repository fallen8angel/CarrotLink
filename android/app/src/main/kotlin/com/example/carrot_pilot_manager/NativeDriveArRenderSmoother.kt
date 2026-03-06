package com.example.carrot_pilot_manager

internal data class NativeDriveArRenderInputs(
    val rawOverlayComplexity: Float,
    val smoothedOverlayComplexity: Float,
    val rawAnchorQuality: Float,
    val smoothedAnchorQuality: Float,
    val rawAnchorStability: Float,
    val smoothedAnchorStability: Float,
    val effectiveAnchorQuality: Float,
)

internal class NativeDriveArRenderSmoother {
    private var initialized = false
    private var smoothedOverlayComplexity = 0f
    private var smoothedAnchorQuality = 0f
    private var smoothedAnchorStability = 0f

    fun reset() {
        initialized = false
        smoothedOverlayComplexity = 0f
        smoothedAnchorQuality = 0f
        smoothedAnchorStability = 0f
    }

    fun update(
        scene: NativeDriveArScene?,
        overlay: NativeDriveOverlayPayload?,
        anchorStabilityOverride: Float? = null,
    ): NativeDriveArRenderInputs {
        val rawOverlayComplexity = overlay?.complexityScore ?: 0f
        val rawAnchorQuality = scene?.screenAnchors?.qualityScore ?: 0f
        val rawAnchorStability = anchorStabilityOverride ?: 0f
        if (!initialized) {
            initialized = true
            smoothedOverlayComplexity = rawOverlayComplexity
            smoothedAnchorQuality = rawAnchorQuality
            smoothedAnchorStability = rawAnchorStability
        } else {
            val overlayBlend = NativeDriveArRenderTuning.overlayComplexityBlend()
            smoothedOverlayComplexity = blend(
                current = smoothedOverlayComplexity,
                target = rawOverlayComplexity,
                riseAlpha = overlayBlend.riseAlpha,
                fallAlpha = overlayBlend.fallAlpha,
            )
            val qualityBlend = NativeDriveArRenderTuning.anchorQualityBlend(scenePresent = scene != null)
            smoothedAnchorQuality = blend(
                current = smoothedAnchorQuality,
                target = rawAnchorQuality,
                riseAlpha = qualityBlend.riseAlpha,
                fallAlpha = qualityBlend.fallAlpha,
            )
            val stabilityBlend = NativeDriveArRenderTuning.anchorStabilityBlend(scenePresent = scene != null)
            smoothedAnchorStability = blend(
                current = smoothedAnchorStability,
                target = rawAnchorStability,
                riseAlpha = stabilityBlend.riseAlpha,
                fallAlpha = stabilityBlend.fallAlpha,
            )
        }
        val effectiveAnchorQuality = minOf(smoothedAnchorQuality, smoothedAnchorStability)
        return NativeDriveArRenderInputs(
            rawOverlayComplexity = rawOverlayComplexity,
            smoothedOverlayComplexity = smoothedOverlayComplexity,
            rawAnchorQuality = rawAnchorQuality,
            smoothedAnchorQuality = smoothedAnchorQuality,
            rawAnchorStability = rawAnchorStability,
            smoothedAnchorStability = smoothedAnchorStability,
            effectiveAnchorQuality = effectiveAnchorQuality,
        )
    }

    fun buildDebugMap(
        scene: NativeDriveArScene?,
        inputs: NativeDriveArRenderInputs,
        rawPolicy: NativeDriveArRenderPolicy?,
        stabilizedPolicy: NativeDriveArRenderPolicy?,
        stabilizerDebug: Map<String, Any?>?,
        retentionDebug: Map<String, Any?>?,
        anchorSmoothingDebug: Map<String, Any?>?,
        sanitizerDebug: Map<String, Any?>?,
    ): Map<String, Any?> {
        val rawBands =
            NativeDriveArRenderBanding.classify(
                scene = scene,
                overlayComplexity = inputs.rawOverlayComplexity,
                anchorQuality = inputs.rawAnchorQuality,
                anchorStability = inputs.rawAnchorStability,
                effectiveAnchorQuality = minOf(inputs.rawAnchorQuality, inputs.rawAnchorStability),
                renderBudget = rawPolicy?.effectiveRenderBudget,
            )
        val smoothedBands =
            NativeDriveArRenderBanding.classify(
                scene = scene,
                overlayComplexity = inputs.smoothedOverlayComplexity,
                anchorQuality = inputs.smoothedAnchorQuality,
                anchorStability = inputs.smoothedAnchorStability,
                effectiveAnchorQuality = inputs.effectiveAnchorQuality,
                renderBudget = stabilizedPolicy?.effectiveRenderBudget ?: rawPolicy?.effectiveRenderBudget,
            )
        val tuningAdvice =
            NativeDriveArTuningAdvisor.buildAdvice(
                scene = scene,
                rawBands = rawBands,
                smoothedBands = smoothedBands,
                rawPolicy = rawPolicy,
                stabilizedPolicy = stabilizedPolicy,
            )
        return mapOf(
            "layoutProfile" to scene?.presentation?.layoutProfile,
            "layoutProfileSpec" to NativeDriveArLayoutProfileTuning.buildDebugMap(scene?.presentation?.layoutProfile),
            "rawOverlayComplexity" to inputs.rawOverlayComplexity,
            "smoothedOverlayComplexity" to inputs.smoothedOverlayComplexity,
            "rawAnchorQuality" to inputs.rawAnchorQuality,
            "smoothedAnchorQuality" to inputs.smoothedAnchorQuality,
            "rawAnchorStability" to inputs.rawAnchorStability,
            "smoothedAnchorStability" to inputs.smoothedAnchorStability,
            "effectiveAnchorQuality" to inputs.effectiveAnchorQuality,
            "rawBands" to rawBands.toDebugMap(),
            "smoothedBands" to smoothedBands.toDebugMap(),
            "tuningAdvice" to tuningAdvice,
            "rawPolicy" to rawPolicy?.let {
                mapOf(
                    "effectiveAnchorQuality" to it.effectiveAnchorQuality,
                    "effectiveRenderBudget" to it.effectiveRenderBudget,
                    "drawCard" to it.drawCard,
                    "drawGateChip" to it.drawGateChip,
                    "drawStatusPill" to it.drawStatusPill,
                    "allowAnchoredGuide" to it.allowAnchoredGuide,
                    "drawRibbon" to it.drawRibbon,
                    "drawTrail" to it.drawTrail,
                    "drawGuideSecondary" to it.drawGuideSecondary,
                    "shellAlphaMultiplier" to it.shellAlphaMultiplier,
                    "anchoredAlphaMultiplier" to it.anchoredAlphaMultiplier,
                    "anchoredPlacementBlend" to it.anchoredPlacementBlend,
                    "guideAlphaMultiplier" to it.guideAlphaMultiplier,
                    "trailAlphaMultiplier" to it.trailAlphaMultiplier,
                )
            },
            "stabilizedPolicy" to stabilizedPolicy?.let {
                mapOf(
                    "effectiveAnchorQuality" to it.effectiveAnchorQuality,
                    "effectiveRenderBudget" to it.effectiveRenderBudget,
                    "drawCard" to it.drawCard,
                    "drawGateChip" to it.drawGateChip,
                    "drawStatusPill" to it.drawStatusPill,
                    "allowAnchoredGuide" to it.allowAnchoredGuide,
                    "drawRibbon" to it.drawRibbon,
                    "drawTrail" to it.drawTrail,
                    "drawGuideSecondary" to it.drawGuideSecondary,
                    "shellAlphaMultiplier" to it.shellAlphaMultiplier,
                    "anchoredAlphaMultiplier" to it.anchoredAlphaMultiplier,
                    "anchoredPlacementBlend" to it.anchoredPlacementBlend,
                    "guideAlphaMultiplier" to it.guideAlphaMultiplier,
                    "trailAlphaMultiplier" to it.trailAlphaMultiplier,
                )
            },
            "stabilizer" to stabilizerDebug,
            "retention" to retentionDebug,
            "anchorSmoothing" to anchorSmoothingDebug,
            "sanitizer" to sanitizerDebug,
            "tuning" to NativeDriveArRenderTuning.buildDebugMap(),
        )
    }

    private fun blend(
        current: Float,
        target: Float,
        riseAlpha: Float,
        fallAlpha: Float,
    ): Float {
        val alpha = if (target >= current) riseAlpha else fallAlpha
        return current + ((target - current) * alpha.coerceIn(0f, 1f))
    }
}
