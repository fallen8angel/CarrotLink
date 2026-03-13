package com.example.carrot_pilot_manager

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface

internal class NativeDriveOverlayCanvasRenderer {
    private val reusablePath = Path()
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        isDither = true
    }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
        isDither = true
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        textAlign = Paint.Align.LEFT
        typeface = Typeface.MONOSPACE
    }

    fun draw(
        canvas: Canvas,
        payload: NativeDriveOverlayPayload?,
        drawWidth: Float,
        drawHeight: Float,
        polygonAlphaMultiplier: Float = 1f,
        strokeAlphaMultiplier: Float = 1f,
        labelAlphaMultiplier: Float = 1f,
    ): Float {
        if (payload == null || payload.isEmpty) return 1f
        val srcWidth = if (payload.canvasWidth > 1f) payload.canvasWidth else drawWidth
        val srcHeight = if (payload.canvasHeight > 1f) payload.canvasHeight else drawHeight
        val scaleX = if (srcWidth > 1f) drawWidth / srcWidth else 1f
        val scaleY = if (srcHeight > 1f) drawHeight / srcHeight else 1f
        val strokeScale = ((scaleX + scaleY) * 0.5f).coerceAtLeast(0.5f)

        for (polygon in payload.polygons) {
            if (polygon.points.size < 6) continue
            reusablePath.reset()
            reusablePath.moveTo(polygon.points[0] * scaleX, polygon.points[1] * scaleY)
            var i = 2
            while (i + 1 < polygon.points.size) {
                reusablePath.lineTo(polygon.points[i] * scaleX, polygon.points[i + 1] * scaleY)
                i += 2
            }
            reusablePath.close()
            fillPaint.color = withScaledAlpha(polygon.fillColor, polygonAlphaMultiplier)
            canvas.drawPath(reusablePath, fillPaint)
            if (polygon.strokeColor != null && polygon.strokeWidth > 0f) {
                strokePaint.color = withScaledAlpha(polygon.strokeColor, strokeAlphaMultiplier)
                strokePaint.strokeWidth = (polygon.strokeWidth * strokeScale).coerceAtLeast(1f)
                canvas.drawPath(reusablePath, strokePaint)
            }
        }

        for (label in payload.labels) {
            textPaint.color = withScaledAlpha(label.color, labelAlphaMultiplier)
            textPaint.textSize = (label.size * strokeScale).coerceIn(8f, 28f)
            textPaint.setShadowLayer(3f, 0f, 0f, Color.BLACK)
            canvas.drawText(label.text, label.x * scaleX, label.y * scaleY, textPaint)
        }

        return strokeScale
    }

    private fun withScaledAlpha(color: Int, alphaMultiplier: Float): Int {
        val alpha = (Color.alpha(color) * alphaMultiplier.coerceIn(0f, 1f)).toInt().coerceIn(0, 255)
        return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
    }
}
