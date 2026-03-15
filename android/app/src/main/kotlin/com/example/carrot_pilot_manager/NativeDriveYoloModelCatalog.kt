package com.example.carrot_pilot_manager

internal data class NativeDriveYoloModelVariantDescriptor(
    val wireValue: String,
    val family: String,
    val aliases: List<String>,
    val candidateBaseNames: List<String>,
    val suggestedQnnWireValue: String? = null,
) {
  val isQnnLowered: Boolean
    get() = family == "qnn"
}

internal object NativeDriveYoloModelCatalog {
  private val generic26n =
      NativeDriveYoloModelVariantDescriptor(
          wireValue = "yolo26n",
          family = "generic",
          aliases = listOf("yolo26n"),
          candidateBaseNames = listOf("yolo26n"),
          suggestedQnnWireValue = "yolo26n_qnn",
      )

  private val generic26s =
      NativeDriveYoloModelVariantDescriptor(
          wireValue = "yolo26s",
          family = "generic",
          aliases = listOf("yolo26s"),
          candidateBaseNames = listOf("yolo26s"),
          suggestedQnnWireValue = "yolo26s_qnn",
      )

  private val qnn26n =
      NativeDriveYoloModelVariantDescriptor(
          wireValue = "yolo26n_qnn",
          family = "qnn",
          aliases =
              listOf(
                  "yolo26n_qnn",
                  "yolo26n-qnn",
                  "yolo26n.qnn",
                  "yolo26n_htp",
                  "yolo26n-htp",
                  "qnn_yolo26n",
              ),
          candidateBaseNames =
              listOf(
                  "yolo26n_qnn",
                  "yolo26n.qnn",
                  "yolo26n_htp",
                  "yolo26n-htp",
                  "qnn_yolo26n",
              ),
      )

  private val qnn26s =
      NativeDriveYoloModelVariantDescriptor(
          wireValue = "yolo26s_qnn",
          family = "qnn",
          aliases =
              listOf(
                  "yolo26s_qnn",
                  "yolo26s-qnn",
                  "yolo26s.qnn",
                  "yolo26s_htp",
                  "yolo26s-htp",
                  "qnn_yolo26s",
              ),
          candidateBaseNames =
              listOf(
                  "yolo26s_qnn",
                  "yolo26s.qnn",
                  "yolo26s_htp",
                  "yolo26s-htp",
                  "qnn_yolo26s",
              ),
      )

  private val descriptors = listOf(generic26n, generic26s, qnn26n, qnn26s)

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

  fun isQnnLoweredReference(raw: String?): Boolean {
    val normalized = normalize(raw)
    if (normalized.isBlank()) return false
    val matched = find(normalized)
    if (matched != null) {
      return matched.isQnnLowered
    }
    return normalized.contains("qnn") ||
        normalized.contains("htp") ||
        normalized.contains("qualcomm")
  }

  fun suggestedQnnWireValueFor(raw: String?): String? {
    return find(raw)?.suggestedQnnWireValue
  }

  fun normalize(raw: String?): String {
    var value = raw?.trim()?.lowercase().orEmpty()
    if (value.endsWith(".pte")) {
      value = value.removeSuffix(".pte")
    }
    return value
  }

  private fun compact(raw: String): String {
    return raw.replace(Regex("[^a-z0-9]+"), "")
  }
}
