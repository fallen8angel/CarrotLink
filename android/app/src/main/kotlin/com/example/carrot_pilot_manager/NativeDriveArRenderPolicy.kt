package com.example.carrot_pilot_manager

internal data class NativeDriveArRenderPolicy(
    val compactLayout: Boolean,
    val drawCard: Boolean,
    val drawGateChip: Boolean,
    val drawStatusPill: Boolean,
    val preferAnchoredStatus: Boolean,
    val allowAnchoredGuide: Boolean,
    val drawRibbon: Boolean,
    val drawTrail: Boolean,
    val drawGuideSecondary: Boolean,
    val effectiveAnchorQuality: Float,
    val effectiveRenderBudget: Int,
    val anchoredAlphaMultiplier: Float,
    val anchoredPlacementBlend: Float,
    val shellAlphaMultiplier: Float,
    val guideAlphaMultiplier: Float,
    val trailAlphaMultiplier: Float,
) {
    companion object {
        fun resolve(
            scene: NativeDriveArScene,
            drawWidth: Float,
            overlayComplexity: Float,
            anchorQualityOverride: Float? = null,
        ): NativeDriveArRenderPolicy {
            val profile = NativeDriveArLayoutProfileTuning.resolve(scene.presentation.layoutProfile)
            val immediate = scene.presentation.distanceBucket == "immediate"
            val arrival = scene.presentation.mode == "arrival"
            val anchors = scene.screenAnchors
            val anchorQuality = anchorQualityOverride ?: anchors?.qualityScore ?: 0f
            val rawBands =
                NativeDriveArRenderBanding.classify(
                    scene = scene,
                    overlayComplexity = overlayComplexity,
                    anchorQuality = anchorQuality,
                    anchorStability = anchorQuality,
                    effectiveAnchorQuality = anchorQuality,
                    renderBudget = scene.presentation.renderBudget,
                )
            val wideMonitor = profile.isWideMonitor
            val cluttered = rawBands.overlayComplexityBand in setOf("busy", "dense")
            val veryCluttered = rawBands.overlayComplexityBand == "dense"

            var budget = scene.presentation.renderBudget.coerceAtLeast(0)
            if (cluttered) budget -= 1
            if (veryCluttered) budget -= 1
            if (profile.nonArrivalBudgetCap != null && !arrival) {
                budget = budget.coerceAtMost(profile.nonArrivalBudgetCap)
            }
            if (
                !wideMonitor &&
                !arrival &&
                anchorQuality < NativeDriveArRenderTuning.lowAnchorBudgetClampThreshold
            ) {
                budget = budget.coerceAtMost(1)
            }
            budget = budget.coerceAtLeast(0)

            val compactLayout =
                scene.presentation.compactPreferred ||
                    drawWidth < 720f ||
                    cluttered ||
                    profile.forceCompact

            val guideAlphaMultiplier =
                NativeDriveArRenderTuning.guideAlphaMultiplier(
                    budget = budget,
                    cluttered = cluttered,
                    veryCluttered = veryCluttered,
                    wideMonitor = wideMonitor,
                    anchorQuality = anchorQuality,
                    immediate = immediate,
                    arrival = arrival,
                )
            val anchoredAlphaMultiplier =
                buildAnchoredAlphaMultiplier(
                    anchorQuality = anchorQuality,
                    budget = budget,
                    immediate = immediate,
                    arrival = arrival,
                )
            val anchoredPlacementBlend =
                buildAnchoredPlacementBlend(
                    anchorQuality = anchorQuality,
                    budget = budget,
                    immediate = immediate,
                    arrival = arrival,
                )
            val shellAlphaMultiplier =
                buildShellAlphaMultiplier(
                    scene = scene,
                    budget = budget,
                    cluttered = cluttered,
                    veryCluttered = veryCluttered,
                    wideMonitor = wideMonitor,
                    anchorQuality = anchorQuality,
                    immediate = immediate,
                    arrival = arrival,
                )
            val trailAlphaMultiplier =
                NativeDriveArRenderTuning.trailAlphaMultiplier(
                    budget = budget,
                    cluttered = cluttered,
                    veryCluttered = veryCluttered,
                    wideMonitor = wideMonitor,
                    immediate = immediate,
                )

            val drawStatusPill = scene.presentation.showStatusPill
            val preferAnchoredStatus =
                drawStatusPill &&
                    profile.supportsAnchoredStatus &&
                    budget >= 1 &&
                    anchors?.supportsAnchoredStatus() == true &&
                    anchorQuality >= NativeDriveArRenderTuning.preferAnchoredStatusThreshold

            val allowAnchoredGuide =
                budget >= 1 &&
                    profile.supportsAnchoredGuide &&
                    anchors?.supportsAnchoredGuide(scene.presentation.mode) == true &&
                    anchorQuality >= NativeDriveArRenderTuning.allowAnchoredGuideThreshold

            val drawRibbon =
                allowAnchoredGuide &&
                    budget >= 3 &&
                    anchorQuality >= NativeDriveArRenderTuning.drawRibbonThreshold
            val drawTrail =
                scene.presentation.showGuideTrail &&
                    budget >= 2 &&
                    profile.supportsTrail
            val drawGuideSecondary =
                budget >= 3 &&
                    scene.presentation.detailLevel >= 2 &&
                    !veryCluttered &&
                    profile.supportsGuideSecondary

            val drawCard =
                scene.presentation.showCard &&
                    profile.supportsCard &&
                    !cluttered &&
                    budget >= 2
            val drawGateChip =
                scene.presentation.showGuidePrimitive &&
                    profile.supportsGateChip &&
                    budget >= 2 &&
                    anchors?.supportsGateChip(scene.presentation.mode) == true &&
                    anchorQuality >= NativeDriveArRenderTuning.drawGateChipThreshold &&
                    (!veryCluttered || immediate || arrival)

            return NativeDriveArRenderPolicy(
                compactLayout = compactLayout,
                drawCard = drawCard,
                drawGateChip = drawGateChip,
                drawStatusPill = drawStatusPill,
                preferAnchoredStatus = preferAnchoredStatus,
                allowAnchoredGuide = allowAnchoredGuide,
                drawRibbon = drawRibbon,
                drawTrail = drawTrail,
                drawGuideSecondary = drawGuideSecondary,
                effectiveAnchorQuality = anchorQuality.coerceIn(0f, 1f),
                effectiveRenderBudget = budget,
                anchoredAlphaMultiplier = anchoredAlphaMultiplier.coerceIn(0f, 1f),
                anchoredPlacementBlend = anchoredPlacementBlend.coerceIn(0f, 1f),
                shellAlphaMultiplier = shellAlphaMultiplier.coerceIn(0f, 1f),
                guideAlphaMultiplier = guideAlphaMultiplier.coerceIn(0f, 1f),
                trailAlphaMultiplier = trailAlphaMultiplier.coerceIn(0f, 1f),
            )
        }

        private fun buildAnchoredAlphaMultiplier(
            anchorQuality: Float,
            budget: Int,
            immediate: Boolean,
            arrival: Boolean,
        ): Float {
            if (budget <= 0) return 0f
            val normalized = ((anchorQuality - 0.18f) / 0.48f).coerceIn(0f, 1f)
            val floor = NativeDriveArRenderTuning.anchoredAlphaMultiplierFloor(immediate, arrival)
            return floor + ((1f - floor) * normalized)
        }

        private fun buildAnchoredPlacementBlend(
            anchorQuality: Float,
            budget: Int,
            immediate: Boolean,
            arrival: Boolean,
        ): Float {
            if (budget <= 0) return 0f
            val normalized = ((anchorQuality - 0.16f) / 0.52f).coerceIn(0f, 1f)
            val floor = NativeDriveArRenderTuning.anchoredPlacementBlendFloor(immediate, arrival)
            return floor + ((1f - floor) * normalized)
        }

        private fun buildShellAlphaMultiplier(
            scene: NativeDriveArScene,
            budget: Int,
            cluttered: Boolean,
            veryCluttered: Boolean,
            wideMonitor: Boolean,
            anchorQuality: Float,
            immediate: Boolean,
            arrival: Boolean,
        ): Float {
            val budgetScale = NativeDriveArRenderTuning.shellBudgetScale(budget)
            val clutterScale =
                NativeDriveArRenderTuning.shellClutterScale(
                    cluttered = cluttered,
                    veryCluttered = veryCluttered,
                    immediate = immediate,
                    arrival = arrival,
                )
            val anchorScale =
                NativeDriveArRenderTuning.shellAnchorScale(
                    wideMonitor = wideMonitor,
                    showGuidePrimitive = scene.presentation.showGuidePrimitive,
                    anchorQuality = anchorQuality,
                )
            return (
                budgetScale *
                    clutterScale *
                    anchorScale *
                    scene.presentation.shellAlphaHint.coerceIn(0f, 1f)
            ).coerceIn(0.42f, 1f)
        }
    }
}
