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
        setColor(Color.parseColor("#E1134A32"))
        setStroke(dp(1), Color.parseColor("#48FFFFFF"))
      }
      elevation = dpF(6f)
    }

    val metricsRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    val cpuMetric = createMetricCell(profile, "CPU", "--°C", "#CC145B3C")
    val metricCpuValue = cpuMetric.second
    val memMetric = createMetricCell(profile, "MEM", "--%", "#CC145B3C")
    val metricMemValue = memMetric.second
    val voltMetric = createMetricCell(profile, "VOLT", "--.-V", "#CC145B3C")
    val metricVoltLabel = voltMetric.first.findViewWithTag<TextView>("label")
    val metricVoltValue = voltMetric.second

    cpuMetric.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    memMetric.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    voltMetric.first.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    metricsRow.addView(cpuMetric.first)
    metricsRow.addView(space(profile.sectionGapDp - 3))
    metricsRow.addView(memMetric.first)
    metricsRow.addView(space(profile.sectionGapDp - 3))
    metricsRow.addView(voltMetric.first)
    card.addView(metricsRow)
    card.addView(spaceVertical(profile.sectionGapDp))

    val leftCard = createContentCard(profile).apply {
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.6f)
    }
    val leftLabel = textView(profile.smallSp, bold = true).apply {
      text = "현재속도"
      setTextColor(Color.parseColor("#66FFFFFF"))
    }
    val speedValue = textView(profile.speedSp, bold = true).apply {
      text = "--"
      setTextColor(Color.WHITE)
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
    }
    leftCard.addView(leftLabel)
    leftCard.addView(LinearLayout(context).apply {
      layoutParams = LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.MATCH_PARENT,
          0,
          1f,
      )
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
      addView(speedValue)
    })

    val rightCard = createContentCard(profile).apply {
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
    }
    val headerRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    val setSpeedLabel = textView(profile.smallSp, bold = true).apply {
      text = "설정속도"
      setTextColor(Color.parseColor("#66FFFFFF"))
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }
    headerRow.addView(setSpeedLabel)
    val setSpeedValue = textView(profile.secondarySp + 2f, bold = true).apply {
      text = "--"
      setTextColor(Color.WHITE)
    }
    val tempRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    val tempSourceValue = textView(profile.bodySp - 1f, bold = true).apply {
      text = "TEMP"
      setTextColor(Color.WHITE)
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }
    val tempSpeedValue = textView(profile.bodySp - 1f, bold = true).apply {
      text = "--"
      setTextColor(Color.WHITE)
      gravity = Gravity.END
    }
    tempRow.addView(tempSourceValue)
    tempRow.addView(tempSpeedValue)
    val supportRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    val gapCluster = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }
    val tfBarRow = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }
    repeat(4) { index ->
      val bar = View(context).apply {
        layoutParams = LinearLayout.LayoutParams(
            dp(if (profile.metaMode == OverlayHudMetaMode.Tiny) 10 else 12),
            dp(if (profile.metaMode == OverlayHudMetaMode.Tiny) 4 else 5),
        ).also { params ->
          if (index > 0) params.marginStart = dp(2)
        }
        background = GradientDrawable().apply {
          shape = GradientDrawable.RECTANGLE
          cornerRadius = dpF(99f)
          setColor(Color.parseColor("#36FFFFFF"))
        }
      }
      tfBarViews.add(bar)
      tfBarRow.addView(bar)
    }
    val gapValue = textView(profile.smallSp, bold = true).apply {
      text = "(--)"
      setTextColor(Color.parseColor("#D6FFFFFF"))
    }
    gapCluster.addView(tfBarRow)
    gapCluster.addView(space(6))
    gapCluster.addView(gapValue)
    val gearCluster = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      val label = textView(profile.smallSp - 1f, bold = true).apply {
        text = "GEAR"
        setTextColor(Color.parseColor("#90FFFFFF"))
      }
      val value = textView(profile.secondarySp - 2f, bold = true).apply {
        text = "–"
        setTextColor(Color.WHITE)
        tag = "gearValueInner"
      }
      addView(label)
      addView(spaceVertical(2))
      addView(value)
    }
    supportRow.addView(gapCluster)
    supportRow.addView(gearCluster)
    rightCard.addView(headerRow)
    rightCard.addView(spaceVertical(4))
    rightCard.addView(setSpeedValue)
    rightCard.addView(spaceVertical(8))
    rightCard.addView(tempRow)
    rightCard.addView(spaceVertical(4))
    rightCard.addView(supportRow)

    val contentContainer = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.TOP
      addView(leftCard)
      addView(space(profile.sectionGapDp))
      addView(rightCard)
    }
    card.addView(contentContainer)
    card.addView(spaceVertical(profile.sectionGapDp))

    val bottomStrip = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(profile.radiusDp - 10f)
        setColor(Color.parseColor("#D7145B3C"))
        setStroke(dp(1), Color.parseColor("#36FFFFFF"))
      }
      setPadding(dp(12), dp(6), dp(12), dp(6))
    }
    val statusDotView = View(context).apply {
      layoutParams = LinearLayout.LayoutParams(dp(8), dp(8))
      background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.parseColor("#55FFFFFF"))
      }
    }
    val modeValue = textView(profile.bodySp - 1f, bold = true).apply {
      text = "일반"
      setTextColor(Color.WHITE)
    }
    val slashOne = textView(profile.bodySp - 1f, bold = false).apply {
      text = " / "
      setTextColor(Color.parseColor("#66FFFFFF"))
    }
    val limitValue = textView(profile.bodySp - 1f, bold = true).apply {
      text = "LIMIT --"
      setTextColor(Color.WHITE)
    }
    val slashTwo = textView(profile.bodySp - 1f, bold = false).apply {
      text = " / "
      setTextColor(Color.parseColor("#66FFFFFF"))
    }
    val connectivityValue = textView(profile.bodySp - 1f, bold = true).apply {
      text = ""
      setTextColor(Color.WHITE)
    }
    val centerStrip = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
      addView(modeValue)
      addView(slashOne)
      addView(limitValue)
      addView(slashTwo)
      addView(connectivityValue)
    }
    val signalValue = textView(profile.smallSp, bold = true).apply {
      text = "--"
      setTextColor(Color.parseColor("#66FFFFFF"))
      gravity = Gravity.END
    }
    bottomStrip.addView(statusDotView)
    bottomStrip.addView(space(8))
    bottomStrip.addView(centerStrip)
    bottomStrip.addView(signalValue)
    card.addView(bottomStrip)

    val sourceValue = textView(profile.smallSp, bold = true).apply { visibility = View.GONE }
    val gpsValue = textView(profile.smallSp, bold = true).apply { visibility = View.GONE }
    val statusValue = textView(profile.smallSp, bold = false).apply { visibility = View.GONE }
    val detailValue = textView(profile.smallSp - 0.5f, bold = false).apply { visibility = View.GONE }

    return OverlayHudBuiltView(
        rootView = card,
        bindings = OverlayHudViewBindings(
            metricCpuValue = metricCpuValue,
            metricMemValue = metricMemValue,
            metricVoltLabel = metricVoltLabel,
            metricVoltValue = metricVoltValue,
            statusDotView = statusDotView,
            speedValue = speedValue,
            setSpeedValue = setSpeedValue,
            tempSourceValue = tempSourceValue,
            tempSpeedValue = tempSpeedValue,
            gapValue = gapValue,
            gearValue = gearCluster.findViewWithTag("gearValueInner"),
            modeValue = modeValue,
            limitValue = limitValue,
            connectivityValue = connectivityValue,
            signalValue = signalValue,
            sourceValue = sourceValue,
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
      setTextColor(Color.WHITE)
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
        setStroke(dp(1), Color.parseColor("#36FFFFFF"))
      }
      setPadding(dp(8), dp(4), dp(8), dp(4))
      addView(labelView)
      addView(valueView)
    }
    return Pair(cell, valueView)
  }

  private fun createContentCard(profile: OverlayHudLayoutProfile): LinearLayout {
    return LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(profile.radiusDp - 8f)
        setColor(Color.parseColor("#D9114A31"))
        setStroke(dp(1), Color.parseColor("#2AFFFFFF"))
      }
      setPadding(dp(12), dp(10), dp(12), dp(10))
    }
  }

  private fun textView(sizeSp: Float, bold: Boolean): TextView {
    return TextView(context).apply {
      textSize = sizeSp
      typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      includeFontPadding = false
      setTextColor(Color.WHITE)
      setShadowLayer(dpF(1.8f), 0f, dpF(0.8f), Color.parseColor("#F0000000"))
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
