package com.example.carrot_pilot_manager

internal object OverlayHudLayoutProfiles {
  fun fromScreenBounds(
      widthPx: Int,
      heightPx: Int,
      density: Float,
  ): OverlayHudLayoutProfile {
    val safeDensity = density.coerceAtLeast(1f)
    val widthDp = widthPx / safeDensity
    val heightDp = heightPx / safeDensity
    val shortestDp = minOf(widthDp, heightDp)
    val wide = widthDp >= heightDp * 1.18f
    return when {
      shortestDp < 360f -> OverlayHudLayoutProfile(
          wide = wide,
          minWidthDp = if (wide) 256 else 232,
          minHeightDp = if (wide) 164 else 184,
          horizontalPaddingDp = 10,
          verticalPaddingDp = 8,
          radiusDp = 16f,
          metricLabelSp = 9f,
          metricValueSp = 12f,
          speedSp = 40f,
          secondarySp = 16f,
          bodySp = 13f,
          smallSp = 11f,
          gearSp = 22f,
          metricCellMinWidthDp = 56,
          sectionGapDp = 8,
          showMetricsRow = wide,
          showDetailLine = false,
      )

      shortestDp < 540f -> OverlayHudLayoutProfile(
          wide = wide,
          minWidthDp = if (wide) 292 else 260,
          minHeightDp = if (wide) 176 else 196,
          horizontalPaddingDp = 12,
          verticalPaddingDp = 10,
          radiusDp = 18f,
          metricLabelSp = 10f,
          metricValueSp = 13f,
          speedSp = 46f,
          secondarySp = 18f,
          bodySp = 14f,
          smallSp = 12f,
          gearSp = 24f,
          metricCellMinWidthDp = 64,
          sectionGapDp = 10,
          showMetricsRow = true,
          showDetailLine = !wide,
      )

      else -> OverlayHudLayoutProfile(
          wide = wide,
          minWidthDp = if (wide) 336 else 292,
          minHeightDp = if (wide) 196 else 214,
          horizontalPaddingDp = 14,
          verticalPaddingDp = 12,
          radiusDp = 20f,
          metricLabelSp = 11f,
          metricValueSp = 14f,
          speedSp = 52f,
          secondarySp = 20f,
          bodySp = 15f,
          smallSp = 12.5f,
          gearSp = 28f,
          metricCellMinWidthDp = 70,
          sectionGapDp = 12,
          showMetricsRow = true,
          showDetailLine = true,
      )
    }
  }

  fun signature(profile: OverlayHudLayoutProfile): String {
    return listOf(
        profile.wide,
        profile.minWidthDp,
        profile.minHeightDp,
        profile.horizontalPaddingDp,
        profile.verticalPaddingDp,
        profile.radiusDp,
        profile.speedSp,
        profile.secondarySp,
        profile.bodySp,
        profile.gearSp,
    ).joinToString("|")
  }
}
