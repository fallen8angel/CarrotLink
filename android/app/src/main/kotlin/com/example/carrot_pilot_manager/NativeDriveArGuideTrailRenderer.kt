package com.example.carrot_pilot_manager

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

internal class NativeDriveArGuideTrailRenderer {
    private data class TrailPath(
        val points: List<NativeDriveArScene.ScreenPoint>,
        val distances: List<Float>,
        val maxDisplayDistance: Float,
    )

    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val corePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val chevronStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val chevronInnerStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    fun drawQuadraticTrail(
        canvas: Canvas,
        startX: Float,
        startY: Float,
        ctrlX: Float,
        ctrlY: Float,
        endX: Float,
        endY: Float,
        accentColor: Int,
        strokeScale: Float,
        detailLevel: Int,
        distanceBucket: String,
        directionKey: String,
        alphaScale: Float,
        emphasisLevel: Int,
    ) {
        if (alphaScale <= 0f) return
        val count = when (distanceBucket) {
            "immediate" -> if (detailLevel >= 2) 4 + emphasisLevel.coerceAtMost(1) else 3
            "near" -> if (detailLevel >= 2) 5 else 4
            "far" -> if (detailLevel >= 3) 6 else 5
            else -> if (detailLevel >= 2) 4 else 3
        }
        if (count <= 0) return

        val drawChevron = directionKey in setOf("left", "right", "lane_left", "lane_right")
        for (index in 1..count) {
            val t = index.toFloat() / (count + 1).toFloat()
            val point = quadPoint(startX, startY, ctrlX, ctrlY, endX, endY, t)
            val tangent = quadTangent(startX, startY, ctrlX, ctrlY, endX, endY, t)
            val intensity = when {
                distanceBucket == "immediate" -> 1.15f
                distanceBucket == "near" -> 1.0f
                else -> 0.9f
            }
            val fade = 1f - (t * 0.35f)
            if (drawChevron) {
                drawChevron(
                    canvas = canvas,
                    centerX = point.first,
                    centerY = point.second,
                    angle = atan2(tangent.second, tangent.first),
                    size = (6.5f + (detailLevel * 0.9f) + (emphasisLevel * 0.45f)) *
                        strokeScale * intensity * fade,
                    accentColor = accentColor,
                    alphaScale = alphaScale * fade,
                )
            } else {
                drawDot(
                    canvas = canvas,
                    centerX = point.first,
                    centerY = point.second,
                    radius = (4.4f + (detailLevel * 0.4f) + (emphasisLevel * 0.25f)) *
                        strokeScale * intensity * fade,
                    accentColor = accentColor,
                    alphaScale = alphaScale * fade,
                )
            }
        }
    }

    fun drawPathPointTrail(
        canvas: Canvas,
        pathPoints: List<NativeDriveArScene.ScreenPoint>,
        pathDistances: List<Float>,
        accentColor: Int,
        strokeScale: Float,
        detailLevel: Int,
        distanceBucket: String,
        directionKey: String,
        alphaScale: Float,
        emphasisLevel: Int,
    ) {
        if (alphaScale <= 0f || pathPoints.size < 2) return
        val trailPath = buildTrailPath(
            pathPoints = pathPoints,
            pathDistances = pathDistances,
            distanceBucket = distanceBucket,
            detailLevel = detailLevel,
        )
        val sampledPoints = trailPath.points
        val sampledDistances = trailPath.distances
        if (sampledPoints.size < 2) return
        val count = when (distanceBucket) {
            "immediate" -> if (detailLevel >= 2) 3 + emphasisLevel.coerceAtMost(1) else 2
            "near" -> if (detailLevel >= 2) 4 else 3
            "far" -> if (detailLevel >= 3) 5 else 4
            else -> if (detailLevel >= 2) 4 else 3
        }
        if (count <= 0) return

        val drawChevron = directionKey in setOf("left", "right", "lane_left", "lane_right")
        val lastIndex = sampledPoints.size - 1
        for (index in 1..count) {
            val t = index.toFloat() / (count + 1).toFloat()
            val position = t * lastIndex
            val baseIndex = position.toInt().coerceIn(0, lastIndex - 1)
            val nextIndex = (baseIndex + 1).coerceAtMost(lastIndex)
            val localT = (position - baseIndex).coerceIn(0f, 1f)
            val a = sampledPoints[baseIndex]
            val b = sampledPoints[nextIndex]
            val x = lerp(a.x, b.x, localT)
            val y = lerp(a.y, b.y, localT)
            val angle = atan2(b.y - a.y, b.x - a.x)
            val distanceAtPoint = if (sampledDistances.size == sampledPoints.size) {
                lerp(sampledDistances[baseIndex], sampledDistances[nextIndex], localT)
            } else {
                null
            }
            val intensity = when {
                distanceBucket == "immediate" -> 1.18f
                distanceBucket == "near" -> 1.0f
                else -> 0.88f
            }
            val distanceFade = if (distanceAtPoint != null && trailPath.maxDisplayDistance > 0f) {
                val normalized = (distanceAtPoint / trailPath.maxDisplayDistance).coerceIn(0f, 1f)
                1f - (normalized * 0.45f)
            } else {
                1f
            }
            val fade = (1f - (t * 0.30f)) * distanceFade
            if (drawChevron) {
                drawChevron(
                    canvas = canvas,
                    centerX = x,
                    centerY = y,
                    angle = angle,
                    size = (6.2f + (detailLevel * 0.8f) + (emphasisLevel * 0.45f)) *
                        strokeScale * intensity * fade,
                    accentColor = accentColor,
                    alphaScale = alphaScale * fade,
                )
            } else {
                drawDot(
                    canvas = canvas,
                    centerX = x,
                    centerY = y,
                    radius = (4.0f + (detailLevel * 0.35f) + (emphasisLevel * 0.22f)) *
                        strokeScale * intensity * fade,
                    accentColor = accentColor,
                    alphaScale = alphaScale * fade,
                )
            }
        }
    }

