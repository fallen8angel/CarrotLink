package com.example.carrot_pilot_manager

import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.View
import android.widget.TextView

internal object OverlayHudUiApplier {
  fun apply(bindings: OverlayHudViewBindings, state: OverlayHudUiState) {
    setTextIfChanged(bindings.sourceValue, state.sourceText)
    setTextIfChanged(bindings.detailValue, state.detailText)
    setTextIfChanged(bindings.metricCpuValue, state.cpuText)
    setTextIfChanged(bindings.metricMemValue, state.memText)
    setTextIfChanged(bindings.metricVoltLabel, state.auxMetricLabel)
    setTextIfChanged(bindings.metricVoltValue, state.auxMetricValue)
    setTextIfChanged(bindings.speedValue, state.speedText)
    setTextIfChanged(bindings.setSpeedValue, state.setSpeedText)
    setTextIfChanged(bindings.gearValue, formatGearText(state.gearText))
    setTextIfChanged(bindings.gpsValue, state.gpsText)
    setTextIfChanged(bindings.tempSourceValue, state.tempSourceText)
    setTextIfChanged(bindings.tempSpeedValue, state.tempSpeedText)
    setTextIfChanged(bindings.gapValue, formatGapText(state.gapText))
    setTextIfChanged(bindings.limitValue, state.limitText)
    setTextIfChanged(bindings.connectivityValue, state.connectivityText)
    setTextIfChanged(bindings.modeValue, state.modeText)
    setTextIfChanged(bindings.statusValue, state.statusText)

    bindings.tempSpeedValue.setTextColor(
        Color.WHITE,
    )
    bindings.limitValue.setTextColor(Color.WHITE)
    bindings.gpsValue.setTextColor(if (state.gpsOk) Color.WHITE else Color.parseColor("#A0FFFFFF"))
    if (state.statusText.isBlank()) {
      bindings.statusValue.visibility = View.GONE
    } else if (bindings.statusValue.visibility != View.VISIBLE) {
      bindings.statusValue.visibility = View.VISIBLE
    }
    if (state.detailText.isBlank()) {
      bindings.detailValue.visibility = View.GONE
    } else if (bindings.detailValue.visibility != View.VISIBLE) {
      bindings.detailValue.visibility = View.VISIBLE
    }
    applySourceStyle(bindings, state.sourceText)
    applyDriveModeStyle(bindings, state.modeKind)
    applySignalState(bindings, state.signalState, state.redDot)
    applyTfBars(bindings.tfBarViews, state.tfBars)
  }

  fun updateStatus(bindings: OverlayHudViewBindings, status: String) {
    setTextIfChanged(bindings.statusValue, status)
  }

  private fun applyDriveModeStyle(bindings: OverlayHudViewBindings, kind: String) {
    when (kind) {
      "eco" -> {
        bindings.modeValue.setTextColor(Color.WHITE)
      }

      "safe" -> {
        bindings.modeValue.setTextColor(Color.WHITE)
      }

      "sport", "fast" -> {
        bindings.modeValue.setTextColor(Color.WHITE)
      }

      else -> {
        bindings.modeValue.setTextColor(Color.WHITE)
      }
    }
  }

  private fun applySignalState(bindings: OverlayHudViewBindings, visualState: String, redDot: Boolean) {
    val color = when (visualState) {
      "red" -> Color.parseColor("#FF5A5A")
      "green" -> Color.parseColor("#34C96E")
      "yellow" -> Color.parseColor("#FFC94A")
      else -> if (redDot) Color.parseColor("#FF5A5A") else Color.parseColor("#A0FFFFFF")
    }
    val signalText = when (visualState) {
      "red" -> "적색"
      "green" -> "녹색"
      "yellow" -> "황색"
      else -> "--"
    }
    setTextIfChanged(bindings.signalValue, signalText)
    bindings.signalValue.setTextColor(Color.WHITE)
    val dot = bindings.statusDotView.background as? GradientDrawable
    dot?.setColor(color)
  }

  private fun applySourceStyle(bindings: OverlayHudViewBindings, sourceText: String) {
    val background = bindings.sourceValue.background as? GradientDrawable ?: return
    when (sourceText) {
      "COMPAT" -> {
        background.setColor(Color.parseColor("#4A3516"))
        background.setStroke(1, Color.parseColor("#66FFB347"))
        bindings.sourceValue.setTextColor(Color.parseColor("#FFF1CF"))
      }

      "FALLBACK", "FB" -> {
        background.setColor(Color.parseColor("#4E2815"))
        background.setStroke(1, Color.parseColor("#66FF9C63"))
        bindings.sourceValue.setTextColor(Color.parseColor("#FFF0E0"))
      }

      "PREVIEW" -> {
        background.setColor(Color.parseColor("#3A2552"))
        background.setStroke(1, Color.parseColor("#668F7AFF"))
        bindings.sourceValue.setTextColor(Color.WHITE)
      }

      else -> {
        background.setColor(Color.parseColor("#1D375A"))
        background.setStroke(1, Color.parseColor("#447AA7FF"))
        bindings.sourceValue.setTextColor(Color.WHITE)
      }
    }
  }

  private fun formatGearText(raw: String): String {
    val text = raw.trim().uppercase()
    return if (text.isBlank() || text == "U") "–" else text
  }

  private fun formatGapText(raw: String): String {
    val normalized = raw.trim()
    if (normalized.isBlank()) return "(--)"
    val number = Regex("(\\d+)").find(normalized)?.groupValues?.getOrNull(1)
    return if (number.isNullOrBlank()) "(--)" else "($number)"
  }

  private fun applyTfBars(views: List<View>, tfBars: Int) {
    val activeCount = tfBars.coerceIn(0, views.size)
    views.forEachIndexed { index, view ->
      val drawable = view.background as? GradientDrawable ?: return@forEachIndexed
      drawable.setColor(
          if (index < activeCount) Color.WHITE else Color.parseColor("#36FFFFFF")
      )
      view.alpha = if (index < activeCount) 1f else 0.72f
    }
  }

  private fun setTextIfChanged(view: TextView?, text: String) {
    if (view == null) return
    if (view.text?.toString() == text) return
    view.text = text
  }
}
