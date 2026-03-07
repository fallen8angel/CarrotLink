package com.example.carrot_pilot_manager

internal data class OverlayHudLayoutProfile(
    val wide: Boolean,
    val minWidthDp: Int,
    val minHeightDp: Int,
    val horizontalPaddingDp: Int,
    val verticalPaddingDp: Int,
    val radiusDp: Float,
    val metricLabelSp: Float,
    val metricValueSp: Float,
    val speedSp: Float,
    val secondarySp: Float,
    val bodySp: Float,
    val smallSp: Float,
    val gearSp: Float,
    val metricCellMinWidthDp: Int,
    val sectionGapDp: Int,
    val showMetricsRow: Boolean,
    val showDetailLine: Boolean,
)

internal data class OverlayHudUiState(
    val sourceText: String,
    val detailText: String,
    val cpuText: String,
    val memText: String,
    val auxMetricLabel: String,
    val auxMetricValue: String,
    val speedText: String,
    val setSpeedText: String,
    val gearText: String,
    val gpsText: String,
    val gpsOk: Boolean,
    val tempSourceText: String,
    val tempSpeedText: String,
    val tempIsDecel: Boolean,
    val limitText: String,
    val limitOver: Boolean,
    val modeText: String,
    val modeKind: String,
    val tfBars: Int,
    val signalState: String,
    val redDot: Boolean,
    val statusText: String,
)

internal enum class OverlayHudPayloadKind {
  Semantic,
  Legacy,
}

internal data class OverlayHudParseContext(
    val hostIp: String?,
    val fallbackCpuTempC: Double?,
    val fallbackMemPct: Double?,
    val fallbackDiskPct: Double?,
)

internal data class OverlayHudMetricPatch(
    val cpuTempC: Double? = null,
    val memPct: Double? = null,
    val diskPct: Double? = null,
)

internal data class OverlayHudParseResult(
    val kind: OverlayHudPayloadKind,
    val uiState: OverlayHudUiState,
    val metricPatch: OverlayHudMetricPatch = OverlayHudMetricPatch(),
    val hostLabel: String? = null,
)
