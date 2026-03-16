package com.example.carrot_pilot_manager

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.TextPaint
import android.text.TextUtils

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
    private val fillTextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        textAlign = Paint.Align.LEFT
        typeface = Typeface.MONOSPACE
        isDither = true
    }
    private val outlineTextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
        textAlign = Paint.Align.LEFT
        typeface = Typeface.MONOSPACE
        isDither = true
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

        for (gradient in payload.gradients) {
            val rect =
                RectF(
                    gradient.left * scaleX,
                    gradient.top * scaleY,
                    gradient.right * scaleX,
                    gradient.bottom * scaleY,
                )
            if (rect.width() <= 0f || rect.height() <= 0f) continue
            fillPaint.shader =
                LinearGradient(
                    gradient.startX * scaleX,
                    gradient.startY * scaleY,
                    gradient.endX * scaleX,
                    gradient.endY * scaleY,
                    gradient.colors.map { withScaledAlpha(it, polygonAlphaMultiplier) }.toIntArray(),
                    gradient.stops,
                    Shader.TileMode.CLAMP,
                )
            canvas.drawRect(rect, fillPaint)
            fillPaint.shader = null
        }

        for (label in payload.labels) {
            val rawText = label.text.trim()
            if (rawText.isEmpty()) continue
            val labelMaxWidth = label.maxWidth?.let { (it * scaleX).coerceAtLeast(24f) }
            val shouldEllipsize =
                !label.ellipsis.isNullOrBlank() &&
                    labelMaxWidth != null &&
                    (label.maxLines ?: 1) <= 1
            val typefaceStyle = if (label.fontWeight >= 700) Typeface.BOLD else Typeface.NORMAL
            val typeface = Typeface.create(Typeface.MONOSPACE, typefaceStyle)
            fillTextPaint.typeface = typeface
            outlineTextPaint.typeface = typeface
            val requestedSize = (label.size * strokeScale).coerceIn(4.5f, 28f)
            val fittedSize =
                fitSingleLineTextSize(
                    text = rawText,
                    requestedSize = requestedSize,
                    minSize = 4.5f,
                    maxWidth = labelMaxWidth,
                    canScaleDown = !shouldEllipsize && (label.maxLines ?: 1) <= 1,
                )
            fillTextPaint.color = withScaledAlpha(label.color, labelAlphaMultiplier)
            fillTextPaint.textSize = fittedSize
            fillTextPaint.clearShadowLayer()
            outlineTextPaint.color =
                withScaledAlpha(label.strokeColor ?: Color.BLACK, labelAlphaMultiplier)
            outlineTextPaint.textSize = fittedSize
            outlineTextPaint.strokeWidth =
                ((if (label.strokeWidth > 0f) label.strokeWidth else 2.6f) * strokeScale)
                    .coerceAtLeast(1.25f)
            outlineTextPaint.clearShadowLayer()
            val displayText =
                if (shouldEllipsize) {
                    TextUtils.ellipsize(
                            rawText,
                            fillTextPaint,
                            labelMaxWidth,
                            TextUtils.TruncateAt.END,
                        )
                        .toString()
                } else {
                    rawText
                }
            val measuredWidth = fillTextPaint.measureText(displayText)
            val dx = label.x * scaleX
            val dy = label.y * scaleY
            val baseline = when (label.alignY.lowercase()) {
                "top" -> dy - fillTextPaint.fontMetrics.ascent
                "center" -> dy - ((fillTextPaint.fontMetrics.ascent + fillTextPaint.fontMetrics.descent) * 0.5f)
                "baselinebottom" -> dy
                else -> dy
            }
            val drawX = when (label.alignX.lowercase()) {
                "right" -> dx - measuredWidth
                "center" -> dx - (measuredWidth * 0.5f)
                else -> dx
            }
            if (outlineTextPaint.strokeWidth > 0f) {
                canvas.drawText(displayText, drawX, baseline, outlineTextPaint)
            }
            canvas.drawText(displayText, drawX, baseline, fillTextPaint)
        }

        return strokeScale
    }

    private fun withScaledAlpha(color: Int, alphaMultiplier: Float): Int {
        val alpha = (Color.alpha(color) * alphaMultiplier.coerceIn(0f, 1f)).toInt().coerceIn(0, 255)
        return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
    }

    private fun fitSingleLineTextSize(
        text: String,
        requestedSize: Float,
        minSize: Float,
        maxWidth: Float?,
        canScaleDown: Boolean,
    ): Float {
        if (!canScaleDown || maxWidth == null || maxWidth <= 0f) {
            return requestedSize
        }
        fillTextPaint.textSize = requestedSize
        val initialWidth = fillTextPaint.measureText(text)
        if (!initialWidth.isFinite() || initialWidth <= maxWidth || initialWidth <= 1f) {
            return requestedSize
        }
        var size = (requestedSize * ((maxWidth / initialWidth) * 0.985f)).coerceIn(minSize, requestedSize)
        fillTextPaint.textSize = size
        val secondWidth = fillTextPaint.measureText(text)
        if (secondWidth.isFinite() && secondWidth > maxWidth && size > minSize + 0.05f) {
            size = (size * ((maxWidth / secondWidth) * 0.995f)).coerceIn(minSize, requestedSize)
        }
        return size
    }
}
