package com.example.carrot_pilot_manager

internal data class NativeDriveArStrokeStyle(
    val glowAlpha: Int,
    val glowWidth: Float,
    val coreAlpha: Int,
    val coreWidth: Float,
)

internal data class NativeDriveArHaloStyle(
    val outerRadius: Float,
    val innerRadius: Float,
    val glowAlpha: Int,
    val glowWidth: Float,
    val coreAlpha: Int,
    val coreWidth: Float,
    val fillAlpha: Int,
)

internal data class NativeDriveArAnchorStyle(
    val outerRadius: Float,
    val innerRadius: Float,
    val fillAlpha: Int,
    val strokeAlpha: Int,
    val strokeWidth: Float,
    val innerFillAlpha: Int,
)

internal data class NativeDriveArHeadStyle(
    val width: Float,
    val height: Float,
    val fillAlpha: Int,
    val strokeAlpha: Int,
    val strokeWidth: Float,
)

internal object NativeDriveArGuideVisualTuning {
    fun anchoredPathStyle(
        emphasisLevel: Int,
        alphaScale: Float,
        anchoredBlend: Float,
        strokeScale: Float,
    ): NativeDriveArStrokeStyle =
        NativeDriveArStrokeStyle(
            glowAlpha = ((56f + (emphasisLevel * 5f)) * alphaScale).toInt(),
            glowWidth =
                (((16f + (emphasisLevel * 1.1f)) * lerp(0.82f, 1f, anchoredBlend)) * strokeScale)
                    .coerceAtLeast(8f),
            coreAlpha = ((214f + (emphasisLevel * 7f)) * alphaScale).toInt(),
            coreWidth =
                (((6f + (emphasisLevel * 0.4f)) * lerp(0.88f, 1f, anchoredBlend)) * strokeScale)
                    .coerceAtLeast(3f),
        )

    fun routePathStyle(
        emphasisLevel: Int,
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArStrokeStyle =
        NativeDriveArStrokeStyle(
            glowAlpha = (54f * alphaScale).toInt(),
            glowWidth = ((16f + (emphasisLevel * 1.1f)) * strokeScale).coerceAtLeast(8f),
            coreAlpha = (210f * alphaScale).toInt(),
            coreWidth = ((6f + (emphasisLevel * 0.4f)) * strokeScale).coerceAtLeast(3f),
        )

    fun turnPathStyle(
        immediate: Boolean,
        emphasisLevel: Int,
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArStrokeStyle =
        NativeDriveArStrokeStyle(
            glowAlpha = (((if (immediate) 74f else 56f) + (emphasisLevel * 4f)) * alphaScale).toInt(),
            glowWidth = (((if (immediate) 20f else 16f) + (emphasisLevel * 1.2f)) * strokeScale),
            coreAlpha = ((224f + (emphasisLevel * 6f)) * alphaScale).toInt(),
            coreWidth = (((if (immediate) 7f else 6f) + (emphasisLevel * 0.35f)) * strokeScale),
        )

    fun secondaryTurnPathStyle(
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArStrokeStyle =
        NativeDriveArStrokeStyle(
            glowAlpha = (32f * alphaScale).toInt(),
            glowWidth = (10f * strokeScale).coerceAtLeast(5f),
            coreAlpha = (122f * alphaScale).toInt(),
            coreWidth = (3f * strokeScale).coerceAtLeast(2f),
        )

    fun arrivalHaloStyle(
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArHaloStyle {
        val outer = (34f * strokeScale).coerceAtLeast(18f)
        return NativeDriveArHaloStyle(
            outerRadius = outer,
            innerRadius = outer * 0.56f,
            glowAlpha = (50f * alphaScale).toInt(),
            glowWidth = (12f * strokeScale).coerceAtLeast(6f),
            coreAlpha = (220f * alphaScale).toInt(),
            coreWidth = (3.2f * strokeScale).coerceAtLeast(2f),
            fillAlpha = (68f * alphaScale).toInt(),
        )
    }

    fun guideAnchorStyle(
        emphasize: Boolean,
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArAnchorStyle {
        val outer = (if (emphasize) 10f else 8f) * strokeScale
        return NativeDriveArAnchorStyle(
            outerRadius = outer,
            innerRadius = outer * 0.42f,
            fillAlpha = (86f * alphaScale).toInt(),
            strokeAlpha = (212f * alphaScale).toInt(),
            strokeWidth = (2f * strokeScale).coerceAtLeast(1.5f),
            innerFillAlpha = (255f * alphaScale).toInt(),
        )
    }

    fun guideHeadStyle(
        emphasize: Boolean,
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArHeadStyle =
        NativeDriveArHeadStyle(
            width = (if (emphasize) 18f else 14f) * strokeScale,
            height = (if (emphasize) 12f else 10f) * strokeScale,
            fillAlpha = (210f * alphaScale).toInt(),
            strokeAlpha = (212f * alphaScale).toInt(),
            strokeWidth = (1.8f * strokeScale).coerceAtLeast(1.3f),
        )

    private fun lerp(
        start: Float,
        end: Float,
        t: Float,
    ): Float = start + ((end - start) * t.coerceIn(0f, 1f))
}
