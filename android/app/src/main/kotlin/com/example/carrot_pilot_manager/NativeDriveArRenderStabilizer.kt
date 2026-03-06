package com.example.carrot_pilot_manager

import kotlin.math.abs

internal class NativeDriveArRenderStabilizer {
    private var initialized = false
    private var budgetState = 0f
    private var anchoredAlphaState = 0f
    private var anchoredPlacementState = 0f
    private var shellAlphaState = 0f
    private var guideAlphaState = 0f
    private var trailAlphaState = 0f

    private var cardHold = 0
    private var gateChipHold = 0
    private var statusPillHold = 0
    private var anchoredStatusHold = 0
    private var anchoredGuideHold = 0
    private var ribbonHold = 0
    private var trailHold = 0
    private var guideSecondaryHold = 0

    fun reset() {
        initialized = false
        budgetState = 0f
        anchoredAlphaState = 0f
        anchoredPlacementState = 0f
        shellAlphaState = 0f
        guideAlphaState = 0f
        trailAlphaState = 0f
        cardHold = 0
        gateChipHold = 0
        statusPillHold = 0
        anchoredStatusHold = 0
        anchoredGuideHold = 0
        ribbonHold = 0
        trailHold = 0
        guideSecondaryHold = 0
    }

    fun stabilize(raw: NativeDriveArRenderPolicy): NativeDriveArRenderPolicy {
        if (!initialized) {
            initialized = true
            budgetState = raw.effectiveRenderBudget.toFloat()
            anchoredAlphaState = raw.anchoredAlphaMultiplier
            anchoredPlacementState = raw.anchoredPlacementBlend
            shellAlphaState = raw.shellAlphaMultiplier
            guideAlphaState = raw.guideAlphaMultiplier
            trailAlphaState = raw.trailAlphaMultiplier
        } else {
            val budgetBlend = NativeDriveArRenderTuning.stabilizerBudgetBlend()
            budgetState = blend(
                current = budgetState,
                target = raw.effectiveRenderBudget.toFloat(),
                riseAlpha = budgetBlend.riseAlpha,
                fallAlpha = budgetBlend.fallAlpha,
            )
            val anchoredAlphaBlend = NativeDriveArRenderTuning.stabilizerAnchoredAlphaBlend()
            anchoredAlphaState = blend(
                current = anchoredAlphaState,
                target = raw.anchoredAlphaMultiplier,
                riseAlpha = anchoredAlphaBlend.riseAlpha,
                fallAlpha = anchoredAlphaBlend.fallAlpha,
            )
            val anchoredPlacementBlend = NativeDriveArRenderTuning.stabilizerAnchoredPlacementBlend()
            anchoredPlacementState = blend(
                current = anchoredPlacementState,
                target = raw.anchoredPlacementBlend,
                riseAlpha = anchoredPlacementBlend.riseAlpha,
                fallAlpha = anchoredPlacementBlend.fallAlpha,
            )
            val shellBlend = NativeDriveArRenderTuning.stabilizerShellAlphaBlend()
            shellAlphaState = blend(
                current = shellAlphaState,
                target = raw.shellAlphaMultiplier,
                riseAlpha = shellBlend.riseAlpha,
                fallAlpha = shellBlend.fallAlpha,
            )
            val guideBlend = NativeDriveArRenderTuning.stabilizerGuideAlphaBlend()
            guideAlphaState = blend(
                current = guideAlphaState,
                target = raw.guideAlphaMultiplier,
                riseAlpha = guideBlend.riseAlpha,
                fallAlpha = guideBlend.fallAlpha,
            )
            val trailBlend = NativeDriveArRenderTuning.stabilizerTrailAlphaBlend()
            trailAlphaState = blend(
                current = trailAlphaState,
                target = raw.trailAlphaMultiplier,
                riseAlpha = trailBlend.riseAlpha,
                fallAlpha = trailBlend.fallAlpha,
            )
        }

        val stabilizedBudget = discreteBudget(budgetState)
        val stabilizedAnchoredAlpha = anchoredAlphaState.coerceIn(0f, 1f)
        val stabilizedAnchoredPlacement = anchoredPlacementState.coerceIn(0f, 1f)
        val stabilizedShellAlpha = shellAlphaState.coerceIn(0f, 1f)
        val stabilizedGuideAlpha = if (stabilizedBudget <= 0) 0f else guideAlphaState.coerceIn(0f, 1f)
        val stabilizedTrailAlpha = if (stabilizedBudget <= 1) 0f else trailAlphaState.coerceIn(0f, 1f)

        val drawCardResult =
            sticky(
                raw.drawCard,
                stabilizedBudget >= 2,
                cardHold,
                NativeDriveArRenderTuning.stabilizerHoldFrames("card"),
            )
        cardHold = drawCardResult.second
        val drawGateChipResult =
            sticky(
                raw.drawGateChip,
                stabilizedBudget >= 2,
                gateChipHold,
                NativeDriveArRenderTuning.stabilizerHoldFrames("gate_chip"),
            )
        gateChipHold = drawGateChipResult.second
        val drawStatusPillResult =
            sticky(
                raw.drawStatusPill,
                true,
                statusPillHold,
                NativeDriveArRenderTuning.stabilizerHoldFrames("status_pill"),
            )
        statusPillHold = drawStatusPillResult.second
        val anchoredStatusResult =
            sticky(
                raw.preferAnchoredStatus,
                stabilizedBudget >= 1,
                anchoredStatusHold,
                NativeDriveArRenderTuning.stabilizerHoldFrames("anchored_status"),
            )
        anchoredStatusHold = anchoredStatusResult.second
        val anchoredGuideResult =
            sticky(
                raw.allowAnchoredGuide,
                stabilizedBudget >= 1,
                anchoredGuideHold,
                NativeDriveArRenderTuning.stabilizerHoldFrames("anchored_guide"),
            )
        anchoredGuideHold = anchoredGuideResult.second
        val ribbonResult =
            sticky(
                raw.drawRibbon,
                stabilizedBudget >= 3,
                ribbonHold,
                NativeDriveArRenderTuning.stabilizerHoldFrames("ribbon"),
            )
        ribbonHold = ribbonResult.second
        val trailResult =
            sticky(
                raw.drawTrail,
                stabilizedBudget >= 2,
                trailHold,
                NativeDriveArRenderTuning.stabilizerHoldFrames("trail"),
            )
        trailHold = trailResult.second
        val secondaryResult =
            sticky(
                raw.drawGuideSecondary,
                stabilizedBudget >= 3,
                guideSecondaryHold,
                NativeDriveArRenderTuning.stabilizerHoldFrames("guide_secondary"),
            )
        guideSecondaryHold = secondaryResult.second

        return raw.copy(
            drawCard = drawCardResult.first,
            drawGateChip = drawGateChipResult.first,
            drawStatusPill = drawStatusPillResult.first,
            preferAnchoredStatus = anchoredStatusResult.first,
            allowAnchoredGuide = anchoredGuideResult.first,
            drawRibbon = ribbonResult.first,
            drawTrail = trailResult.first,
            drawGuideSecondary = secondaryResult.first,
            effectiveRenderBudget = stabilizedBudget,
            anchoredAlphaMultiplier = stabilizedAnchoredAlpha,
            anchoredPlacementBlend = stabilizedAnchoredPlacement,
            shellAlphaMultiplier = stabilizedShellAlpha,
            guideAlphaMultiplier = stabilizedGuideAlpha,
            trailAlphaMultiplier = stabilizedTrailAlpha,
        )
    }

