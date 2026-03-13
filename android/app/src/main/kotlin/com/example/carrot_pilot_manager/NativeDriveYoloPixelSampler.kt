package com.example.carrot_pilot_manager

import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.PixelCopy
import android.view.SurfaceView

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
    private val onPixelSampled: (NativeDriveYoloFrame, Bitmap) -> Unit,
) {
  private val workerThread = HandlerThread("CarrotYoloPixelSampler").apply { start() }
  private val workerHandler = Handler(workerThread.looper)

  @Volatile private var config: NativeDriveYoloConfig = NativeDriveYoloConfig.disabled
  @Volatile private var copyInFlight = false
  @Volatile private var copyRequests = 0
  @Volatile private var copySuccesses = 0
  @Volatile private var copyFailures = 0
  @Volatile private var copySkippedBusy = 0
  @Volatile private var lastCopyResult = "idle"
  private var reusableBitmap: Bitmap? = null
  private var reusableBitmapWidth = 0
  private var reusableBitmapHeight = 0

  fun updateConfig(config: NativeDriveYoloConfig) {
    this.config = config
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

    val bitmap = obtainBitmap(
        width = config.inputWidth.coerceAtLeast(64),
        height = config.inputHeight.coerceAtLeast(64),
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
            onPixelSampled(frame, bitmap)
          } else {
            copyFailures += 1
            lastCopyResult = "pixel_copy_result_$result"
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
        sampleWidth = config.inputWidth.coerceAtLeast(64),
        sampleHeight = config.inputHeight.coerceAtLeast(64),
    )
  }

  fun release() {
    reusableBitmap?.recycle()
    reusableBitmap = null
    try {
      workerThread.quitSafely()
    } catch (_: Throwable) {
    }
  }

  private fun obtainBitmap(width: Int, height: Int): Bitmap {
    val existing = reusableBitmap
    if (existing != null &&
        reusableBitmapWidth == width &&
        reusableBitmapHeight == height &&
        !existing.isRecycled) {
      return existing
    }
    existing?.recycle()
    reusableBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    reusableBitmapWidth = width
    reusableBitmapHeight = height
    return reusableBitmap!!
  }
}
