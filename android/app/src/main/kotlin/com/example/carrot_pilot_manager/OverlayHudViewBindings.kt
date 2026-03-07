package com.example.carrot_pilot_manager

import android.view.View
import android.widget.LinearLayout
import android.widget.TextView

internal data class OverlayHudBuiltView(
    val rootView: LinearLayout,
    val bindings: OverlayHudViewBindings,
)

internal data class OverlayHudViewBindings(
    val metricCpuValue: TextView,
    val metricMemValue: TextView,
    val metricVoltLabel: TextView,
    val metricVoltValue: TextView,
    val sourceValue: TextView,
    val statusDotView: View,
    val speedValue: TextView,
    val setSpeedValue: TextView,
    val tempSourceValue: TextView,
    val tempSpeedValue: TextView,
    val gearValue: TextView,
    val modeValue: TextView,
    val limitValue: TextView,
    val gpsValue: TextView,
    val statusValue: TextView,
    val detailValue: TextView,
    val tfBarViews: List<View>,
)
