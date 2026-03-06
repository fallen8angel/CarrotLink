package com.example.carrot_pilot_manager

internal object NativeDriveArGuideTuning {
    fun displayDistanceLimit(
        distanceBucket: String,
        detailLevel: Int,
    ): Float =
        when (distanceBucket) {
            "immediate" -> 24f
            "near" -> 36f + (detailLevel.coerceAtMost(2) * 3f)
            "far" -> 56f + (detailLevel.coerceAtMost(3) * 4f)
            "arrival" -> 18f
            else -> 32f + (detailLevel.coerceAtMost(2) * 3f)
        }

    fun anchoredDisplayDistanceLimit(
        distanceBucket: String,
        renderBudget: Int,
        effectiveAnchorQuality: Float,
    ): Float {
        val baseDistance =
            when (distanceBucket) {
                "immediate" -> 22f
                "near" -> 30f
                "far" -> 44f
                "arrival" -> 18f
                else -> 28f
            }
        val budgetScale =
            when (renderBudget) {
                0 -> 0.70f
                1 -> 0.82f
                2 -> 0.94f
                else -> 1f
            }
        val qualityScale =
            when {
                effectiveAnchorQuality >= 0.70f -> 1f
                effectiveAnchorQuality >= 0.52f -> 0.92f
                effectiveAnchorQuality >= 0.36f -> 0.82f
                else -> 0.70f
            }
        return (baseDistance * budgetScale * qualityScale).coerceAtLeast(14f)
    }

    fun anchoredMaxPointCount(
        distanceBucket: String,
        renderBudget: Int,
        effectiveAnchorQuality: Float,
    ): Int {
        val baseCount =
            when (distanceBucket) {
                "immediate" -> 7
                "near" -> 9
                "far" -> 12
                "arrival" -> 6
                else -> 8
            }
        val budgetAdjust =
            when (renderBudget) {
                0 -> -2
                1 -> -1
                2 -> 0
                else -> 1
            }
        val qualityAdjust =
            when {
                effectiveAnchorQuality >= 0.70f -> 1
                effectiveAnchorQuality >= 0.52f -> 0
                effectiveAnchorQuality >= 0.36f -> -1
                else -> -2
            }
        return (baseCount + budgetAdjust + qualityAdjust).coerceIn(4, 14)
    }

    fun anchoredMinSegmentSpacingPx(
        renderBudget: Int,
        effectiveAnchorQuality: Float,
    ): Float {
        val baseSpacing =
            when (renderBudget) {
                0 -> 18f
                1 -> 14f
                2 -> 10f
                else -> 8f
            }
        val qualityScale =
            when {
                effectiveAnchorQuality >= 0.70f -> 0.84f
                effectiveAnchorQuality >= 0.52f -> 1f
                effectiveAnchorQuality >= 0.36f -> 1.18f
                else -> 1.34f
            }
        return (baseSpacing * qualityScale).coerceIn(6f, 24f)
    }

    fun preferredPathTargetDistance(distanceBucket: String): Float =
        when (distanceBucket) {
            "immediate" -> 18f
            "near" -> 28f
            "far" -> 42f
            "arrival" -> 12f
            else -> 24f
        }

    fun fallbackHeadY(
        distanceBucket: String,
        drawHeight: Float,
    ): Float =
        when (distanceBucket) {
            "immediate" -> drawHeight * 0.46f
            "near" -> drawHeight * 0.50f
            "arrival" -> drawHeight * 0.44f
            else -> drawHeight * 0.56f
        }

    fun gateFallbackAnchorY(
        distanceBucket: String,
        drawHeight: Float,
    ): Float =
        when (distanceBucket) {
            "immediate" -> drawHeight * 0.46f
            "near" -> drawHeight * 0.42f
            "arrival" -> drawHeight * 0.40f
            else -> drawHeight * 0.38f
        }

    fun shellEmphasisScale(distanceBucket: String): Float =
        when (distanceBucket) {
            "immediate", "arrival" -> 1.04f
            "near" -> 1.02f
            else -> 1f
        }
}
