package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.roundToInt

internal class OverlayHudViewFactory(
    private val context: Context,
) {
  fun build(profile: OverlayHudLayoutProfile): OverlayHudBuiltView {
    val tfBarViews = mutableListOf<View>()
    val card = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      minimumWidth = dp(profile.minWidthDp)
      minimumHeight = dp(profile.minHeightDp)
      setPadding(
          dp(profile.horizontalPaddingDp),
          dp(profile.verticalPaddingDp),
          dp(profile.horizontalPaddingDp),
          dp(profile.verticalPaddingDp),
      )
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(profile.radiusDp)
        setColor(Color.parseColor("#D9010A18"))
        setStroke(dp(1), Color.parseColor("#66FFFFFF"))
      }
      elevation = dpF(6f)
    }

    val topRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    val statusDotView = View(context).apply {
      layoutParams = LinearLayout.LayoutParams(dp(10), dp(10))
      background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.parseColor("#55FFFFFF"))
      }
    }
    topRow.addView(statusDotView)
    topRow.addView(space(profile.sectionGapDp))
    val modeValue = textView(profile.bodySp, bold = true).apply {
      text = "NORM"
      setTextColor(Color.parseColor("#1A1F26"))
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(profile.radiusDp - 8f)
        setColor(Color.parseColor("#E7EEF7"))
      }
      setPadding(dp(10), dp(4), dp(10), dp(4))
    }
    topRow.addView(modeValue)
    topRow.addView(space(profile.sectionGapDp))
    val sourceValue = textView(profile.smallSp, bold = true).apply {
      text = "LIVE"
      setTextColor(Color.WHITE)
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(profile.radiusDp - 8f)
        setColor(Color.parseColor("#1D375A"))
        setStroke(dp(1), Color.parseColor("#447AA7FF"))
      }
      setPadding(dp(10), dp(4), dp(10), dp(4))
    }
    topRow.addView(sourceValue)
    topRow.addView(LinearLayout(context).apply {
      layoutParams = LinearLayout.LayoutParams(0, 1, 1f)
    })
    val gpsValue = textView(profile.smallSp, bold = true).apply {
      text = "GPS --"
      setTextColor(Color.parseColor("#A0FFFFFF"))
    }
    topRow.addView(gpsValue)
    card.addView(topRow)
    card.addView(spaceVertical(profile.sectionGapDp))

    val metricsRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    val cpuMetric = createMetricCell(profile, "CPU", "--°C", "#2A7B54")
    val metricCpuValue = cpuMetric.second
    val memMetric = createMetricCell(profile, "MEM", "--%", "#2A4D7B")
    val metricMemValue = memMetric.second
    val voltMetric = createMetricCell(profile, "VOLT", "--.-V", "#7A5A24")
    val metricVoltLabel = voltMetric.first.findViewWithTag<TextView>("label")
    val metricVoltValue = voltMetric.second

    metricsRow.addView(cpuMetric.first)
    metricsRow.addView(space(profile.sectionGapDp - 2))
    metricsRow.addView(memMetric.first)
    metricsRow.addView(space(profile.sectionGapDp - 2))
    metricsRow.addView(voltMetric.first)
    metricsRow.visibility = if (profile.showMetricsRow) View.VISIBLE else View.GONE
    card.addView(metricsRow)
    if (profile.showMetricsRow) {
      card.addView(spaceVertical(profile.sectionGapDp))
    }

    val contentContainer = LinearLayout(context).apply {
      orientation = if (profile.wide) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
      gravity = Gravity.TOP
    }

    val leftColumn = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.3f)
    }
    val speedValue = textView(profile.speedSp, bold = true).apply {
      text = "--"
      setTextColor(Color.WHITE)
      minWidth = dp(72)
      gravity = Gravity.START
    }
    val setSpeedValue = textView(profile.secondarySp, bold = true).apply {
      text = "SET --"
      setTextColor(Color.parseColor("#22FF61"))
    }
    leftColumn.addView(speedValue)
    leftColumn.addView(spaceVertical(4))
    leftColumn.addView(setSpeedValue)

    val centerColumn = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.START
      layoutParams = if (profile.wide) {
        LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.15f)
      } else {
        LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        )
      }
    }
    val tempSourceValue = textView(profile.bodySp, bold = true).apply {
      text = "eco"
      setTextColor(Color.parseColor("#22FF61"))
    }
    val tempSpeedValue = textView(profile.secondarySp + 2f, bold = true).apply {
      text = "--"
      setTextColor(Color.parseColor("#22FF61"))
    }
    val limitValue = textView(profile.bodySp, bold = true).apply {
      text = "LIMIT --"
      setTextColor(Color.WHITE)
    }
    centerColumn.addView(tempSourceValue)
    centerColumn.addView(spaceVertical(2))
    centerColumn.addView(tempSpeedValue)
    centerColumn.addView(spaceVertical(8))
    centerColumn.addView(limitValue)

    val rightColumn = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.END
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 0.82f)
    }
    val gearValue = textView(profile.gearSp, bold = true).apply {
      text = "U"
      setTextColor(Color.WHITE)
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(profile.radiusDp - 8f)
        setStroke(dp(1), Color.parseColor("#88FFFFFF"))
      }
      setPadding(dp(10), dp(2), dp(10), dp(2))
    }
    val barWrap = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.END or Gravity.CENTER_VERTICAL
    }
    repeat(4) { idx ->
      val bar = View(context).apply {
        layoutParams = LinearLayout.LayoutParams(dp(12), dp(8)).also {
          if (idx > 0) it.marginStart = dp(3)
        }
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = dpF(3f)
          setColor(Color.parseColor("#505862"))
        }
        alpha = 0.55f
      }
      tfBarViews.add(bar)
      barWrap.addView(bar)
    }
    rightColumn.addView(gearValue)
    rightColumn.addView(spaceVertical(12))
    rightColumn.addView(barWrap)

    if (profile.wide) {
      contentContainer.addView(leftColumn)
      contentContainer.addView(space(profile.sectionGapDp))
      contentContainer.addView(centerColumn)
      contentContainer.addView(space(profile.sectionGapDp))
      contentContainer.addView(rightColumn)
    } else {
      val topContentRow = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.TOP
      }
      topContentRow.addView(leftColumn)
      topContentRow.addView(space(profile.sectionGapDp))
      topContentRow.addView(rightColumn)
      contentContainer.addView(topContentRow)
      contentContainer.addView(spaceVertical(profile.sectionGapDp))
      contentContainer.addView(centerColumn)
    }
    card.addView(contentContainer)
    card.addView(spaceVertical(profile.sectionGapDp))

    val statusValue = textView(profile.smallSp, bold = false).apply {
      text = "대기 중"
      setTextColor(Color.parseColor("#A0FFFFFF"))
    }
    card.addView(statusValue)
    card.addView(spaceVertical(2))
    val detailValue = textView(profile.smallSp - 0.5f, bold = false).apply {
      text = ""
      setTextColor(Color.parseColor("#70FFFFFF"))
      visibility = if (profile.showDetailLine) View.VISIBLE else View.GONE
    }
    card.addView(detailValue)

    return OverlayHudBuiltView(
        rootView = card,
        bindings = OverlayHudViewBindings(
            metricCpuValue = metricCpuValue,
            metricMemValue = metricMemValue,
            metricVoltLabel = metricVoltLabel,
            metricVoltValue = metricVoltValue,
            sourceValue = sourceValue,
            statusDotView = statusDotView,
            speedValue = speedValue,
            setSpeedValue = setSpeedValue,
            tempSourceValue = tempSourceValue,
            tempSpeedValue = tempSpeedValue,
            gearValue = gearValue,
            modeValue = modeValue,
            limitValue = limitValue,
            gpsValue = gpsValue,
            statusValue = statusValue,
            detailValue = detailValue,
            tfBarViews = tfBarViews,
        ),
    )
  }

  private fun createMetricCell(
      profile: OverlayHudLayoutProfile,
      label: String,
      value: String,
      backgroundColorHex: String,
  ): Pair<LinearLayout, TextView> {
    val labelView = textView(profile.metricLabelSp, bold = true).apply {
      text = label
      tag = "label"
      setTextColor(Color.parseColor("#D8FFFFFF"))
      gravity = Gravity.CENTER_HORIZONTAL
    }
    val valueView = textView(profile.metricValueSp, bold = true).apply {
      text = value
      setTextColor(Color.WHITE)
      gravity = Gravity.CENTER_HORIZONTAL
    }
    val cell = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      minimumWidth = dp(profile.metricCellMinWidthDp)
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(profile.radiusDp - 10f)
        setColor(Color.parseColor(backgroundColorHex))
      }
      setPadding(dp(8), dp(4), dp(8), dp(4))
      addView(labelView)
      addView(valueView)
    }
    return Pair(cell, valueView)
  }

  private fun textView(sizeSp: Float, bold: Boolean): TextView {
    return TextView(context).apply {
      textSize = sizeSp
      typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      includeFontPadding = false
    }
  }

  private fun space(widthDp: Int): View {
    return View(context).apply {
      layoutParams = LinearLayout.LayoutParams(dp(widthDp), 1)
    }
  }

  private fun spaceVertical(heightDp: Int): View {
    return View(context).apply {
      layoutParams = LinearLayout.LayoutParams(1, dp(heightDp))
    }
  }

  private fun dp(value: Int): Int {
    val density = context.resources.displayMetrics.density
    return (value * density).roundToInt()
  }

  private fun dpF(value: Float): Float {
    val density = context.resources.displayMetrics.density
    return value * density
  }
}
