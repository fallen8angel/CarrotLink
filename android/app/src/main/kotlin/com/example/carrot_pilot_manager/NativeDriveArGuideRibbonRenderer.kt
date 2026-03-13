package com.example.carrot_pilot_manager

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import kotlin.math.hypot
import kotlin.math.max

internal class NativeDriveArGuideRibbonRenderer {
    private val ribbonPath = Path()
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    fun draw(
        canvas: Canvas,
        scene: NativeDriveArScene,
        anchors: NativeDriveArScene.ScreenAnchors,
        accentColor: Int,
        strokeScale: Float,
        alphaMultiplier: Float,
    ) {
        val filtered = filteredPoints(anchors, scene.presentation.distanceBucket)
        val points = filtered.first
        val distances = filtered.second
        if (points.size < 3) return

        val emphasis = scene.presentation.emphasisLevel
        val alphaScale = (scene.presentation.guideAlpha * alphaMultiplier).coerceIn(0f, 1f)
        val baseWidth = ((40f + (emphasis * 5.5f)) * strokeScale).coerceAtLeast(24f)
        val tailWidth = ((16f + (emphasis * 2.2f)) * strokeScale).coerceAtLeast(10f)
        val maxDistance = distances.lastOrNull()?.takeIf { it.isFinite() && it > 0f }

        val left = ArrayList<Pair<Float, Float>>(points.size)
        val right = ArrayList<Pair<Float, Float>>(points.size)
        for (index in points.indices) {
            val point = points[index]
            val prev = points[if (index > 0) index - 1 else index]
            val next = points[if (index < points.lastIndex) index + 1 else index]
            val tangentX = next.x - prev.x
            val tangentY = next.y - prev.y
            val length = hypot(tangentX, tangentY).coerceAtLeast(0.001f)
            val normalX = -tangentY / length
            val normalY = tangentX / length
            val distanceRatio = if (maxDistance != null && distances.size == points.size) {
                (distances[index] / maxDistance).coerceIn(0f, 1f)
            } else {
                index.toFloat() / max(1, points.lastIndex).toFloat()
            }
            val width = lerp(baseWidth, tailWidth, distanceRatio)
            val halfWidth = width * 0.5f
            left.add((point.x + (normalX * halfWidth)) to (point.y + (normalY * halfWidth)))
            right.add((point.x - (normalX * halfWidth)) to (point.y - (normalY * halfWidth)))
        }
        if (left.size < 2 || right.size < 2) return

        ribbonPath.reset()
        ribbonPath.moveTo(left.first().first, left.first().second)
        for (i in 1 until left.size) {
            ribbonPath.lineTo(left[i].first, left[i].second)
        }
        for (i in right.lastIndex downTo 0) {
            ribbonPath.lineTo(right[i].first, right[i].second)
        }
        ribbonPath.close()

        glowPaint.color = withAlpha(accentColor, (74f * alphaScale).toInt())
        fillPaint.color = withAlpha(accentColor, (148f * alphaScale).toInt())
        canvas.drawPath(ribbonPath, glowPaint)
        canvas.drawPath(ribbonPath, fillPaint)
    }

    private fun filteredPoints(
        anchors: NativeDriveArScene.ScreenAnchors,
        distanceBucket: String,
    ): Pair<List<NativeDriveArScene.ScreenPoint>, List<Float>> {
        val maxDistance = NativeDriveArGuideTuning.displayDistanceLimit(distanceBucket, detailLevel = 1)
        if (anchors.pathDistances.size != anchors.pathPoints.size) {
            return anchors.pathPoints to emptyList()
        }
        val points = ArrayList<NativeDriveArScene.ScreenPoint>(anchors.pathPoints.size)
        val distances = ArrayList<Float>(anchors.pathDistances.size)
        for (i in anchors.pathPoints.indices) {
            val distance = anchors.pathDistances[i]
            if (!distance.isFinite()) continue
            points.add(anchors.pathPoints[i])
            distances.add(distance)
            if (distance >= maxDistance) break
        }
        return if (points.size >= 3) points to distances else anchors.pathPoints to anchors.pathDistances
    }

    private fun withAlpha(color: Int, alpha: Int): Int =
        Color.argb(alpha.coerceIn(0, 255), Color.red(color), Color.green(color), Color.blue(color))

    private fun lerp(start: Float, end: Float, t: Float): Float = start + ((end - start) * t)
}
