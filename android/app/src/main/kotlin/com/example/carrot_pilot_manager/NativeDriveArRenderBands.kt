package com.example.carrot_pilot_manager

internal data class NativeDriveArRenderBands(
    val overlayComplexityBand: String,
    val anchorQualityBand: String,
    val anchorStabilityBand: String,
    val effectiveAnchorBand: String,
    val budgetBand: String,
    val degradationStage: String,
) {
    fun toDebugMap(): Map<String, Any?> =
        mapOf(
            "overlayComplexityBand" to overlayComplexityBand,
            "anchorQualityBand" to anchorQualityBand,
            "anchorStabilityBand" to anchorStabilityBand,
            "effectiveAnchorBand" to effectiveAnchorBand,
            "budgetBand" to budgetBand,
            "degradationStage" to degradationStage,
        )
}

internal object NativeDriveArRenderBanding {
    fun classify(
        scene: NativeDriveArScene?,
        overlayComplexity: Float,
        anchorQuality: Float,
        anchorStability: Float,
        effectiveAnchorQuality: Float,
        renderBudget: Int?,
    ): NativeDriveArRenderBands {
        val complexityBand = overlayComplexityBand(overlayComplexity)
        val qualityBand = anchorBand(anchorQuality)
        val stabilityBand = anchorBand(anchorStability)
        val effectiveBand = anchorBand(effectiveAnchorQuality)
        val budgetBand = budgetBand(renderBudget ?: scene?.presentation?.renderBudget ?: 0)
        val degradationStage =
            degradationStage(
                layoutProfile = scene?.presentation?.layoutProfile,
                budgetBand = budgetBand,
                complexityBand = complexityBand,
                effectiveAnchorBand = effectiveBand,
            )
        return NativeDriveArRenderBands(
            overlayComplexityBand = complexityBand,
            anchorQualityBand = qualityBand,
            anchorStabilityBand = stabilityBand,
            effectiveAnchorBand = effectiveBand,
            budgetBand = budgetBand,
            degradationStage = degradationStage,
        )
    }

    private fun overlayComplexityBand(value: Float): String =
        when {
            value >= NativeDriveArRenderTuning.veryClutteredThreshold -> "dense"
            value >= NativeDriveArRenderTuning.clutterThreshold -> "busy"
            value >= 0.32f -> "active"
            else -> "clear"
        }

    private fun anchorBand(value: Float): String =
        when {
            value >= 0.72f -> "strong"
            value >= 0.52f -> "good"
            value >= 0.34f -> "weak"
            value >= 0.18f -> "poor"
            else -> "lost"
        }

    private fun budgetBand(value: Int): String =
        when {
            value >= 3 -> "full"
            value == 2 -> "reduced"
            value == 1 -> "minimal"
            else -> "hidden"
        }

    private fun degradationStage(
        layoutProfile: String?,
        budgetBand: String,
        complexityBand: String,
        effectiveAnchorBand: String,
    ): String {
        if (layoutProfile == "wide_monitor") {
            return if (budgetBand == "hidden") "monitor_hidden" else "monitor"
        }
        return when {
            budgetBand == "hidden" -> "fallback_hidden"
            budgetBand == "minimal" && effectiveAnchorBand in setOf("poor", "lost") -> "fallback_minimal"
            complexityBand == "dense" -> "clutter_reduced"
            effectiveAnchorBand == "weak" -> "anchor_soft"
            effectiveAnchorBand in setOf("poor", "lost") -> "anchor_fallback"
            else -> "full"
        }
    }
}
