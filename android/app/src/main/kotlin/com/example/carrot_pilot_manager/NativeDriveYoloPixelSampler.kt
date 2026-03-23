package com.example.carrot_pilot_manager

import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.PixelCopy
import android.view.SurfaceView
import java.util.ArrayDeque

data class NativeDriveYoloPixelSamplerSnapshot(
    val pixelPathReady: Boolean = false,
    val copyInFlight: Boolean = false,
    val copyRequests: Int = 0,
    val copySuccesses: Int = 0,
    val copyFailures: Int = 0,
    val copySkippedBusy: Int = 0,
    val lastCopyResult: String = "idle",
    val sampleWidth: Int = NativeDriveYoloConfig.disabled.inputWidth,
    val sampleHeight: Int = NativeDriveYoloConfig.disabled.inputHeight,
) {
  fun toPayload(): Map<String, Any?> {
    return mapOf(
        "pixelPathReady" to pixelPathReady,
        "copyInFlight" to copyInFlight,
        "copyRequests" to copyRequests,
        "copySuccesses" to copySuccesses,
        "copyFailures" to copyFailures,
        "copySkippedBusy" to copySkippedBusy,
        "lastCopyResult" to lastCopyResult,
        "sampleWidth" to sampleWidth,
        "sampleHeight" to sampleHeight,
    )
  }
}

class NativeDriveYoloPixelSampler(
    private val surfaceView: SurfaceView,
    private val onPixelSampled: (NativeDriveYoloFrame, Bitmap, () -> Unit) -> Unit,
) {
  companion object {
    private const val MAX_BITMAP_POOL_SIZE = 3
  }

  private val workerThread = HandlerThread("CarrotYoloPixelSampler").apply { start() }
  private val workerHandler = Handler(workerThread.looper)
  private val bitmapPoolLock = Any()

  @Volatile private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
  @Volatile private var copyInFlight = false
  @Volatile private var copyRequests = 0
  @Volatile private var copySuccesses = 0
  @Volatile private var copyFailures = 0
  @Volatile private var copySkippedBusy = 0
  @Volatile private var lastCopyResult = "idle"
  private val availableBitmaps = ArrayDeque<Bitmap>()
  private var pooledBitmapWidth = 0
  private var pooledBitmapHeight = 0
  @Volatile private var released = false
  @Volatile private var lastCaptureWidth = 0
  @Volatile private var lastCaptureHeight = 0

  fun updateConfig(config: NativeDriveYoloConfig) {
    this.config = config
    if (!config.enabled) {
      copyInFlight = false
      copyRequests = 0
      copySuccesses = 0
      copyFailures = 0
      copySkippedBusy = 0
      lastCopyResult = "disabled"
      clearBitmapPool()
    }
  }

  fun trySample(frame: NativeDriveYoloFrame): Boolean {
    if (!config.enabled) {
      lastCopyResult = "disabled"
      return false
    }
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
      lastCopyResult = "pixel_copy_requires_api24"
      return false
    }
    if (surfaceView.width <= 1 || surfaceView.height <= 1) {
      lastCopyResult = "surface_not_ready"
      return false
    }
    if (copyInFlight) {
      copySkippedBusy += 1
      lastCopyResult = "copy_in_flight"
      return false
    }

    val capW = config.inputWidth.coerceAtLeast(64)
    val capH = config.inputHeight.coerceAtLeast(64)
    lastCaptureWidth = capW
    lastCaptureHeight = capH
    val bitmap = obtainBitmap(
        width = capW,
        height = capH,
    )
    copyInFlight = true
    copyRequests += 1
    lastCopyResult = "requested"

    PixelCopy.request(
        surfaceView,
        bitmap,
        { result ->
          if (result == PixelCopy.SUCCESS) {
            copySuccesses += 1
            lastCopyResult = "success"
            try {
              onPixelSampled(frame, bitmap) {
                releaseBitmapToPool(bitmap)
              }
            } catch (_: Throwable) {
              copyFailures += 1
              lastCopyResult = "pixel_sample_consume_failed"
              releaseBitmapToPool(bitmap)
            }
          } else {
            copyFailures += 1
            lastCopyResult = "pixel_copy_result_$result"
            releaseBitmapToPool(bitmap)
          }
          copyInFlight = false
        },
        workerHandler,
    )
    return true
  }

  fun snapshot(): NativeDriveYoloPixelSamplerSnapshot {
    val pixelPathReady = copySuccesses > 0
    return NativeDriveYoloPixelSamplerSnapshot(
        pixelPathReady = pixelPathReady,
        copyInFlight = copyInFlight,
        copyRequests = copyRequests,
        copySuccesses = copySuccesses,
        copyFailures = copyFailures,
        copySkippedBusy = copySkippedBusy,
        lastCopyResult = lastCopyResult,
        sampleWidth = lastCaptureWidth,
        sampleHeight = lastCaptureHeight,
    )
  }

  fun release() {
    released = true
    clearBitmapPool()
    try {
      workerThread.quitSafely()
    } catch (_: Throwable) {
    }
  }

  private fun obtainBitmap(width: Int, height: Int): Bitmap {
    synchronized(bitmapPoolLock) {
      if (pooledBitmapWidth != width || pooledBitmapHeight != height) {
        recycleAvailableBitmapsLocked()
        pooledBitmapWidth = width
        pooledBitmapHeight = height
      }
      while (availableBitmaps.isNotEmpty()) {
        val existing = availableBitmaps.removeFirst()
        if (!existing.isRecycled) {
          return existing
        }
      }
    }
    return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
  }

  private fun releaseBitmapToPool(bitmap: Bitmap) {
    if (bitmap.isRecycled) {
      return
    }
    synchronized(bitmapPoolLock) {
      if (released) {
        bitmap.recycle()
        return
      }
      if (bitmap.width != pooledBitmapWidth ||
          bitmap.height != pooledBitmapHeight ||
          availableBitmaps.size >= MAX_BITMAP_POOL_SIZE) {
        bitmap.recycle()
        return
      }
      availableBitmaps.addLast(bitmap)
    }
  }

  private fun clearBitmapPool() {
    synchronized(bitmapPoolLock) {
      recycleAvailableBitmapsLocked()
      pooledBitmapWidth = 0
      pooledBitmapHeight = 0
    }
  }

  private fun recycleAvailableBitmapsLocked() {
    while (availableBitmaps.isNotEmpty()) {
      val bitmap = availableBitmaps.removeFirst()
      if (!bitmap.isRecycled) {
        bitmap.recycle()
      }
    }
  }

}

/**
 * Computes the PixelCopy target size that preserves source aspect ratio
 * within [inputWidth]×[inputHeight] bounds.  The runtime then pads with
 * letterbox gray to fill the remaining space.
 *
 * Falls back to full [inputWidth]×[inputHeight] when source dims are unknown.
 */
internal fun letterboxCaptureSize(
    sourceWidth: Int,
    sourceHeight: Int,
    inputWidth: Int,
    inputHeight: Int,
): Pair<Int, Int> {
  if (sourceWidth <= 0 || sourceHeight <= 0 || inputWidth <= 0 || inputHeight <= 0) {
    return inputWidth to inputHeight
  }
  val scale = minOf(
      inputWidth.toFloat() / sourceWidth,
      inputHeight.toFloat() / sourceHeight,
  )
  val w = (sourceWidth * scale).toInt().coerceIn(1, inputWidth)
  val h = (sourceHeight * scale).toInt().coerceIn(1, inputHeight)
  return w to h
}