    fun buildDebugMap(
        rawPolicy: NativeDriveArRenderPolicy?,
        stabilizedPolicy: NativeDriveArRenderPolicy?,
    ): Map<String, Any?> {
        return mapOf(
            "budgetState" to budgetState,
            "anchoredAlphaState" to anchoredAlphaState,
            "anchoredPlacementState" to anchoredPlacementState,
            "shellAlphaState" to shellAlphaState,
            "guideAlphaState" to guideAlphaState,
            "trailAlphaState" to trailAlphaState,
            "rawBudget" to rawPolicy?.effectiveRenderBudget,
            "stabilizedBudget" to stabilizedPolicy?.effectiveRenderBudget,
            "rawEffectiveAnchorQuality" to rawPolicy?.effectiveAnchorQuality,
            "stabilizedEffectiveAnchorQuality" to stabilizedPolicy?.effectiveAnchorQuality,
            "rawDrawCard" to rawPolicy?.drawCard,
            "stabilizedDrawCard" to stabilizedPolicy?.drawCard,
            "rawDrawGateChip" to rawPolicy?.drawGateChip,
            "stabilizedDrawGateChip" to stabilizedPolicy?.drawGateChip,
            "rawAllowAnchoredGuide" to rawPolicy?.allowAnchoredGuide,
            "stabilizedAllowAnchoredGuide" to stabilizedPolicy?.allowAnchoredGuide,
            "rawAnchoredAlpha" to rawPolicy?.anchoredAlphaMultiplier,
            "stabilizedAnchoredAlpha" to stabilizedPolicy?.anchoredAlphaMultiplier,
            "rawAnchoredPlacement" to rawPolicy?.anchoredPlacementBlend,
            "stabilizedAnchoredPlacement" to stabilizedPolicy?.anchoredPlacementBlend,
            "rawShellAlpha" to rawPolicy?.shellAlphaMultiplier,
            "stabilizedShellAlpha" to stabilizedPolicy?.shellAlphaMultiplier,
            "rawGuideAlpha" to rawPolicy?.guideAlphaMultiplier,
            "stabilizedGuideAlpha" to stabilizedPolicy?.guideAlphaMultiplier,
            "rawTrailAlpha" to rawPolicy?.trailAlphaMultiplier,
            "stabilizedTrailAlpha" to stabilizedPolicy?.trailAlphaMultiplier,
        )
    }

    private fun sticky(
        raw: Boolean,
        gateOpen: Boolean,
        currentHold: Int,
        holdFrames: Int,
    ): Pair<Boolean, Int> =
        when {
            raw && gateOpen -> {
                true to holdFrames
            }
            !gateOpen -> {
                false to 0
            }
            currentHold > 0 -> {
                true to (currentHold - 1)
            }
            else -> {
                false to 0
            }
        }

    private fun discreteBudget(value: Float): Int =
        when {
            value >= 2.5f -> 3
            value >= 1.5f -> 2
            value >= 0.5f -> 1
            else -> 0
        }

    private fun blend(
        current: Float,
        target: Float,
        riseAlpha: Float,
        fallAlpha: Float,
    ): Float {
        if (abs(target - current) < 0.001f) return target
        val alpha = if (target >= current) riseAlpha else fallAlpha
        return current + ((target - current) * alpha.coerceIn(0f, 1f))
    }
}
