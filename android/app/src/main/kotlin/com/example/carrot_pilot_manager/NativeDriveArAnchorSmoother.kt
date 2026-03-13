package com.example.carrot_pilot_manager

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

internal class NativeDriveArAnchorSmoother {
    private var initialized = false
    private var lastCameraKind = ""
    private var lastLayoutProfile = ""
    private var smoothedPathPoints: List<NativeDriveArScene.ScreenPoint> = emptyList()
    private var smoothedGateAnchor: NativeDriveArScene.ScreenPoint? = null
    private var smoothedStatusAnchor: NativeDriveArScene.ScreenPoint? = null
    private var lastStabilityScore = 0f
    private var lastDebug: Map<String, Any?> = mapOf("enabled" to false)

    fun reset() {
        initialized = false
        lastCameraKind = ""
        lastLayoutProfile = ""
        smoothedPathPoints = emptyList()
        smoothedGateAnchor = null
        smoothedStatusAnchor = null
        lastStabilityScore = 0f
        lastDebug = mapOf("enabled" to false)
    }

    fun update(scene: NativeDriveArScene?): NativeDriveArScene? {
        if (scene == null) {
            reset()
            return null
        }
        val anchors = scene.screenAnchors ?: run {
            smoothedPathPoints = emptyList()
            smoothedGateAnchor = null
            smoothedStatusAnchor = null
            lastStabilityScore = 0f
            lastDebug =
                mapOf(
                    "enabled" to false,
                    "reason" to "no_anchors",
                    "stabilityScore" to lastStabilityScore,
                )
            return scene
        }
        val resetRequired =
            !initialized ||
                lastCameraKind != scene.cameraKind ||
                lastLayoutProfile != scene.presentation.layoutProfile ||
                anchors.pathPoints.size < 2 ||
                smoothedPathPoints.isEmpty() ||
                abs(smoothedPathPoints.size - anchors.pathPoints.size) >=
                    NativeDriveArRenderTuning.anchorResetPathCountDeltaThreshold
        if (resetRequired) {
            initialized = true
            lastCameraKind = scene.cameraKind
            lastLayoutProfile = scene.presentation.layoutProfile
            smoothedPathPoints = anchors.pathPoints
            smoothedGateAnchor = anchors.gateAnchor
            smoothedStatusAnchor = anchors.statusAnchor
        } else {
            smoothedPathPoints = smoothPath(scene, anchors.pathPoints)
            smoothedGateAnchor =
                smoothPoint(
                    current = smoothedGateAnchor,
                    target = anchors.gateAnchor,
                    alpha = pointAlpha(scene, kind = "gate"),
                    snapDistancePx = NativeDriveArRenderTuning.gateSnapDistancePx,
                )
            smoothedStatusAnchor =
                smoothPoint(
                    current = smoothedStatusAnchor,
                    target = anchors.statusAnchor,
                    alpha = pointAlpha(scene, kind = "status"),
                    snapDistancePx = NativeDriveArRenderTuning.statusSnapDistancePx,
                )
        }

        val smoothedAnchors =
            anchors.copy(
                pathPoints = smoothedPathPoints,
                gateAnchor = smoothedGateAnchor,
                statusAnchor = smoothedStatusAnchor,
            )
        val gateDelta = deltaPx(anchors.gateAnchor, smoothedGateAnchor)
        val statusDelta = deltaPx(anchors.statusAnchor, smoothedStatusAnchor)
        val pathMeanDelta = pathMeanDeltaPx(anchors.pathPoints, smoothedPathPoints)
        lastStabilityScore = computeStabilityScore(gateDelta, statusDelta, pathMeanDelta)
        lastDebug =
            mapOf(
                "enabled" to true,
                "cameraKind" to scene.cameraKind,
                "layoutProfile" to scene.presentation.layoutProfile,
                "rawPathPoints" to anchors.pathPoints.size,
                "smoothedPathPoints" to smoothedPathPoints.size,
                "gateDeltaPx" to gateDelta,
                "statusDeltaPx" to statusDelta,
                "pathMeanDeltaPx" to pathMeanDelta,
                "stabilityScore" to lastStabilityScore,
            )
        return scene.copy(screenAnchors = smoothedAnchors)
    }

    fun buildDebugMap(): Map<String, Any?> = lastDebug

    fun currentStabilityScore(): Float = lastStabilityScore

    private fun smoothPath(
        scene: NativeDriveArScene,
        rawPoints: List<NativeDriveArScene.ScreenPoint>,
    ): List<NativeDriveArScene.ScreenPoint> {
        if (rawPoints.size < 2) return rawPoints
        val previous = resample(smoothedPathPoints, rawPoints.size)
        if (previous.size != rawPoints.size) return rawPoints
        val baseAlpha = NativeDriveArRenderTuning.pathBaseAlpha(scene.presentation.distanceBucket)
        val out = ArrayList<NativeDriveArScene.ScreenPoint>(rawPoints.size)
        for (i in rawPoints.indices) {
            val raw = rawPoints[i]
            val prev = previous[i]
            val jump = hypot((raw.x - prev.x).toDouble(), (raw.y - prev.y).toDouble()).toFloat()
            if (jump >= NativeDriveArRenderTuning.pathJumpSnapDistancePx) {
                out.add(raw)
                continue
            }
            val pointAlpha =
                when {
                    i == 0 -> (baseAlpha + 0.10f).coerceAtMost(0.55f)
                    i == rawPoints.lastIndex -> (baseAlpha + 0.06f).coerceAtMost(0.50f)
                    else -> baseAlpha
                }
            out.add(
                NativeDriveArScene.ScreenPoint(
                    x = lerp(prev.x, raw.x, pointAlpha),
                    y = lerp(prev.y, raw.y, pointAlpha),
                ),
            )
        }
        return out
    }

