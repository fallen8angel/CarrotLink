package com.example.carrot_pilot_manager

internal class NativeDriveArRenderStatsTracker {
    private var framesWithScene = 0
    private var framesWithoutScene = 0
    private var degradationStageChanges = 0
    private var budgetBandChanges = 0
    private var anchorBandChanges = 0
    private var unstableFrames = 0

    private var lastDegradationStage = ""
    private var lastBudgetBand = ""
    private var lastAnchorBand = ""

    private val stageCounts = linkedMapOf<String, Int>()

    fun reset() {
        framesWithScene = 0
        framesWithoutScene = 0
        degradationStageChanges = 0
        budgetBandChanges = 0
        anchorBandChanges = 0
        unstableFrames = 0
        lastDegradationStage = ""
        lastBudgetBand = ""
        lastAnchorBand = ""
        stageCounts.clear()
    }

    fun attach(debug: Map<String, Any?>?, hasScene: Boolean): Map<String, Any?>? {
        if (debug == null) {
            if (!hasScene) {
                framesWithoutScene += 1
            }
            return null
        }
        if (hasScene) {
            framesWithScene += 1
        } else {
            framesWithoutScene += 1
        }
        val smoothedBands = debug["smoothedBands"] as? Map<*, *>
        val stage = smoothedBands?.get("degradationStage")?.toString().orEmpty()
        val budgetBand = smoothedBands?.get("budgetBand")?.toString().orEmpty()
        val anchorBand = smoothedBands?.get("effectiveAnchorBand")?.toString().orEmpty()
        if (stage.isNotBlank()) {
            stageCounts[stage] = (stageCounts[stage] ?: 0) + 1
            if (lastDegradationStage.isNotBlank() && lastDegradationStage != stage) {
                degradationStageChanges += 1
            }
            lastDegradationStage = stage
        }
        if (budgetBand.isNotBlank()) {
            if (lastBudgetBand.isNotBlank() && lastBudgetBand != budgetBand) {
                budgetBandChanges += 1
            }
            lastBudgetBand = budgetBand
        }
        if (anchorBand.isNotBlank()) {
            if (lastAnchorBand.isNotBlank() && lastAnchorBand != anchorBand) {
                anchorBandChanges += 1
            }
            lastAnchorBand = anchorBand
        }
        val tuningAdvice = debug["tuningAdvice"] as? List<*>
        if (
            tuningAdvice?.any {
                val token = it?.toString().orEmpty()
                token == "watch_band_flicker" || token == "policy_hysteresis_active"
            } == true
        ) {
            unstableFrames += 1
        }
        return debug + ("stats" to buildDebugMap())
    }

    private fun buildDebugMap(): Map<String, Any?> =
        mapOf(
            "framesWithScene" to framesWithScene,
            "framesWithoutScene" to framesWithoutScene,
            "degradationStageChanges" to degradationStageChanges,
            "budgetBandChanges" to budgetBandChanges,
            "anchorBandChanges" to anchorBandChanges,
            "unstableFrames" to unstableFrames,
            "lastDegradationStage" to lastDegradationStage,
            "lastBudgetBand" to lastBudgetBand,
            "lastAnchorBand" to lastAnchorBand,
            "stageCounts" to stageCounts.toMap(),
        )
}
