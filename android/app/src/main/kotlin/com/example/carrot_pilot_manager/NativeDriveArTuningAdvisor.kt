package com.example.carrot_pilot_manager

internal object NativeDriveArTuningAdvisor {
    fun buildAdvice(
        scene: NativeDriveArScene?,
        rawBands: NativeDriveArRenderBands,
        smoothedBands: NativeDriveArRenderBands,
        rawPolicy: NativeDriveArRenderPolicy?,
        stabilizedPolicy: NativeDriveArRenderPolicy?,
    ): List<String> {
        if (scene == null) return listOf("scene_absent")
        val advice = linkedSetOf<String>()
        if (scene.presentation.layoutProfile == "wide_monitor") {
            advice += "wide_monitor_profile"
        }
        if (smoothedBands.overlayComplexityBand == "dense") {
            advice += "reduce_shell_clutter"
        } else if (smoothedBands.overlayComplexityBand == "busy") {
            advice += "tune_clutter_thresholds"
        }
        if (smoothedBands.anchorStabilityBand in setOf("poor", "lost")) {
            advice += "increase_anchor_smoothing"
        }
        if (smoothedBands.effectiveAnchorBand in setOf("poor", "lost")) {
            advice += "prefer_safe_fallback"
        } else if (smoothedBands.effectiveAnchorBand == "weak") {
            advice += "soften_anchored_blend"
        }
        if (rawBands.effectiveAnchorBand != smoothedBands.effectiveAnchorBand) {
            advice += "watch_band_flicker"
        }
        if (stabilizedPolicy != null && rawPolicy != null) {
            if (
                rawPolicy.effectiveRenderBudget != stabilizedPolicy.effectiveRenderBudget ||
                rawPolicy.drawGateChip != stabilizedPolicy.drawGateChip ||
                rawPolicy.allowAnchoredGuide != stabilizedPolicy.allowAnchoredGuide
            ) {
                advice += "policy_hysteresis_active"
            }
        }
        if (scene.presentation.distanceBucket == "immediate") {
            advice += "protect_immediate_cues"
        }
        if (scene.presentation.mode == "arrival") {
            advice += "protect_arrival_marker"
        }
        if (advice.isEmpty()) {
            advice += "stable"
        }
        return advice.toList()
    }
}
