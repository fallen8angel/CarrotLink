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
            glowAlpha = ((92f + (emphasisLevel * 10f)) * alphaScale).toInt(),
            glowWidth =
                (((22f + (emphasisLevel * 1.8f)) * lerp(0.86f, 1.08f, anchoredBlend)) * strokeScale)
                    .coerceAtLeast(11f),
            coreAlpha = ((244f + (emphasisLevel * 4f)) * alphaScale).toInt(),
            coreWidth =
                (((8.2f + (emphasisLevel * 0.65f)) * lerp(0.92f, 1.08f, anchoredBlend)) * strokeScale)
                    .coerceAtLeast(4.4f),
        )

    fun routePathStyle(
        emphasisLevel: Int,
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArStrokeStyle =
        NativeDriveArStrokeStyle(
            glowAlpha = (88f * alphaScale).toInt(),
            glowWidth = ((20f + (emphasisLevel * 1.5f)) * strokeScale).coerceAtLeast(10f),
            coreAlpha = (238f * alphaScale).toInt(),
            coreWidth = ((8f + (emphasisLevel * 0.65f)) * strokeScale).coerceAtLeast(4f),
        )

    fun turnPathStyle(
        immediate: Boolean,
        emphasisLevel: Int,
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArStrokeStyle =
        NativeDriveArStrokeStyle(
            glowAlpha = (((if (immediate) 108f else 88f) + (emphasisLevel * 7f)) * alphaScale).toInt(),
            glowWidth = (((if (immediate) 26f else 22f) + (emphasisLevel * 1.6f)) * strokeScale),
            coreAlpha = ((248f + (emphasisLevel * 3f)) * alphaScale).toInt(),
            coreWidth = (((if (immediate) 9f else 8f) + (emphasisLevel * 0.45f)) * strokeScale),
        )

    fun secondaryTurnPathStyle(
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArStrokeStyle =
        NativeDriveArStrokeStyle(
            glowAlpha = (56f * alphaScale).toInt(),
            glowWidth = (12f * strokeScale).coerceAtLeast(6f),
            coreAlpha = (162f * alphaScale).toInt(),
            coreWidth = (3.8f * strokeScale).coerceAtLeast(2.2f),
        )

    fun arrivalHaloStyle(
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArHaloStyle {
        val outer = (42f * strokeScale).coerceAtLeast(22f)
        return NativeDriveArHaloStyle(
            outerRadius = outer,
            innerRadius = outer * 0.56f,
            glowAlpha = (82f * alphaScale).toInt(),
            glowWidth = (16f * strokeScale).coerceAtLeast(8f),
            coreAlpha = (238f * alphaScale).toInt(),
            coreWidth = (4f * strokeScale).coerceAtLeast(2.4f),
            fillAlpha = (98f * alphaScale).toInt(),
        )
    }

    fun guideAnchorStyle(
        emphasize: Boolean,
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArAnchorStyle {
        val outer = (if (emphasize) 13f else 10f) * strokeScale
        return NativeDriveArAnchorStyle(
            outerRadius = outer,
            innerRadius = outer * 0.42f,
            fillAlpha = (118f * alphaScale).toInt(),
            strokeAlpha = (236f * alphaScale).toInt(),
            strokeWidth = (2.4f * strokeScale).coerceAtLeast(1.8f),
            innerFillAlpha = (255f * alphaScale).toInt(),
        )
    }

    fun guideHeadStyle(
        emphasize: Boolean,
        alphaScale: Float,
        strokeScale: Float,
    ): NativeDriveArHeadStyle =
        NativeDriveArHeadStyle(
            width = (if (emphasize) 22f else 18f) * strokeScale,
            height = (if (emphasize) 15f else 12f) * strokeScale,
            fillAlpha = (232f * alphaScale).toInt(),
            strokeAlpha = (236f * alphaScale).toInt(),
            strokeWidth = (2.2f * strokeScale).coerceAtLeast(1.5f),
        )

    private fun lerp(
        start: Float,
        end: Float,
        t: Float,
    ): Float = start + ((end - start) * t.coerceIn(0f, 1f))
}
