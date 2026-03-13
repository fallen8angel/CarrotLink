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
          minWidthDp = if (wide) 276 else 248,
          minHeightDp = if (wide) 178 else 198,
          horizontalPaddingDp = 11,
          verticalPaddingDp = 9,
          radiusDp = 16f,
          metricLabelSp = 10f,
          metricValueSp = 13.5f,
          speedSp = 46f,
          secondarySp = 18f,
          bodySp = 14f,
          smallSp = 12f,
          gearSp = 25f,
          metricCellMinWidthDp = 60,
          sectionGapDp = 9,
          showMetricsRow = true,
          showDetailLine = false,
          metaMode = OverlayHudMetaMode.Tiny,
      )

      shortestDp < 540f -> OverlayHudLayoutProfile(
          wide = wide,
          minWidthDp = if (wide) 318 else 282,
          minHeightDp = if (wide) 192 else 214,
          horizontalPaddingDp = 13,
          verticalPaddingDp = 11,
          radiusDp = 18f,
          metricLabelSp = 11f,
          metricValueSp = 15f,
          speedSp = 52f,
          secondarySp = 20f,
          bodySp = 15f,
          smallSp = 13f,
          gearSp = 28f,
          metricCellMinWidthDp = 68,
          sectionGapDp = 11,
          showMetricsRow = true,
          showDetailLine = true,
          metaMode = OverlayHudMetaMode.Compact,
      )

      else -> OverlayHudLayoutProfile(
          wide = wide,
          minWidthDp = if (wide) 366 else 320,
          minHeightDp = if (wide) 214 else 234,
          horizontalPaddingDp = 15,
          verticalPaddingDp = 13,
          radiusDp = 20f,
          metricLabelSp = 12f,
          metricValueSp = 16f,
          speedSp = 58f,
          secondarySp = 22f,
          bodySp = 16f,
          smallSp = 13.5f,
          gearSp = 31f,
          metricCellMinWidthDp = 74,
          sectionGapDp = 13,
          showMetricsRow = true,
          showDetailLine = true,
          metaMode = OverlayHudMetaMode.Full,
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
