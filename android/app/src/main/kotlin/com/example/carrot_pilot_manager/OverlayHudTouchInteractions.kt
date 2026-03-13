package com.example.carrot_pilot_manager

import android.os.Handler
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import kotlin.math.abs

internal data class OverlayHudTouchCallbacks(
    val currentLayoutParams: () -> WindowManager.LayoutParams?,
    val currentOverlaySize: () -> Pair<Int, Int>,
    val updateOverlayLayout: (WindowManager.LayoutParams) -> Unit,
    val clampOverlayPosition: (WindowManager.LayoutParams, Int, Int) -> Unit,
    val snapOverlayToNearestAnchor: (WindowManager.LayoutParams, Int, Int) -> Unit,
    val persistOverlayPosition: (WindowManager.LayoutParams) -> Unit,
    val showCloseTarget: () -> Unit,
    val hideCloseTarget: () -> Unit,
    val setCloseTargetHover: (Boolean) -> Unit,
    val isOverlayOverCloseTarget: () -> Boolean,
    val onRequestClose: () -> Unit,
    val onTap: () -> Unit,
)

internal object OverlayHudTouchInteractions {
  fun createTouchListener(
      mainHandler: Handler,
      dragTouchSlop: Int,
      dragHoldToCloseMs: Long,
      callbacks: OverlayHudTouchCallbacks,
  ): View.OnTouchListener {
    return object : View.OnTouchListener {
      private var startX = 0
      private var startY = 0
      private var touchX = 0f
      private var touchY = 0f
      private var moved = false
      private var dragByLongPress = false
      private var longPressRunnable: Runnable? = null

      private fun cancelLongPressTimer() {
        longPressRunnable?.let { mainHandler.removeCallbacks(it) }
        longPressRunnable = null
      }

      override fun onTouch(v: View?, event: MotionEvent?): Boolean {
        val e = event ?: return false
        when (e.actionMasked) {
          MotionEvent.ACTION_DOWN -> {
            val params = callbacks.currentLayoutParams() ?: return false
            startX = params.x
            startY = params.y
            touchX = e.rawX
            touchY = e.rawY
            moved = false
            dragByLongPress = false
            cancelLongPressTimer()
            longPressRunnable = Runnable {
              dragByLongPress = true
              callbacks.showCloseTarget()
              callbacks.setCloseTargetHover(false)
              v?.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            }
            mainHandler.postDelayed(longPressRunnable!!, dragHoldToCloseMs)
            return true
          }

          MotionEvent.ACTION_MOVE -> {
            val params = callbacks.currentLayoutParams() ?: return false
            val dx = (e.rawX - touchX).toInt()
            val dy = (e.rawY - touchY).toInt()
            if (!dragByLongPress) {
              if (abs(dx) > dragTouchSlop * 2 || abs(dy) > dragTouchSlop * 2) {
                moved = true
                cancelLongPressTimer()
              }
              return true
            }
            moved = true
            params.x = startX + dx
            params.y = startY + dy
            val size = callbacks.currentOverlaySize()
            callbacks.clampOverlayPosition(params, size.first, size.second)
            callbacks.updateOverlayLayout(params)
            callbacks.setCloseTargetHover(callbacks.isOverlayOverCloseTarget())
            return true
          }

          MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
            cancelLongPressTimer()
            val params = callbacks.currentLayoutParams()
            if (params != null) {
              if (dragByLongPress) {
                val shouldClose = callbacks.isOverlayOverCloseTarget()
                callbacks.hideCloseTarget()
                dragByLongPress = false
                if (shouldClose) {
                  callbacks.onRequestClose()
                  return true
                }
                val size = callbacks.currentOverlaySize()
                callbacks.clampOverlayPosition(params, size.first, size.second)
                callbacks.snapOverlayToNearestAnchor(params, size.first, size.second)
                callbacks.updateOverlayLayout(params)
                callbacks.persistOverlayPosition(params)
              } else if (e.actionMasked == MotionEvent.ACTION_UP && !moved) {
                callbacks.onTap()
              }
            }
            callbacks.hideCloseTarget()
            moved = false
            dragByLongPress = false
            return true
          }
        }
        return false
      }
    }
  }
}
