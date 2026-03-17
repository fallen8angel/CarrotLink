package com.example.carrot_pilot_manager

data class NativeDriveYoloConfig(
    val enabled: Boolean = false,
    val unsafeRuntimeEnabled: Boolean = false,
    val showBoxes: Boolean = false,
    val showLabels: Boolean = false,
    val showTrafficLights: Boolean = false,
    val showStats: Boolean = false,
    val runtimeBackend: String = DEFAULT_RUNTIME_BACKEND,
    val modelVariant: String = DEFAULT_MODEL_VARIANT,
    val camera: String = DEFAULT_CAMERA,
    val sourceWidth: Int = DEFAULT_SOURCE_WIDTH,
    val sourceHeight: Int = DEFAULT_SOURCE_HEIGHT,
    val inputWidth: Int = DEFAULT_INPUT_WIDTH,
    val inputHeight: Int = DEFAULT_INPUT_HEIGHT,
    val samplePeriodMs: Int = DEFAULT_SAMPLE_PERIOD_MS,
) {
  companion object {
    const val DEFAULT_RUNTIME_BACKEND = "executorch_xnnpack"
    const val DEFAULT_MODEL_VARIANT = "yolo26n"
    private const val DEFAULT_CAMERA = "road"
    private const val DEFAULT_SOURCE_WIDTH = 1928
    private const val DEFAULT_SOURCE_HEIGHT = 1208
    private const val DEFAULT_INPUT_WIDTH = 416
    private const val DEFAULT_INPUT_HEIGHT = 416
    private const val DEFAULT_SAMPLE_PERIOD_MS = 200

    val disabled = NativeDriveYoloConfig()

    fun fromPayload(payload: Map<String, Any?>?): NativeDriveYoloConfig {
      if (payload == null) return disabled
      val parsed =
          NativeDriveYoloConfig(
          enabled = readBoolean(payload, "yoloEnabled"),
          unsafeRuntimeEnabled = readBoolean(payload, "unsafeRuntimeEnabled"),
          showBoxes = readBoolean(payload, "yoloBoxes"),
          showLabels = readBoolean(payload, "yoloLabels"),
          showTrafficLights = readBoolean(payload, "yoloTrafficLights"),
          showStats = readBoolean(payload, "yoloStats"),
          runtimeBackend =
              readString(payload, "runtimeBackend", DEFAULT_RUNTIME_BACKEND),
          modelVariant = readString(payload, "modelVariant", DEFAULT_MODEL_VARIANT),
          camera = readString(payload, "camera", DEFAULT_CAMERA),
          sourceWidth = readInt(payload, "sourceWidth", DEFAULT_SOURCE_WIDTH),
          sourceHeight = readInt(payload, "sourceHeight", DEFAULT_SOURCE_HEIGHT),
          inputWidth = readInt(payload, "inputWidth", DEFAULT_INPUT_WIDTH),
          inputHeight = readInt(payload, "inputHeight", DEFAULT_INPUT_HEIGHT),
          samplePeriodMs =
              readInt(payload, "samplePeriodMs", DEFAULT_SAMPLE_PERIOD_MS),
      )
      return if (parsed.enabled) {
        parsed
      } else {
        parsed.copy(
            unsafeRuntimeEnabled = false,
            showBoxes = false,
            showLabels = false,
            showTrafficLights = false,
            showStats = false,
        )
      }
    }

    private fun readBoolean(payload: Map<String, Any?>, key: String): Boolean {
      return when (val value = payload[key]) {
        is Boolean -> value
        is Number -> value.toInt() != 0
        is String -> {
          when (value.trim().lowercase()) {
            "1", "true", "yes", "on" -> true
            else -> false
          }
        }
        else -> false
      }
    }

    private fun readString(payload: Map<String, Any?>, key: String, fallback: String): String {
      val value = payload[key]?.toString()?.trim().orEmpty()
      return if (value.isEmpty()) fallback else value
    }

    private fun readInt(payload: Map<String, Any?>, key: String, fallback: Int): Int {
      return when (val value = payload[key]) {
        is Int -> value
        is Long -> value.toInt()
        is Float -> value.toInt()
        is Double -> value.toInt()
        is Number -> value.toInt()
        is String -> value.toIntOrNull() ?: fallback
        else -> fallback
      }
    }
  }

  fun toPayload(): Map<String, Any?> {
    return mapOf(
        "yoloEnabled" to enabled,
        "unsafeRuntimeEnabled" to unsafeRuntimeEnabled,
        "yoloBoxes" to showBoxes,
        "yoloLabels" to showLabels,
        "yoloTrafficLights" to showTrafficLights,
        "yoloStats" to showStats,
        "runtimeBackend" to runtimeBackend,
        "modelVariant" to modelVariant,
        "camera" to camera,
        "sourceWidth" to sourceWidth,
        "sourceHeight" to sourceHeight,
        "inputWidth" to inputWidth,
        "inputHeight" to inputHeight,
        "samplePeriodMs" to samplePeriodMs,
    )
  }
}
