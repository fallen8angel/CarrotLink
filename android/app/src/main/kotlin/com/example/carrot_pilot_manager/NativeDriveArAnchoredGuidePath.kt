package com.example.carrot_pilot_manager

import kotlin.math.hypot

internal data class NativeDriveArAnchoredGuidePath(
    val anchors: NativeDriveArScene.ScreenAnchors,
    val gateAnchor: NativeDriveArScene.ScreenPoint?,
) {
    companion object {
        fun build(
            scene: NativeDriveArScene,
            anchors: NativeDriveArScene.ScreenAnchors,
            drawWidth: Float,
            drawHeight: Float,
            strokeScale: Float,
            policy: NativeDriveArRenderPolicy,
        ): NativeDriveArAnchoredGuidePath {
            val blendedPoints = blendedAnchoredPathPoints(
                scene = scene,
                rawPoints = anchors.pathPoints,
                drawWidth = drawWidth,
                drawHeight = drawHeight,
                anchoredBlend = policy.anchoredPlacementBlend,
            )
            val blendedGateAnchor = blendedGateAnchor(
                scene = scene,
                rawAnchor = anchors.gateAnchor,
                drawWidth = drawWidth,
                drawHeight = drawHeight,
                anchoredBlend = policy.anchoredPlacementBlend,
            )
            val blendedAnchors = anchors.copy(
                pathPoints = blendedPoints,
                gateAnchor = blendedGateAnchor,
            )
            val trimmedAnchors = trimAnchoredPath(
                anchors = blendedAnchors,
                maxDistanceMeters = NativeDriveArGuideTuning.anchoredDisplayDistanceLimit(
                    distanceBucket = scene.presentation.distanceBucket,
                    renderBudget = policy.effectiveRenderBudget,
                    effectiveAnchorQuality = policy.effectiveAnchorQuality,
                ),
            )
            val normalizedAnchors = normalizeAnchoredPath(
                anchors = trimmedAnchors,
                maxPoints = NativeDriveArGuideTuning.anchoredMaxPointCount(
                    distanceBucket = scene.presentation.distanceBucket,
                    renderBudget = policy.effectiveRenderBudget,
                    effectiveAnchorQuality = policy.effectiveAnchorQuality,
                ),
                minSegmentSpacingPx = NativeDriveArGuideTuning.anchoredMinSegmentSpacingPx(
                    renderBudget = policy.effectiveRenderBudget,
                    effectiveAnchorQuality = policy.effectiveAnchorQuality,
                ) * strokeScale.coerceAtLeast(0.8f),
            )
            return NativeDriveArAnchoredGuidePath(
                anchors = normalizedAnchors,
                gateAnchor = blendedGateAnchor,
            )
        }

        fun preferredHeadPoint(
            scene: NativeDriveArScene,
            guidePath: NativeDriveArAnchoredGuidePath,
            anchoredBlend: Float,
        ): NativeDriveArScene.ScreenPoint {
            val lastVisiblePoint = guidePath.anchors.pathPoints.last()
            if (scene.presentation.mode == "arrival" && guidePath.gateAnchor != null) {
                return guidePath.gateAnchor
            }
            if (scene.presentation.distanceBucket == "immediate" && guidePath.gateAnchor != null) {
                return NativeDriveArGeometry.blendedPoint(
                    fallback = lastVisiblePoint,
                    anchor = guidePath.gateAnchor,
                    blend = (anchoredBlend * 0.72f).coerceIn(0f, 1f),
                )
            }
            return preferredPathEnd(guidePath.anchors, scene.presentation.distanceBucket) ?: lastVisiblePoint
        }

        private fun trimAnchoredPath(
            anchors: NativeDriveArScene.ScreenAnchors,
            maxDistanceMeters: Float,
        ): NativeDriveArScene.ScreenAnchors {
            if (anchors.pathPoints.size < 2) return anchors
            if (anchors.pathDistances.size != anchors.pathPoints.size || maxDistanceMeters <= 0f) {
                return anchors
            }
            val points = ArrayList<NativeDriveArScene.ScreenPoint>(anchors.pathPoints.size)
            val distances = ArrayList<Float>(anchors.pathDistances.size)
            for (i in anchors.pathPoints.indices) {
                val distance = anchors.pathDistances[i]
                if (!distance.isFinite()) continue
                points.add(anchors.pathPoints[i])
                distances.add(distance)
                if (distance >= maxDistanceMeters) break
            }
            if (points.size < 2) return anchors
            return anchors.copy(pathPoints = points, pathDistances = distances)
        }

        private fun normalizeAnchoredPath(
            anchors: NativeDriveArScene.ScreenAnchors,
            maxPoints: Int,
            minSegmentSpacingPx: Float,
        ): NativeDriveArScene.ScreenAnchors {
            if (anchors.pathPoints.size < 3) return anchors
            val filteredPoints = ArrayList<NativeDriveArScene.ScreenPoint>(anchors.pathPoints.size)
            val filteredDistances = ArrayList<Float>(anchors.pathDistances.size)
            filteredPoints.add(anchors.pathPoints.first())
            if (anchors.pathDistances.isNotEmpty()) {
                filteredDistances.add(anchors.pathDistances.first())
            }
            for (i in 1 until anchors.pathPoints.lastIndex) {
                val point = anchors.pathPoints[i]
                val previous = filteredPoints.last()
                val deltaPx = hypot((point.x - previous.x).toDouble(), (point.y - previous.y).toDouble()).toFloat()
                if (deltaPx < minSegmentSpacingPx) continue
                filteredPoints.add(point)
                if (anchors.pathDistances.size == anchors.pathPoints.size) {
                    filteredDistances.add(anchors.pathDistances[i])
                }
            }
            filteredPoints.add(anchors.pathPoints.last())
            if (anchors.pathDistances.size == anchors.pathPoints.size) {
                filteredDistances.add(anchors.pathDistances.last())
            }
            if (filteredPoints.size <= maxPoints || maxPoints < 3) {
                return anchors.copy(
                    pathPoints = filteredPoints,
                    pathDistances = if (filteredDistances.size == filteredPoints.size) filteredDistances else emptyList(),
                )
            }
            val sampledPoints = ArrayList<NativeDriveArScene.ScreenPoint>(maxPoints)
            val sampledDistances = ArrayList<Float>(maxPoints)
            for (index in 0 until maxPoints) {
                val t = index.toFloat() / (maxPoints - 1).toFloat()
                val sampleIndex = (t * filteredPoints.lastIndex).toInt().coerceIn(0, filteredPoints.lastIndex)
                sampledPoints.add(filteredPoints[sampleIndex])
                if (filteredDistances.size == filteredPoints.size) {
                    sampledDistances.add(filteredDistances[sampleIndex])
                }
            }
            return anchors.copy(
                pathPoints = sampledPoints,
                pathDistances = if (sampledDistances.size == sampledPoints.size) sampledDistances else emptyList(),
            )
        }

        private fun blendedAnchoredPathPoints(
            scene: NativeDriveArScene,
            rawPoints: List<NativeDriveArScene.ScreenPoint>,
            drawWidth: Float,
            drawHeight: Float,
            anchoredBlend: Float,
        ): List<NativeDriveArScene.ScreenPoint> {
            if (rawPoints.size < 2 || anchoredBlend >= 0.995f) return rawPoints
            val fallbackPoints = buildFallbackPathPoints(scene, drawWidth, drawHeight, rawPoints.size)
            if (fallbackPoints.size != rawPoints.size) return rawPoints
            return List(rawPoints.size) { index ->
                NativeDriveArGeometry.blendedPoint(
                    fallback = fallbackPoints[index],
                    anchor = rawPoints[index],
                    blend = anchoredBlend,
                )
            }
        }

        private fun blendedGateAnchor(
            scene: NativeDriveArScene,
            rawAnchor: NativeDriveArScene.ScreenPoint?,
            drawWidth: Float,
            drawHeight: Float,
            anchoredBlend: Float,
        ): NativeDriveArScene.ScreenPoint? {
            rawAnchor ?: return null
            if (anchoredBlend >= 0.995f) return rawAnchor
            val fallback = NativeDriveArGeometry.fallbackGuideHeadPoint(scene, drawWidth, drawHeight)
            return NativeDriveArGeometry.blendedPoint(fallback = fallback, anchor = rawAnchor, blend = anchoredBlend)
        }

        private fun buildFallbackPathPoints(
            scene: NativeDriveArScene,
            drawWidth: Float,
            drawHeight: Float,
            count: Int,
        ): List<NativeDriveArScene.ScreenPoint> {
            if (count <= 1) {
                return listOf(NativeDriveArGeometry.fallbackGuideHeadPoint(scene, drawWidth, drawHeight))
            }
            val mode = scene.presentation.mode
            val direction = scene.presentation.turnDirectionKey.ifBlank {
                scene.turnCue?.directionKey.orEmpty()
            }
            val startX = drawWidth * 0.50f
            val startY = drawHeight * if (scene.presentation.compactPreferred) 0.78f else 0.80f
            if (mode == "arrival") {
                val end = NativeDriveArGeometry.fallbackGuideHeadPoint(scene, drawWidth, drawHeight)
                return List(count) { index ->
                    val t = if (count <= 1) 1f else index.toFloat() / (count - 1).toFloat()
                    NativeDriveArScene.ScreenPoint(
                        x = lerp(startX, end.x, t),
                        y = lerp(startY, end.y, t),
                    )
                }
            }
            if (direction.isBlank() || direction == "none") {
                return NativeDriveArGeometry.sampleQuadraticPath(
                    startX = drawWidth * 0.42f,
                    startY = drawHeight * 0.74f,
                    ctrlX = drawWidth * 0.50f,
                    ctrlY = drawHeight * 0.66f,
                    endX = drawWidth * 0.58f,
                    endY = drawHeight * if (scene.presentation.compactPreferred) 0.56f else 0.52f,
                    count = count,
                )
            }
            val dirSign = when (direction) {
                "left", "lane_left", "u_turn" -> -1f
                "right", "lane_right" -> 1f
                else -> 0f
            }
            if (dirSign == 0f) {
                return NativeDriveArGeometry.sampleQuadraticPath(
                    startX = drawWidth * 0.42f,
                    startY = drawHeight * 0.74f,
                    ctrlX = drawWidth * 0.50f,
                    ctrlY = drawHeight * 0.66f,
                    endX = drawWidth * 0.58f,
                    endY = drawHeight * if (scene.presentation.compactPreferred) 0.56f else 0.52f,
                    count = count,
                )
            }
            val immediate = scene.presentation.distanceBucket == "immediate"
            val near = scene.presentation.distanceBucket == "near"
            val lateral = NativeDriveArGeometry.routeTurnLateral(direction, immediate, near)
            val heightFactor = NativeDriveArGeometry.routeTurnHeightFactor(immediate, near)
            return NativeDriveArGeometry.sampleQuadraticPath(
                startX = startX,
                startY = startY,
                ctrlX = drawWidth * (0.50f + (dirSign * NativeDriveArGeometry.routeTurnCtrlOffset(lateral))),
                ctrlY = drawHeight * (if (immediate) 0.64f else 0.67f),
                endX = drawWidth * (0.50f + (dirSign * lateral)),
                endY = drawHeight * heightFactor,
                count = count,
            )
        }

        private fun preferredPathEnd(
            anchors: NativeDriveArScene.ScreenAnchors,
            distanceBucket: String,
        ): NativeDriveArScene.ScreenPoint? {
            if (anchors.pathPoints.size < 2) return null
            if (anchors.pathDistances.size != anchors.pathPoints.size) return null
            val targetDistance = NativeDriveArGuideTuning.preferredPathTargetDistance(distanceBucket)
            for (i in anchors.pathDistances.indices) {
                if (anchors.pathDistances[i] >= targetDistance) {
                    return anchors.pathPoints[i]
                }
            }
            return anchors.pathPoints.last()
        }

        private fun lerp(start: Float, end: Float, t: Float): Float =
            start + ((end - start) * t.coerceIn(0f, 1f))
    }
}
