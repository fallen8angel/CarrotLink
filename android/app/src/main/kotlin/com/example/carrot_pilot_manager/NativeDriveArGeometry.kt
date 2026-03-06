package com.example.carrot_pilot_manager

import kotlin.math.max

internal object NativeDriveArGeometry {
    fun defaultDirectionalCenterX(
        directionKey: String,
        drawWidth: Float,
    ): Float =
        when (directionKey) {
            "left", "lane_left", "u_turn" -> drawWidth * 0.40f
            "right", "lane_right" -> drawWidth * 0.60f
            else -> drawWidth * 0.50f
        }

    fun fallbackGuideHeadPoint(
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
    ): NativeDriveArScene.ScreenPoint {
        val directionKey = scene.presentation.turnDirectionKey.ifBlank {
            scene.turnCue?.directionKey.orEmpty()
        }
        return NativeDriveArScene.ScreenPoint(
            x = defaultDirectionalCenterX(directionKey, drawWidth),
            y = NativeDriveArGuideTuning.fallbackHeadY(scene.presentation.distanceBucket, drawHeight),
        )
    }

    fun sampleQuadraticPath(
        startX: Float,
        startY: Float,
        ctrlX: Float,
        ctrlY: Float,
        endX: Float,
        endY: Float,
        count: Int,
    ): List<NativeDriveArScene.ScreenPoint> =
        List(count) { index ->
            val t = if (count <= 1) 1f else index.toFloat() / (count - 1).toFloat()
            val oneMinusT = 1f - t
            val x =
                (oneMinusT * oneMinusT * startX) +
                    (2f * oneMinusT * t * ctrlX) +
                    (t * t * endX)
            val y =
                (oneMinusT * oneMinusT * startY) +
                    (2f * oneMinusT * t * ctrlY) +
                    (t * t * endY)
            NativeDriveArScene.ScreenPoint(x = x, y = y)
        }

    fun blendedPoint(
        fallback: NativeDriveArScene.ScreenPoint,
        anchor: NativeDriveArScene.ScreenPoint,
        blend: Float,
    ): NativeDriveArScene.ScreenPoint =
        NativeDriveArScene.ScreenPoint(
            x = lerp(fallback.x, anchor.x, blend),
            y = lerp(fallback.y, anchor.y, blend),
        )

    fun blendedScalar(
        fallback: Float,
        anchor: Float?,
        blend: Float,
    ): Float {
        anchor ?: return fallback
        return lerp(fallback, anchor, blend.coerceIn(0f, 1f))
    }

    fun routeTurnLateral(
        directionKey: String,
        immediate: Boolean,
        near: Boolean,
    ): Float =
        when (directionKey) {
            "lane_left", "lane_right" -> 0.14f
            "u_turn" -> 0.18f
            else -> if (immediate) 0.24f else if (near) 0.20f else 0.17f
        }

    fun routeTurnHeightFactor(
        immediate: Boolean,
        near: Boolean,
    ): Float =
        when {
            immediate -> 0.42f
            near -> 0.50f
            else -> 0.58f
        }

    fun routeTurnCtrlOffset(lateral: Float): Float = max(0.07f, lateral * 0.55f)

    private fun lerp(start: Float, end: Float, t: Float): Float =
        start + ((end - start) * t.coerceIn(0f, 1f))
}
