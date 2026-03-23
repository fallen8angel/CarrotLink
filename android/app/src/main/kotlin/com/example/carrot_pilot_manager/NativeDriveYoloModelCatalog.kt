package com.example.carrot_pilot_manager

internal data class NativeDriveYoloModelVariantDescriptor(
    val wireValue: String,
    val family: String,
    val aliases: List<String>,
    // Candidate base names for .pte lookup (ExecuTorch path).
    val candidateBaseNames: List<String>,
    // Candidate base names for .tflite lookup (LiteRT path).
    // If null, the LiteRT locator falls back to candidateBaseNames.
    val candidateTfliteBaseNames: List<String>? = null,
    val suggestedLiteRtWireValue: String? = null,
) {
  val isLiteRt: Boolean
    get() = family == "litert"
}

internal object NativeDriveYoloModelCatalog {
  private val generic26n =
      NativeDriveYoloModelVariantDescriptor(
          wireValue = "yolo26n",
          family = "generic",
          aliases = listOf("yolo26n"),
          candidateBaseNames = listOf("yolo26n"),
          // ultralytics half=True export produces _float16 suffix; _fp16 is our convention
          candidateTfliteBaseNames = listOf("yolo26n_float16", "yolo26n_fp16", "yolo26n"),
          suggestedLiteRtWireValue = "yolo26n_litert",
      )

  private val generic26s =
      NativeDriveYoloModelVariantDescriptor(
          wireValue = "yolo26s",
          family = "generic",
          aliases = listOf("yolo26s"),
          candidateBaseNames = listOf("yolo26s"),
          candidateTfliteBaseNames = listOf("yolo26s_float16", "yolo26s_fp16", "yolo26s"),
          suggestedLiteRtWireValue = "yolo26s_litert",
      )

  // LiteRT-specific variants: GPU (FP16) primary, INT8 future HTP path.
  private val litert26n =
      NativeDriveYoloModelVariantDescriptor(
          wireValue = "yolo26n_litert",
          family = "litert",
          aliases =
              listOf(
                  "yolo26n_litert",
                  "yolo26n_tflite",
                  "yolo26n_gpu",
                  "yolo26n_fp16",
                  "yolo26n_float16",
              ),
          candidateBaseNames = listOf("yolo26n"),
          // ultralytics half=True → yolo26n_float16.tflite; _fp16 is our internal convention
          candidateTfliteBaseNames = listOf("yolo26n_float16", "yolo26n_fp16", "yolo26n_litert", "yolo26n"),
      )

  private val litert26s =
      NativeDriveYoloModelVariantDescriptor(
          wireValue = "yolo26s_litert",
          family = "litert",
          aliases =
              listOf(
                  "yolo26s_litert",
                  "yolo26s_tflite",
                  "yolo26s_gpu",
                  "yolo26s_fp16",
                  "yolo26s_float16",
              ),
          candidateBaseNames = listOf("yolo26s"),
          candidateTfliteBaseNames = listOf("yolo26s_float16", "yolo26s_fp16", "yolo26s_litert", "yolo26s"),
      )

  private val descriptors = listOf(generic26n, generic26s, litert26n, litert26s)

  val default: NativeDriveYoloModelVariantDescriptor = generic26n

  fun find(raw: String?): NativeDriveYoloModelVariantDescriptor? {
    val normalized = normalize(raw)
    if (normalized.isBlank()) return null
    val compact = compact(normalized)
    return descriptors.firstOrNull { descriptor ->
      descriptor.aliases.any { alias ->
        val aliasNormalized = normalize(alias)
        normalized == aliasNormalized || compact == compact(aliasNormalized)
      }
    }
  }

  fun candidateBaseNamesFor(raw: String?): List<String> {
    val normalized = normalize(raw)
    if (normalized.isBlank()) {
      return default.candidateBaseNames
    }
    return find(normalized)?.candidateBaseNames ?: listOf(normalized)
  }

  // Returns .tflite candidate base names for the given model variant.
  // Used by NativeDriveLiteRtModelLocator.
  fun candidateTfliteBaseNamesFor(
      raw: String?,
      inputWidth: Int? = null,
      inputHeight: Int? = null,
  ): List<String> {
    val normalized = normalize(raw)
    val baseNames =
        if (normalized.isBlank()) {
          default.candidateTfliteBaseNames ?: default.candidateBaseNames
        } else {
          val descriptor = find(normalized)
          descriptor?.candidateTfliteBaseNames
              ?: descriptor?.candidateBaseNames
              ?: listOf(normalized)
        }
    val requestedSize =
        inputWidth?.takeIf { it > 0 && it == inputHeight && it != 416 } ?: return baseNames
    val sizeSpecificNames =
        baseNames.map(::normalize).map { addInputSizeSuffix(it, requestedSize) }.distinct()
    return (sizeSpecificNames + baseNames).distinct()
  }

  private fun addInputSizeSuffix(baseName: String, inputSize: Int): String {
    return when {
      baseName.endsWith("_float16") ->
          baseName.removeSuffix("_float16") + "_${inputSize}_float16"
      baseName.endsWith("_fp16") ->
          baseName.removeSuffix("_fp16") + "_${inputSize}_fp16"
      baseName.endsWith("_litert") ->
          baseName.removeSuffix("_litert") + "_${inputSize}_litert"
      else -> "${baseName}_${inputSize}"
    }
  }

  fun isLiteRtReference(raw: String?): Boolean {
    val normalized = normalize(raw)
    if (normalized.isBlank()) return false
    val matched = find(normalized)
    if (matched != null) {
      return matched.isLiteRt
    }
    return normalized.contains("litert") ||
        normalized.contains("tflite") ||
        normalized.contains("_gpu") ||
        normalized.contains("_fp16")
  }

  fun suggestedLiteRtWireValueFor(raw: String?): String? {
    return find(raw)?.suggestedLiteRtWireValue
  }

  fun normalize(raw: String?): String {
    var value = raw?.trim()?.lowercase().orEmpty()
    if (value.endsWith(".pte")) {
      value = value.removeSuffix(".pte")
    }
    if (value.endsWith(".tflite")) {
      value = value.removeSuffix(".tflite")
    }
    return value
  }

  private fun compact(raw: String): String {
    return raw.replace(Regex("[^a-z0-9]+"), "")
  }
}
