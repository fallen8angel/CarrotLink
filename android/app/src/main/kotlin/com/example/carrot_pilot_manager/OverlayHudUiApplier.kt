package com.example.carrot_pilot_manager

import android.graphics.Color
import android.graphics.drawable.GradientDrawable
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
    setTextIfChanged(bindings.gearValue, state.gearText)
    setTextIfChanged(bindings.gpsValue, state.gpsText)
    setTextIfChanged(bindings.tempSourceValue, state.tempSourceText)
    setTextIfChanged(bindings.tempSpeedValue, state.tempSpeedText)
    setTextIfChanged(bindings.limitValue, state.limitText)
    setTextIfChanged(bindings.modeValue, state.modeText)
    setTextIfChanged(bindings.statusValue, state.statusText)

    bindings.tempSpeedValue.setTextColor(
        if (state.tempIsDecel) Color.parseColor("#FF9C2A") else Color.parseColor("#22FF61"),
    )
    bindings.limitValue.setTextColor(if (state.limitOver) Color.parseColor("#FF5050") else Color.WHITE)
    bindings.gpsValue.setTextColor(if (state.gpsOk) Color.WHITE else Color.parseColor("#A0FFFFFF"))
    applyDriveModeStyle(bindings, state.modeKind)
    applyTfBars(bindings, state.tfBars)
    applySignalState(bindings, state.signalState, state.redDot)
  }

  fun updateStatus(bindings: OverlayHudViewBindings, status: String) {
    setTextIfChanged(bindings.statusValue, status)
  }

  private fun applyDriveModeStyle(bindings: OverlayHudViewBindings, kind: String) {
    val bg = bindings.modeValue.background as? GradientDrawable ?: return
    when (kind) {
      "eco" -> {
        bg.setColor(Color.parseColor("#10C248"))
        bindings.modeValue.setTextColor(Color.WHITE)
      }

      "safe" -> {
        bg.setColor(Color.parseColor("#FF9C2A"))
        bindings.modeValue.setTextColor(Color.parseColor("#1A1F26"))
      }

      "sport", "fast" -> {
        bg.setColor(Color.parseColor("#FF2A2A"))
        bindings.modeValue.setTextColor(Color.WHITE)
      }

      else -> {
        bg.setColor(Color.parseColor("#E7EEF7"))
        bindings.modeValue.setTextColor(Color.parseColor("#1A1F26"))
      }
    }
  }

  private fun applySignalState(bindings: OverlayHudViewBindings, visualState: String, redDot: Boolean) {
    val color = when (visualState) {
      "red" -> Color.parseColor("#FF5A5A")
      "green" -> Color.parseColor("#22FF61")
      "yellow" -> Color.parseColor("#FFB347")
      else -> if (redDot) Color.parseColor("#FF5A5A") else Color.parseColor("#A0FFFFFF")
    }
    bindings.statusValue.setTextColor(color)
    val dot = bindings.statusDotView.background as? GradientDrawable
    dot?.setColor(color)
  }

  private fun applyTfBars(bindings: OverlayHudViewBindings, activeBars: Int) {
    bindings.tfBarViews.forEachIndexed { index, view ->
      val on = index >= (4 - activeBars)
      val bg = view.background as? GradientDrawable ?: return@forEachIndexed
      bg.setColor(if (on) Color.parseColor("#1CFF57") else Color.parseColor("#505862"))
      view.alpha = if (on) 1.0f else 0.55f
    }
  }

  private fun setTextIfChanged(view: TextView?, text: String) {
    if (view == null) return
    if (view.text?.toString() == text) return
    view.text = text
  }
}
