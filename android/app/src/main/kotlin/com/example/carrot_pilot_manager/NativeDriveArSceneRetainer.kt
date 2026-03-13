package com.example.carrot_pilot_manager

internal class NativeDriveArSceneRetainer {
    private var lastStableScene: NativeDriveArScene? = null
    private var holdFramesRemaining = 0
    private var holdFramesTotal = 0
    private var retainActive = false
    private var lastReason = "idle"
    private var lastRetainedFraction = 0f

    fun update(raw: NativeDriveArScene?): NativeDriveArScene? {
        if (raw == null) {
            return retainIfPossible(reason = "null_scene")
        }
        if (!raw.health.calibrationOk) {
            holdFramesRemaining = 0
            holdFramesTotal = 0
            retainActive = false
            lastReason = "calibration_bad"
            lastRetainedFraction = 0f
            return raw
        }
        if (!raw.health.frameGapOk) {
            holdFramesRemaining = 0
            holdFramesTotal = 0
            retainActive = false
            lastReason = "frame_gap_bad"
            lastRetainedFraction = 0f
            return raw
        }
        if (raw.isEmpty) {
            return retainIfPossible(reason = "empty_scene") ?: raw
        }

        lastStableScene = raw
        holdFramesTotal = NativeDriveArRenderTuning.retentionHoldBudget(raw)
        holdFramesRemaining = holdFramesTotal
        retainActive = false
        lastReason = "fresh"
        lastRetainedFraction = 1f
        return raw
    }

    fun reset() {
        lastStableScene = null
        holdFramesRemaining = 0
        holdFramesTotal = 0
        retainActive = false
        lastReason = "reset"
        lastRetainedFraction = 0f
    }

    fun buildDebugMap(): Map<String, Any?> =
        mapOf(
            "retainActive" to retainActive,
            "holdFramesRemaining" to holdFramesRemaining,
            "holdFramesTotal" to holdFramesTotal,
            "retainedFraction" to lastRetainedFraction,
            "hasStableScene" to (lastStableScene != null),
            "lastReason" to lastReason,
            "stableMode" to lastStableScene?.presentation?.mode,
            "stableProfile" to lastStableScene?.presentation?.layoutProfile,
        )

    private fun retainIfPossible(reason: String): NativeDriveArScene? {
        val stable = lastStableScene
        if (stable == null || holdFramesRemaining <= 0) {
            retainActive = false
            lastReason = "$reason:none"
            lastRetainedFraction = 0f
            return null
        }
        val fraction = if (holdFramesTotal > 0) {
            (holdFramesRemaining.toFloat() / holdFramesTotal.toFloat()).coerceIn(0f, 1f)
        } else {
            0f
        }
        holdFramesRemaining = (holdFramesRemaining - 1).coerceAtLeast(0)
        retainActive = true
        lastReason = reason
        lastRetainedFraction = fraction
        return buildRetainedScene(stable, fraction)
    }

    private fun buildRetainedScene(
        scene: NativeDriveArScene,
        retainedFraction: Float,
    ): NativeDriveArScene {
        val retainedPhase =
            when {
                retainedFraction >= 0.66f -> "strong"
                retainedFraction >= 0.33f -> "mid"
                else -> "tail"
            }
        val retainedStatus =
            when {
                scene.turnCue?.isArrival == true -> "도착 안내 유지"
                scene.turnCue != null && retainedPhase == "tail" -> "안내 유지 중"
                scene.turnCue != null -> "안내 유지"
                scene.hasRoute && retainedPhase == "tail" -> "경로 유지 중"
                scene.hasRoute -> "경로 유지"
                else -> "안내 유지"
            }
        val renderBudget =
            NativeDriveArRenderTuning.retainedRenderBudget(scene.presentation.renderBudget, retainedFraction)
        val guideScale = NativeDriveArRenderTuning.retainedGuideScale(retainedFraction)
        val trailScale = NativeDriveArRenderTuning.retainedTrailScale(retainedFraction)
        val shellScale = NativeDriveArRenderTuning.retainedShellScale(retainedFraction)
        val retainedPresentation =
            scene.presentation.copy(
                renderBudget = renderBudget,
                shellAlphaHint = (scene.presentation.shellAlphaHint * shellScale).coerceIn(0f, 1f),
                guideAlpha = (scene.presentation.guideAlpha * guideScale).coerceIn(0f, 1f),
                trailAlpha = (scene.presentation.trailAlpha * trailScale).coerceIn(0f, 1f),
                showMeta = false,
                showCard = false,
                showStatusPill = true,
            )
        return scene.copy(
            presentation = retainedPresentation,
            summary = scene.summary.copy(statusText = retainedStatus),
        )
    }
}
