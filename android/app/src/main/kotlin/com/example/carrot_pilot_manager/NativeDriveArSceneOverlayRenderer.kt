package com.example.carrot_pilot_manager

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import kotlin.math.max

internal class NativeDriveArSceneOverlayRenderer {
    private val reusableRect = RectF()
    private val guidePrimitiveRenderer = NativeDriveArGuidePrimitiveRenderer()
    private val cueGlyphRenderer = NativeDriveArCueGlyphRenderer()
    private val cardPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val accentPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
    }
    private val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        textAlign = Paint.Align.LEFT
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    }
    private val bodyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        textAlign = Paint.Align.LEFT
        typeface = Typeface.MONOSPACE
    }
    private val pillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val pillStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
    }
    private val pillTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    }

    fun draw(
        canvas: Canvas,
        scene: NativeDriveArScene?,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        scene ?: return
        guidePrimitiveRenderer.draw(canvas, scene, drawWidth, drawHeight, strokeScale, policy)
        if (policy.drawGateChip) {
            drawGateCueChip(canvas, scene, drawWidth, drawHeight, strokeScale, policy)
        }
        if (policy.drawCard) {
            drawSceneCard(canvas, scene, drawWidth, drawHeight, strokeScale, policy)
        }
        if (policy.drawStatusPill) {
            drawStatusPill(canvas, scene, drawWidth, drawHeight, strokeScale, policy)
        }
    }

    private fun drawSceneCard(
        canvas: Canvas,
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        val compactLayout = policy.compactLayout
        val shellAlpha = shellAlphaMultiplier(policy, scene)
        val accentColor = sceneAccentColor(scene)
        val showMeta = scene.presentation.showMeta && !compactLayout
        val layout = NativeDriveArShellLayout.card(scene, drawWidth, drawHeight, strokeScale, compactLayout)
        reusableRect.set(layout.left, layout.top, layout.left + layout.width, layout.top + layout.height)
        cardPaint.color = withScaledAlpha(Color.argb(172, 12, 14, 18), shellAlpha)
        borderPaint.color = withScaledAlpha(Color.argb(156, 255, 255, 255), shellAlpha)
        borderPaint.strokeWidth = (1.2f * strokeScale).coerceAtLeast(1f)
        accentPaint.color = withScaledAlpha(accentColor, shellAlpha)
        canvas.drawRoundRect(reusableRect, 16f, 16f, cardPaint)
        canvas.drawRoundRect(reusableRect, 16f, 16f, borderPaint)

        reusableRect.set(layout.left, layout.top, layout.left + layout.accentWidth, layout.top + layout.height)
        canvas.drawRoundRect(reusableRect, 16f, 16f, accentPaint)
        titlePaint.color = withScaledAlpha(Color.argb(220, 255, 255, 255), shellAlpha)
        titlePaint.textSize = layout.titleSize
        canvas.drawText("AR SCENE ${scene.cameraKind}", layout.textLeft, layout.titleY, titlePaint)
        drawCueBadge(canvas, scene, layout.left + layout.width, layout.top, strokeScale, compactLayout, shellAlpha)

        bodyPaint.color = withScaledAlpha(Color.argb(235, 255, 255, 255), shellAlpha)
        bodyPaint.textSize = layout.bodySize
        val turnLabel = scene.turnLabel().ifBlank { scene.statusLabel() }
        canvas.drawText(turnLabel.take(28), layout.textLeft, layout.bodyY, bodyPaint)

        if (showMeta) {
            bodyPaint.color = withScaledAlpha(Color.argb(194, 215, 225, 236), shellAlpha)
            bodyPaint.textSize = layout.metaSize
            val metaText =
                "route=${scene.summary.routePointCount} gap=${scene.health.frameGap ?: "-"} status=${scene.statusLabel()}"
            canvas.drawText(metaText.take(40), layout.textLeft, layout.metaY, bodyPaint)
        }
    }

    private fun drawStatusPill(
        canvas: Canvas,
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        val compactLayout = policy.compactLayout
        val shellAlpha = shellAlphaMultiplier(policy, scene)
        val text = if (compactLayout) {
            scene.statusLabel()
        } else {
            scene.turnLabel().ifBlank { scene.statusLabel() }
        }.take(28)
        if (text.isBlank()) return
        val textSize = (13f * strokeScale).coerceIn(11f, 19f)
        pillTextPaint.textSize = textSize
        val cueText = cueBadgeText(scene)
        val cueWidth = if (cueText.isBlank()) 0f else max(28f * strokeScale, (12f * strokeScale) * cueText.length)
        val textWidth = max(96f * strokeScale, pillTextPaint.measureText(text))
        val layout =
            NativeDriveArShellLayout.statusPill(
                scene = scene,
                drawWidth = drawWidth,
                drawHeight = drawHeight,
                strokeScale = strokeScale,
                policy = policy,
                textWidth = textWidth,
                cueWidth = cueWidth,
            )
        reusableRect.set(layout.left, layout.top, layout.left + layout.width, layout.top + layout.height)

        pillPaint.color = withScaledAlpha(sceneAccentColor(scene), shellAlpha)
        pillStrokePaint.color = withScaledAlpha(Color.argb(172, 255, 255, 255), shellAlpha)
        pillStrokePaint.strokeWidth = (1.2f * strokeScale).coerceAtLeast(1f)
        pillTextPaint.textSize = layout.textSize
        pillTextPaint.color = withScaledAlpha(Color.WHITE, shellAlpha)
        canvas.drawRoundRect(reusableRect, layout.radius, layout.radius, pillPaint)
        canvas.drawRoundRect(reusableRect, layout.radius, layout.radius, pillStrokePaint)
        val baseline = reusableRect.centerY() - ((pillTextPaint.descent() + pillTextPaint.ascent()) * 0.5f)
        var textStartX = reusableRect.centerX()
        if (cueText.isNotBlank()) {
            val cueRectLeft = reusableRect.left + (10f * strokeScale)
            val cueRectTop = reusableRect.top + (7f * strokeScale)
            val cueRectRight = cueRectLeft + layout.cueWidth
            val cueRectBottom = reusableRect.bottom - (7f * strokeScale)
            reusableRect.set(cueRectLeft, cueRectTop, cueRectRight, cueRectBottom)
            val cueFill = withScaledAlpha(Color.argb(86, 255, 255, 255), shellAlpha)
            pillPaint.color = cueFill
            canvas.drawRoundRect(reusableRect, 12f * strokeScale, 12f * strokeScale, pillPaint)
            val drewGlyph = cueGlyphRenderer.draw(
                canvas,
                scene.presentation.turnDirectionKey,
                RectF(reusableRect),
                withScaledAlpha(Color.WHITE, shellAlpha),
                strokeScale,
            )
            if (!drewGlyph) {
                pillTextPaint.textSize = (11f * strokeScale).coerceIn(9f, 15f)
                canvas.drawText(
                    cueText,
                    reusableRect.centerX(),
                    reusableRect.centerY() - ((pillTextPaint.descent() + pillTextPaint.ascent()) * 0.5f),
                    pillTextPaint,
                )
            }
            pillTextPaint.textSize = textSize
            textStartX = cueRectRight + (12f * strokeScale) + (textWidth * 0.5f)
        }
        canvas.drawText(text, textStartX, baseline, pillTextPaint)
    }

    private fun drawGateCueChip(
        canvas: Canvas,
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        val compactLayout = policy.compactLayout
        val shellAlpha = shellAlphaMultiplier(policy, scene)
        val text = scene.turnLabel().ifBlank {
            if (scene.turnCue?.isArrival == true) "도착 임박" else ""
        }.take(if (compactLayout) 20 else 28)
        if (text.isBlank()) return
        if (!scene.presentation.showGuidePrimitive) return
        val cueText = cueBadgeText(scene)
        val accentColor = sceneAccentColor(scene)
        val emphasized = scene.presentation.distanceBucket == "immediate"
        val anchoredBlend = policy.anchoredPlacementBlend
        val anchoredAlpha = policy.anchoredAlphaMultiplier
        val chipHeight =
            ((if (compactLayout) 34f else 38f) * strokeScale * if (emphasized) 1.08f else 1f)
                .coerceIn(30f, 52f)
        val textSize =
            ((if (compactLayout) 11.5f else 12.5f) * strokeScale * if (emphasized) 1.06f else 1f)
                .coerceIn(10f, 19f)
        pillTextPaint.textSize = textSize
        val cueWidth = if (cueText.isBlank()) 0f else (chipHeight - (10f * strokeScale)).coerceAtLeast(24f)
        val textWidth = max(92f * strokeScale, pillTextPaint.measureText(text))
        val layout =
            NativeDriveArShellLayout.gateChip(
                scene = scene,
                drawWidth = drawWidth,
                drawHeight = drawHeight,
                strokeScale = strokeScale,
                policy = policy,
                textWidth = textWidth,
                cueWidth = cueWidth,
            ) ?: return
        reusableRect.set(layout.left, layout.top, layout.left + layout.width, layout.top + layout.height)

        val anchoredShellAlpha = (shellAlpha * anchoredAlpha).coerceIn(0f, 1f)
        cardPaint.color = withScaledAlpha(Color.argb(216, 10, 12, 16), anchoredShellAlpha)
        borderPaint.color = withScaledAlpha(Color.argb(182, 255, 255, 255), anchoredShellAlpha)
        borderPaint.strokeWidth = (1.2f * strokeScale).coerceAtLeast(1f)
        accentPaint.color = withScaledAlpha(accentColor, anchoredShellAlpha)
        canvas.drawRoundRect(reusableRect, layout.radius, layout.radius, cardPaint)
        canvas.drawRoundRect(reusableRect, layout.radius, layout.radius, borderPaint)

        reusableRect.set(layout.left, layout.top, layout.left + layout.accentWidth, layout.top + layout.height)
        canvas.drawRoundRect(reusableRect, layout.radius, layout.radius, accentPaint)

        val chipBottom = layout.top + layout.height
        borderPaint.color = withScaledAlpha(
            Color.argb((128f * scene.presentation.guideAlpha).toInt().coerceIn(64, 168), 255, 255, 255),
            anchoredShellAlpha,
        )
        borderPaint.strokeWidth = (2f * strokeScale).coerceAtLeast(1.4f)
        canvas.drawLine(
            layout.drawCenterX,
            chipBottom - (2f * strokeScale),
            layout.tetherAnchorX,
            layout.tetherAnchorY,
            borderPaint,
        )

        val contentLeft = layout.left + layout.accentWidth + (12f * strokeScale)
        var textStartX = contentLeft
        if (cueWidth > 0f) {
            val cueRect = RectF(
                contentLeft,
                layout.top + (5f * strokeScale),
                contentLeft + layout.cueWidth,
                layout.top + layout.height - (5f * strokeScale),
            )
            pillPaint.color = withScaledAlpha(Color.argb(80, 255, 255, 255), anchoredShellAlpha)
            canvas.drawRoundRect(cueRect, cueRect.height() * 0.35f, cueRect.height() * 0.35f, pillPaint)
            val drewGlyph = cueGlyphRenderer.draw(
                canvas,
                scene.presentation.turnDirectionKey,
                cueRect,
                withScaledAlpha(Color.WHITE, anchoredShellAlpha),
                strokeScale * if (emphasized) 1.06f else 1f,
            )
            if (!drewGlyph) {
                pillTextPaint.textSize = (10.5f * strokeScale).coerceIn(9f, 15f)
                pillTextPaint.color = withScaledAlpha(Color.WHITE, anchoredShellAlpha)
                canvas.drawText(
                    cueText,
                    cueRect.centerX(),
                    cueRect.centerY() - ((pillTextPaint.descent() + pillTextPaint.ascent()) * 0.5f),
                    pillTextPaint,
                )
                pillTextPaint.textSize = textSize
            }
            textStartX = cueRect.right + (10f * strokeScale)
        }

        bodyPaint.color = withScaledAlpha(Color.WHITE, anchoredShellAlpha)
        bodyPaint.textSize = layout.textSize
        val textBaseline =
            (layout.top + (layout.height * 0.5f)) - ((bodyPaint.descent() + bodyPaint.ascent()) * 0.5f)
        canvas.drawText(text, textStartX, textBaseline, bodyPaint)
    }

    private fun sceneAccentColor(scene: NativeDriveArScene): Int =
        when (scene.presentation.accentKey) {
            "warning" -> Color.parseColor("#FFF3A53A")
            "arrival" -> Color.parseColor("#FF19E57A")
            "inactive" -> Color.parseColor("#A08C98A8")
            else -> Color.parseColor("#FF23D6FF")
        }

    private fun drawCueBadge(
        canvas: Canvas,
        scene: NativeDriveArScene,
        cardRight: Float,
        cardTop: Float,
        strokeScale: Float,
        compactLayout: Boolean,
        shellAlpha: Float,
    ) {
        val cueText = cueBadgeText(scene)
        if (cueText.isBlank()) return
        val emphasized = scene.presentation.distanceBucket == "immediate"
        val badgeWidth = (if (cueText.length >= 3) 34f else 28f) * strokeScale * if (emphasized) 1.12f else 1f
        val badgeHeight = 20f * strokeScale * if (emphasized) 1.08f else 1f
        val rightInset = if (compactLayout) 10f else 12f
        reusableRect.set(
            cardRight - badgeWidth - (rightInset * strokeScale),
            cardTop + (10f * strokeScale),
            cardRight - (rightInset * strokeScale),
            cardTop + (10f * strokeScale) + badgeHeight,
        )
        pillPaint.color = withScaledAlpha(Color.argb(78, 255, 255, 255), shellAlpha)
        canvas.drawRoundRect(reusableRect, 10f * strokeScale, 10f * strokeScale, pillPaint)
        val drewGlyph = cueGlyphRenderer.draw(
            canvas,
            scene.presentation.turnDirectionKey,
            RectF(reusableRect),
            withScaledAlpha(Color.WHITE, shellAlpha),
            strokeScale * if (emphasized) 1.08f else 1f,
        )
        if (!drewGlyph) {
            pillTextPaint.color = withScaledAlpha(Color.WHITE, shellAlpha)
            pillTextPaint.textSize = (10f * strokeScale).coerceIn(9f, 14f)
            val baseline = reusableRect.centerY() - ((pillTextPaint.descent() + pillTextPaint.ascent()) * 0.5f)
            canvas.drawText(cueText, reusableRect.centerX(), baseline, pillTextPaint)
        }
    }

    private fun cueBadgeText(scene: NativeDriveArScene): String =
        when (scene.presentation.turnDirectionKey.ifBlank { scene.turnCue?.directionKey.orEmpty() }) {
            "left" -> "L"
            "right" -> "R"
            "lane_left" -> "LL"
            "lane_right" -> "LR"
            "u_turn" -> "UT"
            "arrival" -> "ARR"
            else -> ""
        }

    private fun shellAlphaMultiplier(
        policy: NativeDriveArRenderPolicy,
        scene: NativeDriveArScene,
    ): Float {
        val emphasisScale =
            NativeDriveArGuideTuning.shellEmphasisScale(scene.presentation.distanceBucket)
        return (policy.shellAlphaMultiplier * emphasisScale).coerceIn(0.42f, 1f)
    }

    private fun withScaledAlpha(
        color: Int,
        scale: Float,
    ): Int {
        val alpha = (Color.alpha(color) * scale).toInt().coerceIn(0, 255)
        return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
    }
}
