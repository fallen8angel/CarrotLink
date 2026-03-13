package com.example.carrot_pilot_manager

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import kotlin.math.min

internal class NativeDriveArCueGlyphRenderer {
    private val path = Path()
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    fun draw(
        canvas: Canvas,
        directionKey: String,
        bounds: RectF,
        color: Int,
        strokeScale: Float,
    ): Boolean {
        val key = directionKey.ifBlank { return false }
        if (key == "none") return false
        val size = min(bounds.width(), bounds.height())
        val stroke = (2.1f * strokeScale).coerceAtLeast(1.5f)
        strokePaint.color = color
        strokePaint.strokeWidth = stroke
        fillPaint.color = color
        path.reset()
        return when (key) {
            "left" -> {
                buildArrow(bounds, left = true, laneChange = false)
                canvas.drawPath(path, strokePaint)
                true
            }
            "right" -> {
                buildArrow(bounds, left = false, laneChange = false)
                canvas.drawPath(path, strokePaint)
                true
            }
            "lane_left" -> {
                buildArrow(bounds, left = true, laneChange = true)
                canvas.drawPath(path, strokePaint)
                true
            }
            "lane_right" -> {
                buildArrow(bounds, left = false, laneChange = true)
                canvas.drawPath(path, strokePaint)
                true
            }
            "u_turn" -> {
                buildUTurn(bounds, stroke)
                canvas.drawPath(path, strokePaint)
                true
            }
            "arrival" -> {
                val outer = size * 0.34f
                val inner = size * 0.16f
                canvas.drawCircle(bounds.centerX(), bounds.centerY(), outer, strokePaint)
                canvas.drawCircle(bounds.centerX(), bounds.centerY(), inner, fillPaint)
                true
            }
            else -> false
        }
    }

    private fun buildArrow(bounds: RectF, left: Boolean, laneChange: Boolean) {
        val cx = bounds.centerX()
        val cy = bounds.centerY()
        val dir = if (left) -1f else 1f
        val stemTop = bounds.top + bounds.height() * 0.22f
        val stemBottom = bounds.bottom - bounds.height() * 0.18f
        val tipX = cx + dir * bounds.width() * 0.30f
        val elbowX = cx - dir * bounds.width() * if (laneChange) 0.06f else 0.02f
        val headInset = bounds.width() * 0.12f

        path.moveTo(cx, stemBottom)
        path.lineTo(cx, cy + bounds.height() * 0.08f)
        path.lineTo(elbowX, cy + bounds.height() * 0.08f)
        path.lineTo(elbowX, stemTop + bounds.height() * 0.20f)
        path.lineTo(tipX, stemTop + bounds.height() * 0.20f)
        path.moveTo(tipX, stemTop + bounds.height() * 0.20f)
        path.lineTo(tipX - dir * headInset, stemTop)
        path.moveTo(tipX, stemTop + bounds.height() * 0.20f)
        path.lineTo(tipX - dir * headInset, stemTop + bounds.height() * 0.40f)

        if (laneChange) {
            val laneX = cx - dir * bounds.width() * 0.20f
            path.moveTo(laneX, bounds.bottom - bounds.height() * 0.20f)
            path.lineTo(laneX, bounds.top + bounds.height() * 0.18f)
        }
    }

    private fun buildUTurn(bounds: RectF, stroke: Float) {
        val inset = stroke * 0.8f
        val arcRect = RectF(
            bounds.left + bounds.width() * 0.22f,
            bounds.top + inset,
            bounds.right - bounds.width() * 0.22f,
            bounds.bottom - bounds.height() * 0.24f,
        )
        path.moveTo(bounds.centerX(), bounds.bottom - bounds.height() * 0.10f)
        path.lineTo(bounds.centerX(), arcRect.centerY())
        path.addArc(arcRect, 0f, -180f)
        val tipX = arcRect.left
        val tipY = arcRect.centerY()
        val head = bounds.width() * 0.12f
        path.moveTo(tipX, tipY)
        path.lineTo(tipX + head, tipY - head)
        path.moveTo(tipX, tipY)
        path.lineTo(tipX + head, tipY + head)
    }
}
