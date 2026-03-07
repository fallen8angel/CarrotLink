package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Rect
import android.os.Build
import android.view.View
import android.view.WindowManager
import kotlin.math.roundToInt

internal class OverlayHudPositionController(
    private val context: Context,
    private val windowManagerProvider: () -> WindowManager?,
    private val prefsName: String,
    private val prefXKey: String,
    private val prefYKey: String,
) {
  fun defaultOverlayX(): Int = dp(10)

  fun defaultOverlayY(): Int = dp(72)

  fun persistOverlayPosition(params: WindowManager.LayoutParams) {
    try {
      prefs().edit()
          .putInt(prefXKey, params.x)
          .putInt(prefYKey, params.y)
          .apply()
    } catch (_: Throwable) {
    }
  }

  fun restoreOverlayPosition(params: WindowManager.LayoutParams) {
    try {
      val pref = prefs()
      params.x = pref.getInt(prefXKey, defaultOverlayX())
      params.y = pref.getInt(prefYKey, defaultOverlayY())
    } catch (_: Throwable) {
      params.x = defaultOverlayX()
      params.y = defaultOverlayY()
    }
  }

  fun currentOverlaySize(view: View?): Pair<Int, Int> {
    if (view == null) return Pair(dp(260), dp(180))
    if (view.width <= 0 || view.height <= 0) {
      val spec = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
      view.measure(spec, spec)
      view.layout(0, 0, view.measuredWidth, view.measuredHeight)
    }
    var width = if (view.width > 0) view.width else view.measuredWidth
    var height = if (view.height > 0) view.height else view.measuredHeight
    if (width < dp(120) || height < dp(120)) {
      val bounds = screenBounds()
      val wSpec = View.MeasureSpec.makeMeasureSpec(
          (bounds.width() - dp(12)).coerceAtLeast(dp(120)),
          View.MeasureSpec.AT_MOST
      )
      val hSpec = View.MeasureSpec.makeMeasureSpec(
          (bounds.height() - dp(12)).coerceAtLeast(dp(120)),
          View.MeasureSpec.AT_MOST
      )
      view.measure(wSpec, hSpec)
      view.layout(0, 0, view.measuredWidth, view.measuredHeight)
      width = if (view.width > 0) view.width else view.measuredWidth
      height = if (view.height > 0) view.height else view.measuredHeight
    }
    return Pair(width.coerceAtLeast(dp(120)), height.coerceAtLeast(dp(120)))
  }

  fun screenBounds(): Rect {
    val wm = windowManagerProvider()
    if (wm == null) {
      val dm = context.resources.displayMetrics
      return Rect(0, 0, dm.widthPixels, dm.heightPixels)
    }
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      wm.currentWindowMetrics.bounds
    } else {
      val dm = context.resources.displayMetrics
      Rect(0, 0, dm.widthPixels, dm.heightPixels)
    }
  }

  fun clampOverlayPosition(
      params: WindowManager.LayoutParams,
      viewWidth: Int,
      viewHeight: Int,
  ): Boolean {
    val bounds = screenBounds()
    val safeMargin = dp(6)

    val minX = safeMargin
    val minY = safeMargin
    val maxX = (bounds.width() - viewWidth - safeMargin).coerceAtLeast(minX)
    val maxY = (bounds.height() - viewHeight - safeMargin).coerceAtLeast(minY)

    val clampedX = params.x.coerceIn(minX, maxX)
    val clampedY = params.y.coerceIn(minY, maxY)
    val changed = clampedX != params.x || clampedY != params.y
    if (changed) {
      params.x = clampedX
      params.y = clampedY
    }
    return changed
  }

  fun snapOverlayToNearestAnchor(
      params: WindowManager.LayoutParams,
      viewWidth: Int,
      viewHeight: Int,
  ): Boolean {
    val bounds = screenBounds()
    val safeMargin = dp(6)
    val minX = safeMargin
    val minY = safeMargin
    val maxX = (bounds.width() - viewWidth - safeMargin).coerceAtLeast(minX)
    val maxY = (bounds.height() - viewHeight - safeMargin).coerceAtLeast(minY)
    val centerX = ((minX + maxX) / 2.0).roundToInt()
    val centerY = ((minY + maxY) / 2.0).roundToInt()

    val anchors = arrayOf(
        Pair(minX, minY),
        Pair(centerX, minY),
        Pair(maxX, minY),
        Pair(minX, centerY),
        Pair(centerX, centerY),
        Pair(maxX, centerY),
        Pair(minX, maxY),
        Pair(centerX, maxY),
        Pair(maxX, maxY),
    )

    var best = anchors[0]
    var bestDist = Long.MAX_VALUE
    for (anchor in anchors) {
      val dx = (params.x - anchor.first).toLong()
      val dy = (params.y - anchor.second).toLong()
      val dist = dx * dx + dy * dy
      if (dist < bestDist) {
        bestDist = dist
        best = anchor
      }
    }

    val changed = params.x != best.first || params.y != best.second
    if (changed) {
      params.x = best.first
      params.y = best.second
    }
    return changed
  }

  fun ensureOverlayInBounds(
      view: View?,
      params: WindowManager.LayoutParams?,
      forceApply: Boolean,
      persistIfChanged: Boolean,
  ) {
    val actualView = view ?: return
    val actualParams = params ?: return
    val (width, height) = currentOverlaySize(actualView)
    val changed = clampOverlayPosition(actualParams, width, height)
    if (!changed && !forceApply) return
    try {
      windowManagerProvider()?.updateViewLayout(actualView, actualParams)
      if (persistIfChanged && (changed || forceApply)) {
        persistOverlayPosition(actualParams)
      }
    } catch (_: Throwable) {
    }
  }

  private fun prefs() = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

  private fun dp(value: Int): Int {
    val density = context.resources.displayMetrics.density
    return (value * density).roundToInt()
  }
}
