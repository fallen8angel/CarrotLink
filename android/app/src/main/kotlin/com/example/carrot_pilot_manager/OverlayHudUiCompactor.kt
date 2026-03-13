package com.example.carrot_pilot_manager

import java.util.Locale

internal object OverlayHudUiCompactor {
  fun compress(
      state: OverlayHudUiState,
      profile: OverlayHudLayoutProfile,
  ): OverlayHudUiState {
    val isTiny = profile.metaMode == OverlayHudMetaMode.Tiny
    val quality = state.qualityText.trim().lowercase(Locale.US)
    val degraded =
        quality.isNotEmpty() && quality != "live" ||
            state.compatibilityHint.isNotBlank() ||
            state.sourceText == "COMPAT" ||
            state.sourceText == "FALLBACK"
    val shortQuality = when {
      quality.isEmpty() || quality == "live" -> when (state.sourceText) {
        "COMPAT" -> "compat"
        "FALLBACK" -> "fallback"
        else -> if (degraded) "degraded" else ""
      }

      quality == "legacy" -> "compat"
      else -> quality
    }
    val compactHint = state.compatibilityBadgeText.takeIf { it.isNotBlank() }
    val detailText = when (profile.metaMode) {
      OverlayHudMetaMode.Tiny -> listOfNotNull(
          compactHint,
          shortQuality.takeIf { it.isNotBlank() && it != "live" },
      ).joinToString(" · ")

      OverlayHudMetaMode.Compact -> listOfNotNull(
          shortQuality.takeIf { it.isNotBlank() },
          compactHint,
      ).joinToString(" · ")

      OverlayHudMetaMode.Full -> listOfNotNull(
          if (quality == "live" && compactHint == null && !degraded) null else state.qualityText.takeIf { it.isNotBlank() },
          state.hostText.takeIf { it.isNotBlank() && (degraded || profile.wide) },
          state.compatibilityHint.takeIf { it.isNotBlank() },
      ).joinToString(" · ")
    }

    val sourceText = when {
      isTiny && state.sourceText == "COMPAT" -> "CP"
      isTiny && state.sourceText == "PREVIEW" -> "PRV"
      isTiny && state.sourceText == "FALLBACK" -> "FB"
      profile.metaMode == OverlayHudMetaMode.Compact && state.sourceText == "FALLBACK" -> "FB"
      else -> state.sourceText
    }
    val statusText = when {
      isTiny && degraded -> listOfNotNull(
          compactHint,
          shortQuality.takeIf { it.isNotBlank() && it != "live" },
      ).joinToString(" · ").ifBlank { state.statusText }

      isTiny -> ""
      profile.metaMode == OverlayHudMetaMode.Compact && state.hostText.isNotBlank() -> state.hostText
      profile.metaMode == OverlayHudMetaMode.Compact && degraded -> listOfNotNull(
          shortQuality.takeIf { it.isNotBlank() },
          compactHint,
      ).joinToString(" · ").ifBlank { state.statusText }

      else -> state.statusText
    }

    return state.copy(
        sourceText = sourceText,
        detailText = detailText,
        statusText = statusText,
    )
  }
}
