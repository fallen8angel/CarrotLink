package com.example.carrot_pilot_manager

data class NativeDriveYoloFrame(
    val frameId: Int,
    val ptsUs: Long,
    val camera: String,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val fpsHint: Float,
) {
  fun toPayload(): Map<String, Any?> {
    return mapOf(
        "frameId" to frameId,
        "ptsUs" to ptsUs,
        "camera" to camera,
        "sourceWidth" to sourceWidth,
        "sourceHeight" to sourceHeight,
        "fpsHint" to fpsHint,
    )
  }
}
