package com.example.carrot_pilot_manager

import android.content.Context
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.roundToInt

internal class OverlayHudCloseTargetController(
    private val context: Context,
    private val windowManagerProvider: () -> WindowManager?,
    private val overlayWindowTypeProvider: () -> Int,
) {
  private var closeTargetView: View? = null
  private var closeTargetBubble: TextView? = null
  private var closeTargetCaption: TextView? = null

  fun detach() {
    val wm = windowManagerProvider() ?: return
    val view = closeTargetView ?: return
    try {
      wm.removeView(view)
    } catch (_: Throwable) {
    }
    closeTargetView = null
    closeTargetBubble = null
    closeTargetCaption = null
  }

  fun show() {
    attachIfNeeded()
    val target = closeTargetView ?: return
    if (target.visibility == View.VISIBLE && target.alpha >= 0.99f) return
    target.visibility = View.VISIBLE
    target.animate().cancel()
    target.animate().alpha(1f).setDuration(120).start()
    setHover(false)
  }

  fun hide() {
    val target = closeTargetView ?: return
    target.animate().cancel()
    target.alpha = 0f
    target.visibility = View.GONE
    setHover(false)
  }

  fun setHover(hover: Boolean) {
    val bubble = closeTargetBubble ?: return
    val bg = bubble.background as? GradientDrawable ?: return
    if (hover) {
      bg.setColor(Color.parseColor("#D93B3B"))
      bg.setStroke(dp(2), Color.parseColor("#FFF1F1"))
      bubble.setTextColor(Color.WHITE)
      closeTargetCaption?.text = "놓으면 종료"
      closeTargetCaption?.setTextColor(Color.WHITE)
    } else {
      bg.setColor(Color.parseColor("#F4B08B"))
      bg.setStroke(dp(1), Color.parseColor("#FFD5BC"))
      bubble.setTextColor(Color.parseColor("#1A1F26"))
      closeTargetCaption?.text = "길게 눌러 이동 후 여기에 놓기"
      closeTargetCaption?.setTextColor(Color.parseColor("#E6FFFFFF"))
    }
  }

  fun isOverlayOverTarget(overlay: View?): Boolean {
    val actualOverlay = overlay ?: return false
    val target = closeTargetView ?: return false
    if (target.visibility != View.VISIBLE) return false
    if (actualOverlay.width <= 0 || actualOverlay.height <= 0) return false
    if (target.width <= 0 || target.height <= 0) return false

    val overlayLoc = IntArray(2)
    val targetLoc = IntArray(2)
    actualOverlay.getLocationOnScreen(overlayLoc)
    target.getLocationOnScreen(targetLoc)

    val centerX = overlayLoc[0] + actualOverlay.width / 2
    val centerY = overlayLoc[1] + actualOverlay.height / 2

    val rect = Rect(
        targetLoc[0],
        targetLoc[1],
        targetLoc[0] + target.width,
        targetLoc[1] + target.height,
    )
    rect.inset(-dp(64), -dp(52))
    return rect.contains(centerX, centerY)
  }

  private fun attachIfNeeded() {
    if (closeTargetView != null) return
    val wm = windowManagerProvider() ?: return

    val params = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        overlayWindowTypeProvider(),
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        android.graphics.PixelFormat.TRANSLUCENT,
    ).apply {
      gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
      y = dp(26)
    }

    val closeContainer = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER_HORIZONTAL
      visibility = View.GONE
      alpha = 0f
      setPadding(dp(20), dp(16), dp(20), dp(18))
    }

    val bubble = textView(16f, bold = true).apply {
      text = "HUD 종료"
      gravity = Gravity.CENTER
      setTextColor(Color.parseColor("#1A1F26"))
      layoutParams = LinearLayout.LayoutParams(dp(170), dp(56))
      background = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dpF(18f)
        setColor(Color.parseColor("#F4B08B"))
        setStroke(dp(1), Color.parseColor("#FFD5BC"))
      }
    }
    val caption = textView(11f, bold = true).apply {
      text = "길게 눌러 이동 후 여기에 놓기"
      setTextColor(Color.parseColor("#E6FFFFFF"))
      setPadding(0, dp(5), 0, 0)
    }
    closeContainer.addView(bubble)
    closeContainer.addView(caption)

    try {
      wm.addView(closeContainer, params)
      closeTargetView = closeContainer
      closeTargetBubble = bubble
      closeTargetCaption = caption
    } catch (_: Throwable) {
    }
  }

  private fun textView(sizeSp: Float, bold: Boolean): TextView {
    return TextView(context).apply {
      textSize = sizeSp
      typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
      includeFontPadding = false
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