    private fun buildTrailPath(
        pathPoints: List<NativeDriveArScene.ScreenPoint>,
        pathDistances: List<Float>,
        distanceBucket: String,
        detailLevel: Int,
    ): TrailPath {
        val maxDisplayDistance = displayDistanceLimit(distanceBucket, detailLevel)
        if (pathDistances.size != pathPoints.size || maxDisplayDistance <= 0f) {
            return TrailPath(pathPoints, emptyList(), maxDisplayDistance)
        }

        val filteredPoints = ArrayList<NativeDriveArScene.ScreenPoint>(pathPoints.size)
        val filteredDistances = ArrayList<Float>(pathDistances.size)
        for (i in pathPoints.indices) {
            val distance = pathDistances[i]
            if (!distance.isFinite()) continue
            filteredPoints.add(pathPoints[i])
            filteredDistances.add(distance)
            if (distance >= maxDisplayDistance) {
                break
            }
        }
        if (filteredPoints.size < 2) {
            return TrailPath(pathPoints, pathDistances, maxDisplayDistance)
        }
        return TrailPath(filteredPoints, filteredDistances, maxDisplayDistance)
    }

    private fun displayDistanceLimit(
        distanceBucket: String,
        detailLevel: Int,
    ): Float = NativeDriveArGuideTuning.displayDistanceLimit(distanceBucket, detailLevel)

    private fun drawDot(
        canvas: Canvas,
        centerX: Float,
        centerY: Float,
        radius: Float,
        accentColor: Int,
        alphaScale: Float,
    ) {
        glowPaint.color = withAlpha(accentColor, (68f * alphaScale).toInt())
        corePaint.color = withAlpha(Color.WHITE, (208f * alphaScale).toInt())
        canvas.drawCircle(centerX, centerY, radius * 1.8f, glowPaint)
        glowPaint.color = withAlpha(accentColor, (190f * alphaScale).toInt())
        canvas.drawCircle(centerX, centerY, radius, glowPaint)
        canvas.drawCircle(centerX, centerY, radius * 0.38f, corePaint)
    }

    private fun drawChevron(
        canvas: Canvas,
        centerX: Float,
        centerY: Float,
        angle: Float,
        size: Float,
        accentColor: Int,
        alphaScale: Float,
    ) {
        val forwardX = cos(angle)
        val forwardY = sin(angle)
        val sideX = -forwardY
        val sideY = forwardX
        val tipX = centerX + (forwardX * size)
        val tipY = centerY + (forwardY * size)
        val leftX = centerX - (forwardX * size * 0.45f) + (sideX * size * 0.75f)
        val leftY = centerY - (forwardY * size * 0.45f) + (sideY * size * 0.75f)
        val rightX = centerX - (forwardX * size * 0.45f) - (sideX * size * 0.75f)
        val rightY = centerY - (forwardY * size * 0.45f) - (sideY * size * 0.75f)

        glowPaint.color = withAlpha(accentColor, (74f * alphaScale).toInt())
        corePaint.color = withAlpha(Color.WHITE, (220f * alphaScale).toInt())
        canvas.drawCircle(centerX, centerY, max(2.4f, size * 0.82f), glowPaint)

        chevronStrokePaint.strokeWidth = max(1.4f, size * 0.22f)
        chevronStrokePaint.color = withAlpha(accentColor, (228f * alphaScale).toInt())
        canvas.drawLine(leftX, leftY, tipX, tipY, chevronStrokePaint)
        canvas.drawLine(tipX, tipY, rightX, rightY, chevronStrokePaint)

        chevronInnerStrokePaint.strokeWidth = max(1f, size * 0.10f)
        chevronInnerStrokePaint.color = corePaint.color
        canvas.drawLine(leftX, leftY, tipX, tipY, chevronInnerStrokePaint)
        canvas.drawLine(tipX, tipY, rightX, rightY, chevronInnerStrokePaint)
    }

    private fun quadPoint(
        startX: Float,
        startY: Float,
        ctrlX: Float,
        ctrlY: Float,
        endX: Float,
        endY: Float,
        t: Float,
    ): Pair<Float, Float> {
        val oneMinusT = 1f - t
        val x =
            (oneMinusT * oneMinusT * startX) +
                (2f * oneMinusT * t * ctrlX) +
                (t * t * endX)
        val y =
            (oneMinusT * oneMinusT * startY) +
                (2f * oneMinusT * t * ctrlY) +
                (t * t * endY)
        return x to y
    }

    private fun quadTangent(
        startX: Float,
        startY: Float,
        ctrlX: Float,
        ctrlY: Float,
        endX: Float,
        endY: Float,
        t: Float,
    ): Pair<Float, Float> {
        val dx = (2f * (1f - t) * (ctrlX - startX)) + (2f * t * (endX - ctrlX))
        val dy = (2f * (1f - t) * (ctrlY - startY)) + (2f * t * (endY - ctrlY))
        return dx to dy
    }

    private fun withAlpha(color: Int, alpha: Int): Int =
        Color.argb(alpha.coerceIn(0, 255), Color.red(color), Color.green(color), Color.blue(color))

    private fun lerp(a: Float, b: Float, t: Float): Float = a + ((b - a) * t)
}