    private fun smoothPoint(
        current: NativeDriveArScene.ScreenPoint?,
        target: NativeDriveArScene.ScreenPoint?,
        alpha: Float,
        snapDistancePx: Float,
    ): NativeDriveArScene.ScreenPoint? {
        target ?: return null
        current ?: return target
        val jump = hypot((target.x - current.x).toDouble(), (target.y - current.y).toDouble()).toFloat()
        if (jump >= snapDistancePx) return target
        return NativeDriveArScene.ScreenPoint(
            x = lerp(current.x, target.x, alpha),
            y = lerp(current.y, target.y, alpha),
        )
    }

    private fun pointAlpha(
        scene: NativeDriveArScene,
        kind: String,
    ): Float {
        val base = NativeDriveArRenderTuning.pointBaseAlpha(scene.presentation.distanceBucket)
        return when (kind) {
            "status" -> (base - 0.08f).coerceAtLeast(0.18f)
            else -> base
        }
    }

    private fun resample(
        points: List<NativeDriveArScene.ScreenPoint>,
        targetCount: Int,
    ): List<NativeDriveArScene.ScreenPoint> {
        if (points.isEmpty() || targetCount <= 0) return emptyList()
        if (points.size == targetCount) return points
        if (targetCount == 1) return listOf(points.first())
        val out = ArrayList<NativeDriveArScene.ScreenPoint>(targetCount)
        val maxIndex = points.lastIndex.toFloat()
        for (i in 0 until targetCount) {
            val t = i.toFloat() / (targetCount - 1).toFloat()
            val position = t * maxIndex
            val leftIndex = position.toInt().coerceIn(0, points.lastIndex)
            val rightIndex = (leftIndex + 1).coerceAtMost(points.lastIndex)
            val localT = (position - leftIndex).coerceIn(0f, 1f)
            val a = points[leftIndex]
            val b = points[rightIndex]
            out.add(
                NativeDriveArScene.ScreenPoint(
                    x = lerp(a.x, b.x, localT),
                    y = lerp(a.y, b.y, localT),
                ),
            )
        }
        return out
    }

    private fun deltaPx(
        raw: NativeDriveArScene.ScreenPoint?,
        smoothed: NativeDriveArScene.ScreenPoint?,
    ): Float? {
        if (raw == null || smoothed == null) return null
        return hypot((raw.x - smoothed.x).toDouble(), (raw.y - smoothed.y).toDouble()).toFloat()
    }

    private fun pathMeanDeltaPx(
        rawPoints: List<NativeDriveArScene.ScreenPoint>,
        smoothedPoints: List<NativeDriveArScene.ScreenPoint>,
    ): Float? {
        if (rawPoints.isEmpty() || smoothedPoints.isEmpty() || rawPoints.size != smoothedPoints.size) {
            return null
        }
        var total = 0f
        var count = 0
        for (i in rawPoints.indices) {
            total += deltaPx(rawPoints[i], smoothedPoints[i])
            count += 1
        }
        if (count <= 0) return null
        return total / count.toFloat()
    }

    private fun deltaPx(
        raw: NativeDriveArScene.ScreenPoint,
        smoothed: NativeDriveArScene.ScreenPoint,
    ): Float = hypot((raw.x - smoothed.x).toDouble(), (raw.y - smoothed.y).toDouble()).toFloat()

    private fun computeStabilityScore(
        gateDelta: Float?,
        statusDelta: Float?,
        pathMeanDelta: Float?,
    ): Float {
        val gatePenalty =
            normalizedPenalty(
                gateDelta,
                startPx = NativeDriveArRenderTuning.stabilityPenaltyStart("gate"),
                fullPx = NativeDriveArRenderTuning.stabilityPenaltyFull("gate"),
            )
        val statusPenalty =
            normalizedPenalty(
                statusDelta,
                startPx = NativeDriveArRenderTuning.stabilityPenaltyStart("status"),
                fullPx = NativeDriveArRenderTuning.stabilityPenaltyFull("status"),
            )
        val pathPenalty =
            normalizedPenalty(
                pathMeanDelta,
                startPx = NativeDriveArRenderTuning.stabilityPenaltyStart("path"),
                fullPx = NativeDriveArRenderTuning.stabilityPenaltyFull("path"),
            )
        val weightedPenalty = (gatePenalty * 0.42f) + (statusPenalty * 0.20f) + (pathPenalty * 0.38f)
        return (1f - weightedPenalty.coerceIn(0f, 1f)).coerceIn(0f, 1f)
    }

    private fun normalizedPenalty(
        delta: Float?,
        startPx: Float,
        fullPx: Float,
    ): Float {
        delta ?: return 0f
        val span = max(1f, fullPx - startPx)
        return ((delta - startPx) / span).coerceIn(0f, 1f)
    }

    private fun lerp(
        start: Float,
        end: Float,
        t: Float,
    ): Float = start + ((end - start) * t.coerceIn(0f, 1f))
}
