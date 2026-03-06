package com.example.carrot_pilot_manager

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import kotlin.math.max

internal class NativeDriveArGuidePrimitiveRenderer {
    private val guidePath = Path()
    private val trailRenderer = NativeDriveArGuideTrailRenderer()
    private val ribbonRenderer = NativeDriveArGuideRibbonRenderer()
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val corePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
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
        if (!scene.presentation.showGuidePrimitive) return
        if (policy.effectiveRenderBudget <= 0) return
        val mode = scene.presentation.mode.ifBlank { return }
        val anchors = scene.screenAnchors
        if (policy.allowAnchoredGuide && anchors != null) {
            drawAnchoredGuide(canvas, scene, anchors, drawWidth, drawHeight, strokeScale, policy)
            return
        }
        if (mode == "idle" || mode == "caution") return
        if (mode == "arrival") {
            drawArrivalHalo(canvas, scene, drawWidth, drawHeight, strokeScale, policy)
            return
        }
        val direction = scene.presentation.turnDirectionKey.ifBlank {
            scene.turnCue?.directionKey.orEmpty()
        }
        if (direction.isBlank() || direction == "none") {
            drawRouteGuide(canvas, scene, drawWidth, drawHeight, strokeScale, policy)
            return
        }
        drawTurnGuide(canvas, scene, direction, drawWidth, drawHeight, strokeScale, policy)
    }

    private fun drawAnchoredGuide(
        canvas: Canvas,
        scene: NativeDriveArScene,
        anchors: NativeDriveArScene.ScreenAnchors,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        val rawPoints = anchors.pathPoints
        if (rawPoints.size < 2) return
        val accent = accentColor(scene)
        val anchoredAlpha = policy.anchoredAlphaMultiplier
        val anchoredBlend = policy.anchoredPlacementBlend
        val alphaScale = scene.presentation.guideAlpha * policy.guideAlphaMultiplier * anchoredAlpha
        val emphasis = scene.presentation.emphasisLevel
        val detailLevel = scene.presentation.detailLevel
        val guidePathData = NativeDriveArAnchoredGuidePath.build(
            scene = scene,
            anchors = anchors,
            drawWidth = drawWidth,
            drawHeight = drawHeight,
            strokeScale = strokeScale,
            policy = policy,
        )
        if (policy.drawRibbon) {
            ribbonRenderer.draw(
                canvas = canvas,
                scene = scene,
                anchors = guidePathData.anchors,
                accentColor = accent,
                strokeScale = strokeScale,
                alphaMultiplier = anchoredAlpha,
            )
        }
        guidePath.reset()
        guidePath.moveTo(guidePathData.anchors.pathPoints.first().x, guidePathData.anchors.pathPoints.first().y)
        for (i in 1 until guidePathData.anchors.pathPoints.size) {
            guidePath.lineTo(guidePathData.anchors.pathPoints[i].x, guidePathData.anchors.pathPoints[i].y)
        }
        val anchoredStyle =
            NativeDriveArGuideVisualTuning.anchoredPathStyle(
                emphasisLevel = emphasis,
                alphaScale = alphaScale,
                anchoredBlend = anchoredBlend,
                strokeScale = strokeScale,
            )
        glowPaint.color = withAlpha(accent, anchoredStyle.glowAlpha)
        glowPaint.strokeWidth = anchoredStyle.glowWidth
        corePaint.color = withAlpha(accent, anchoredStyle.coreAlpha)
        corePaint.strokeWidth = anchoredStyle.coreWidth
        canvas.drawPath(guidePath, glowPaint)
        canvas.drawPath(guidePath, corePaint)

        if (policy.drawTrail) {
            trailRenderer.drawPathPointTrail(
                canvas = canvas,
                pathPoints = guidePathData.anchors.pathPoints,
                pathDistances = guidePathData.anchors.pathDistances,
                accentColor = accent,
                strokeScale = strokeScale,
                detailLevel = detailLevel,
                distanceBucket = scene.presentation.distanceBucket,
                directionKey = scene.presentation.turnDirectionKey,
                alphaScale = scene.presentation.trailAlpha * policy.trailAlphaMultiplier * anchoredAlpha,
                emphasisLevel = emphasis,
            )
        }

        val start = guidePathData.anchors.pathPoints.first()
        val end = NativeDriveArAnchoredGuidePath.preferredHeadPoint(
            scene = scene,
            guidePath = guidePathData,
            anchoredBlend = anchoredBlend,
        )
        drawGuideAnchor(
            canvas,
            start.x,
            start.y,
            accent,
            strokeScale,
            alphaScale = alphaScale,
            emphasize = emphasis >= 2 || scene.presentation.distanceBucket == "immediate",
        )
        if (scene.presentation.mode == "arrival" && guidePathData.gateAnchor != null) {
            drawArrivalHaloAt(
                canvas,
                guidePathData.gateAnchor.x,
                guidePathData.gateAnchor.y,
                scene,
                strokeScale,
                policy,
            )
        } else {
            drawGuideHead(
                canvas,
                end.x,
                end.y,
                scene.presentation.turnDirectionKey.ifBlank { scene.turnCue?.directionKey.orEmpty() },
                accent,
                strokeScale,
                alphaScale = alphaScale,
                emphasize = emphasis >= 2 || scene.presentation.distanceBucket == "immediate",
            )
        }
    }

    private fun drawRouteGuide(
        canvas: Canvas,
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        val baseY = drawHeight * 0.74f
        val startX = drawWidth * 0.42f
        val endX = drawWidth * 0.58f
        val endY = drawHeight * if (scene.presentation.compactPreferred) 0.56f else 0.52f
        val accent = accentColor(scene)
        guidePath.reset()
        guidePath.moveTo(startX, baseY)
        guidePath.quadTo(drawWidth * 0.50f, drawHeight * 0.66f, endX, endY)
        val alphaScale = scene.presentation.guideAlpha * policy.guideAlphaMultiplier
        val emphasis = scene.presentation.emphasisLevel
        val routeStyle =
            NativeDriveArGuideVisualTuning.routePathStyle(
                emphasisLevel = emphasis,
                alphaScale = alphaScale,
                strokeScale = strokeScale,
            )
        glowPaint.color = withAlpha(accent, routeStyle.glowAlpha)
        glowPaint.strokeWidth = routeStyle.glowWidth
        corePaint.color = withAlpha(accent, routeStyle.coreAlpha)
        corePaint.strokeWidth = routeStyle.coreWidth
        canvas.drawPath(guidePath, glowPaint)
        canvas.drawPath(guidePath, corePaint)
        if (policy.drawTrail) {
            trailRenderer.drawQuadraticTrail(
                canvas = canvas,
                startX = startX,
                startY = baseY,
                ctrlX = drawWidth * 0.50f,
                ctrlY = drawHeight * 0.66f,
                endX = endX,
                endY = endY,
                accentColor = accent,
                strokeScale = strokeScale,
                detailLevel = scene.presentation.detailLevel,
                distanceBucket = scene.presentation.distanceBucket,
                directionKey = scene.presentation.turnDirectionKey,
                alphaScale = scene.presentation.trailAlpha * policy.trailAlphaMultiplier,
                emphasisLevel = emphasis,
            )
        }
    }

    private fun drawTurnGuide(
        canvas: Canvas,
        scene: NativeDriveArScene,
        direction: String,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        val distanceBucket = scene.presentation.distanceBucket
        val accent = accentColor(scene)
        val detailLevel = scene.presentation.detailLevel
        val emphasis = scene.presentation.emphasisLevel
        val alphaScale = scene.presentation.guideAlpha * policy.guideAlphaMultiplier
        val dirSign = when (direction) {
            "left", "lane_left", "u_turn" -> -1f
            "right", "lane_right" -> 1f
            else -> 0f
        }
        if (dirSign == 0f) {
            drawRouteGuide(canvas, scene, drawWidth, drawHeight, strokeScale, policy)
            return
        }

        val immediate = distanceBucket == "immediate"
        val near = distanceBucket == "near"
        val lateral = when (direction) {
            "lane_left", "lane_right" -> 0.14f
            "u_turn" -> 0.18f
            else -> if (immediate) 0.24f else if (near) 0.20f else 0.17f
        }
        val heightFactor = when {
            immediate -> 0.42f
            near -> 0.50f
            else -> 0.58f
        }
        val startX = drawWidth * 0.50f
        val startY = drawHeight * if (scene.presentation.compactPreferred) 0.78f else 0.80f
        val endX = drawWidth * (0.50f + (dirSign * lateral))
        val endY = drawHeight * heightFactor
        val ctrlX = drawWidth * (0.50f + (dirSign * max(0.07f, lateral * 0.55f)))
        val ctrlY = drawHeight * (if (immediate) 0.64f else 0.67f)

        guidePath.reset()
        guidePath.moveTo(startX, startY)
        guidePath.quadTo(ctrlX, ctrlY, endX, endY)
        val turnStyle =
            NativeDriveArGuideVisualTuning.turnPathStyle(
                immediate = immediate,
                emphasisLevel = emphasis,
                alphaScale = alphaScale,
                strokeScale = strokeScale,
            )
        glowPaint.color = withAlpha(accent, turnStyle.glowAlpha)
        glowPaint.strokeWidth = turnStyle.glowWidth
        corePaint.color = withAlpha(accent, turnStyle.coreAlpha)
        corePaint.strokeWidth = turnStyle.coreWidth
        canvas.drawPath(guidePath, glowPaint)
        canvas.drawPath(guidePath, corePaint)
        if (policy.drawTrail) {
            trailRenderer.drawQuadraticTrail(
                canvas = canvas,
                startX = startX,
                startY = startY,
                ctrlX = ctrlX,
                ctrlY = ctrlY,
                endX = endX,
                endY = endY,
                accentColor = accent,
                strokeScale = strokeScale,
                detailLevel = detailLevel,
                distanceBucket = distanceBucket,
                directionKey = direction,
                alphaScale = scene.presentation.trailAlpha * policy.trailAlphaMultiplier,
                emphasisLevel = emphasis,
            )
        }

        drawGuideAnchor(
            canvas,
            startX,
            startY,
            accent,
            strokeScale,
            alphaScale = alphaScale,
            emphasize = immediate || emphasis >= 2,
        )
        drawGuideHead(
            canvas,
            endX,
            endY,
            direction,
            accent,
            strokeScale,
            alphaScale = alphaScale,
            emphasize = immediate || emphasis >= 2,
        )

        if (policy.drawGuideSecondary) {
            val offset = 14f * strokeScale * if (direction == "u_turn") 0.5f else 1f
            guidePath.reset()
            guidePath.moveTo(startX + (dirSign * offset), startY - (8f * strokeScale))
            guidePath.quadTo(
                ctrlX + (dirSign * offset * 0.72f),
                ctrlY - (12f * strokeScale),
                endX + (dirSign * offset * 0.42f),
                endY - (8f * strokeScale),
            )
            val secondaryStyle =
                NativeDriveArGuideVisualTuning.secondaryTurnPathStyle(
                    alphaScale = alphaScale,
                    strokeScale = strokeScale,
                )
            glowPaint.color = withAlpha(accent, secondaryStyle.glowAlpha)
            glowPaint.strokeWidth = secondaryStyle.glowWidth
            corePaint.color = withAlpha(accent, secondaryStyle.coreAlpha)
            corePaint.strokeWidth = secondaryStyle.coreWidth
            canvas.drawPath(guidePath, glowPaint)
            canvas.drawPath(guidePath, corePaint)
        }
    }

    private fun drawArrivalHalo(
        canvas: Canvas,
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        val cx = drawWidth * 0.5f
        val cy = drawHeight * 0.67f
        drawArrivalHaloAt(canvas, cx, cy, scene, strokeScale, policy)
    }

    private fun drawArrivalHaloAt(
        canvas: Canvas,
        cx: Float,
        cy: Float,
        scene: NativeDriveArScene,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
    ) {
        val accent = accentColor(scene)
        val alphaScale = (scene.presentation.guideAlpha * policy.guideAlphaMultiplier).coerceAtLeast(0.7f)
        val haloStyle =
            NativeDriveArGuideVisualTuning.arrivalHaloStyle(
                alphaScale = alphaScale,
                strokeScale = strokeScale,
            )
        glowPaint.color = withAlpha(accent, haloStyle.glowAlpha)
        glowPaint.strokeWidth = haloStyle.glowWidth
        corePaint.color = withAlpha(accent, haloStyle.coreAlpha)
        corePaint.strokeWidth = haloStyle.coreWidth
        fillPaint.color = withAlpha(accent, haloStyle.fillAlpha)
        canvas.drawCircle(cx, cy, haloStyle.outerRadius, glowPaint)
        canvas.drawCircle(cx, cy, haloStyle.outerRadius, corePaint)
        canvas.drawCircle(cx, cy, haloStyle.innerRadius, fillPaint)
        if (scene.presentation.detailLevel >= 3 && policy.effectiveRenderBudget >= 2) {
            corePaint.strokeWidth = (2f * strokeScale).coerceAtLeast(1.5f)
            corePaint.color = withAlpha(Color.WHITE, (204f * alphaScale).toInt())
            canvas.drawCircle(cx, cy, haloStyle.innerRadius * 0.42f, corePaint)
        }
    }

    private fun drawGuideAnchor(
        canvas: Canvas,
        x: Float,
        y: Float,
        color: Int,
        strokeScale: Float,
        alphaScale: Float,
        emphasize: Boolean,
    ) {
        val anchorStyle =
            NativeDriveArGuideVisualTuning.guideAnchorStyle(
                emphasize = emphasize,
                alphaScale = alphaScale,
                strokeScale = strokeScale,
            )
        fillPaint.color = withAlpha(color, anchorStyle.fillAlpha)
        corePaint.color = withAlpha(Color.WHITE, anchorStyle.strokeAlpha)
        corePaint.strokeWidth = anchorStyle.strokeWidth
        canvas.drawCircle(x, y, anchorStyle.outerRadius, fillPaint)
        canvas.drawCircle(x, y, anchorStyle.outerRadius, corePaint)
        fillPaint.color = withAlpha(Color.WHITE, anchorStyle.innerFillAlpha)
        canvas.drawCircle(x, y, anchorStyle.innerRadius, fillPaint)
    }

    private fun drawGuideHead(
        canvas: Canvas,
        x: Float,
        y: Float,
        direction: String,
        color: Int,
        strokeScale: Float,
        alphaScale: Float,
        emphasize: Boolean,
    ) {
        if (direction.isBlank() || direction == "none" || direction == "arrival") return
        val headStyle =
            NativeDriveArGuideVisualTuning.guideHeadStyle(
                emphasize = emphasize,
                alphaScale = alphaScale,
                strokeScale = strokeScale,
            )
        val dir = when (direction) {
            "left", "lane_left", "u_turn" -> -1f
            else -> 1f
        }
        guidePath.reset()
        guidePath.moveTo(x, y)
        guidePath.lineTo(x - (dir * headStyle.width), y - headStyle.height)
        guidePath.lineTo(x - (dir * headStyle.width * 0.82f), y + headStyle.height)
        guidePath.close()
        fillPaint.color = withAlpha(color, headStyle.fillAlpha)
        canvas.drawPath(guidePath, fillPaint)
        corePaint.color = withAlpha(Color.WHITE, headStyle.strokeAlpha)
        corePaint.strokeWidth = headStyle.strokeWidth
        canvas.drawPath(guidePath, corePaint)
    }

    private fun accentColor(scene: NativeDriveArScene): Int =
        when (scene.presentation.accentKey) {
            "warning" -> Color.parseColor("#D97A5100")
            "arrival" -> Color.parseColor("#E617A84B")
            "inactive" -> Color.parseColor("#996C7480")
            else -> Color.parseColor("#CC1C8E54")
        }

    private fun withAlpha(color: Int, alpha: Int): Int =
        Color.argb(alpha.coerceIn(0, 255), Color.red(color), Color.green(color), Color.blue(color))

}
