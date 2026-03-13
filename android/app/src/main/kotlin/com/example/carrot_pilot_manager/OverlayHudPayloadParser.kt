package com.example.carrot_pilot_manager

import org.json.JSONObject
import java.util.Locale
import kotlin.math.roundToInt

internal object OverlayHudPayloadParser {
  fun parse(raw: String, context: OverlayHudParseContext): OverlayHudParseResult? {
    return try {
      val obj = JSONObject(raw)
      if (obj.has("vehicle") || obj.has("tempControl")) {
        parseSemantic(obj, context)
      } else {
        parseLegacy(obj, context)
      }
    } catch (_: Throwable) {
      null
    }
  }

  fun formatTemp(value: Double?): String {
    return if (value == null) "--°C" else "${value.roundToInt()}°C"
  }

  fun formatPercent(value: Double?): String {
    return if (value == null) "--%" else "${value.roundToInt()}%"
  }

  private fun parseLegacy(
      obj: JSONObject,
      context: OverlayHudParseContext,
  ): OverlayHudParseResult {
    val parsedCpu = optDoubleAny(obj, "cpuTempC", "cpuTemp", "cpu_temp_c")
    val cpuValue = parsedCpu ?: context.fallbackCpuTempC
    val parsedMem =
        optDoubleAny(obj, "memPct", "memPctC", "mem", "mem_pct", "memoryUsagePercent")
    val memValue = parsedMem ?: context.fallbackMemPct

    val wsDiskLabel = obj.optString("diskLabel", "VOLT").ifBlank { "VOLT" }.uppercase(Locale.US)
    val parsedDisk = optDoubleAny(obj, "diskPct", "disk", "disk_pct")
    val fallbackDisk = context.fallbackDiskPct
    val usingDiskFallback = parsedDisk == null && fallbackDisk != null
    val diskLabel = if (usingDiskFallback) "DISK" else wsDiskLabel
    val diskRaw = parsedDisk ?: fallbackDisk
    val disk = if (diskLabel == "VOLT") {
      if (diskRaw == null) "--.-V" else String.format(Locale.US, "%.1fV", diskRaw)
    } else {
      if (diskRaw == null) "--%" else "${diskRaw.roundToInt()}%"
    }

    val speedKph = optDouble(obj, "vEgo")?.let { (it * 3.6).roundToInt().toString() } ?: "--"
    val vSet = optDouble(obj, "vSetKph")?.roundToInt()?.toString() ?: "--"
    val gear = obj.optString("gear", "U").ifBlank { "U" }
    val gpsOk = obj.optBoolean("gpsOk", false)
    val tfBars = obj.optInt("tfBars", obj.optInt("tfGap", 0)).coerceIn(0, 4)

    val driveMode = obj.optJSONObject("driveMode")
    val modeName = normalizeModeText(
        driveMode?.optString("name")?.takeIf { it.isNotBlank() } ?: "Normal"
    )
    val modeKind = driveMode?.optString("kind")?.lowercase(Locale.US) ?: "normal"

    val tempObj = obj.optJSONObject("temp")
    val tempSource = tempObj?.optString("source")?.takeIf { it.isNotBlank() } ?: "eco"
    val tempSpeed = optDouble(tempObj, "speed")?.roundToInt()?.toString() ?: "--"
    val tempIsDecel = tempObj?.optBoolean("is_decel", false) ?: false

    val limit = optDouble(obj, "speedLimitKph")?.roundToInt()?.toString() ?: "--"
    val limitOver = obj.optBoolean("speedLimitOver", false)

    return OverlayHudParseResult(
        kind = OverlayHudPayloadKind.Legacy,
        hostLabel = context.hostIp,
        metricPatch = OverlayHudMetricPatch(cpuTempC = parsedCpu, memPct = parsedMem, diskPct = parsedDisk),
        uiState =
            OverlayHudUiState(
                sourceText = "COMPAT",
                detailText = buildDetailText(
                    quality = "legacy",
                    host = context.hostIp,
                    compatibilityHint = if (parsedCpu == null || parsedMem == null || parsedDisk == null) "metric fallback" else null,
                ),
                cpuText = formatTemp(cpuValue),
                memText = formatPercent(memValue),
                auxMetricLabel = diskLabel,
                auxMetricValue = disk,
                speedText = speedKph,
                setSpeedText = "SET $vSet",
                gearText = gear,
                gpsText = if (gpsOk) "GPS" else "NO GPS",
                gpsOk = gpsOk,
                tempSourceText = tempSource,
                tempSpeedText = tempSpeed,
                tempIsDecel = tempIsDecel,
                gapText = if (tfBars > 0) "GAP ($tfBars)" else "GAP (--)",
                limitText = "LIMIT $limit",
                limitOver = limitOver,
                connectivityText = "stock",
                modeText = modeName,
                modeKind = modeKind,
                tfBars = tfBars,
                signalState = "off",
                redDot = false,
                statusText = buildStatusText(
                    sourceText = "COMPAT",
                    hostLabel = context.hostIp,
                    qualityText = "legacy",
                    compatibilityHint = if (parsedCpu == null || parsedMem == null || parsedDisk == null) "metric fallback" else null,
                ),
                qualityText = "legacy",
                hostText = context.hostIp.orEmpty(),
                compatibilityHint = if (parsedCpu == null || parsedMem == null || parsedDisk == null) "metric fallback" else "",
                compatibilityBadgeText = if (parsedCpu == null || parsedMem == null || parsedDisk == null) "fallback" else "",
            ),
    )
  }

  private fun parseSemantic(
      obj: JSONObject,
      context: OverlayHudParseContext,
  ): OverlayHudParseResult {
    val source = obj.optJSONObject("source")
    val vehicle = obj.optJSONObject("vehicle")
    val tempControl = obj.optJSONObject("tempControl")
    val driveMode = obj.optJSONObject("driveMode")
    val gap = obj.optJSONObject("gap")
    val limits = obj.optJSONObject("limits")
    val signals = obj.optJSONObject("signals")
    val gps = obj.optJSONObject("gps")
    val device = obj.optJSONObject("device")

    val parsedCpu = optDoubleAny(device, "cpuTempAvgC", "cpuTempMaxC")
    val cpuValue = parsedCpu ?: context.fallbackCpuTempC
    val parsedMem = optDouble(device, "memUsagePct")
    val memValue = parsedMem ?: context.fallbackMemPct

    val metricPrimaryMode =
        device?.optString("metricPrimaryMode", "disk")?.lowercase(Locale.US) ?: "disk"
    val parsedDisk = if (metricPrimaryMode == "volt") optDouble(device, "voltV") else optDouble(device, "diskUsedPct")
    val fallbackDisk = context.fallbackDiskPct

    val diskLabel = if (metricPrimaryMode == "volt") "VOLT" else "DISK"
    val diskValue = parsedDisk ?: if (diskLabel == "DISK") fallbackDisk else null
    val disk = if (diskLabel == "VOLT") {
      if (diskValue == null) "--.-V" else String.format(Locale.US, "%.1fV", diskValue)
    } else {
      if (diskValue == null) "--%" else "${diskValue.roundToInt()}%"
    }

    val speedKph = optDouble(vehicle, "speedClusterKph")?.roundToInt()?.toString() ?: "--"
    val vSet = optDouble(vehicle, "setSpeedClusterKph")?.roundToInt()?.toString() ?: "--"
    val gear = vehicle?.optString("gearText", "U")?.ifBlank { "U" } ?: "U"
    val gpsOk = gps?.optBoolean("hasFix", false) ?: false
    val tfBars = gap?.optInt("barCount", gap.optInt("displayValue", 0))?.coerceIn(0, 4) ?: 0

    val modeNameRaw = driveMode?.optString("nameOriginal")?.takeIf { it.isNotBlank() }
        ?: driveMode?.optString("kind")?.takeIf { it.isNotBlank() }
        ?: "NORM"
    val modeKind = driveMode?.optString("kind")?.lowercase(Locale.US) ?: "normal"
    val modeName = normalizeModeText(modeNameRaw)

    val tempSource = tempControl?.optString("label")?.takeIf { it.isNotBlank() }
        ?: tempControl?.optString("sourceRaw")?.takeIf { it.isNotBlank() }
        ?: "eco"
    val tempSpeed = optDouble(tempControl, "speedKph")?.roundToInt()?.toString() ?: "--"
    val tempIsDecel = tempControl?.optBoolean("isDecel", false) ?: false

    val limitLabel = limits?.optString("label")?.takeIf { it.isNotBlank() } ?: "LIMIT"
    val limit = optDouble(limits, "displaySpeedKph")?.roundToInt()?.toString() ?: "--"
    val limitOver = limits?.optBoolean("isOverLimit", false) ?: false
    val gapText = gap?.optInt("displayValue", 0)?.takeIf { it > 0 }?.let { "GAP ($it)" } ?: "GAP (--)"
    val connectivity = obj.optJSONObject("connectivity")
    val connectivityText = normalizeConnectivityText(
        connectivity?.optString("badgeLabel"),
        connectivity?.optString("badgeMode"),
    )

    val visualState = signals?.optString("visualState", "off")?.lowercase(Locale.US) ?: "off"
    val redDot = signals?.optBoolean("redDot", false) ?: false

    val hostLabel = source?.optString("deviceHost")?.takeIf { it.isNotBlank() } ?: context.hostIp
    val sourceText = mapSourceText(source?.optString("transport"))
    val meta = obj.optJSONObject("meta")
    val qualityText = meta?.optString("quality")?.takeIf { it.isNotBlank() } ?: "live"
    val missingCount = meta?.optJSONArray("missingFields")?.length() ?: 0
    val compatibilityHint = when {
      missingCount > 0 -> "$missingCount missing"
      meta?.optBoolean("isFallbackMetricsApplied", false) == true -> "metric fallback"
      else -> null
    }
    val compatibilityBadgeText = when {
      missingCount > 0 -> "$missingCount miss"
      meta?.optBoolean("isFallbackMetricsApplied", false) == true -> "fallback"
      else -> ""
    }

    return OverlayHudParseResult(
        kind = OverlayHudPayloadKind.Semantic,
        hostLabel = hostLabel,
        metricPatch = OverlayHudMetricPatch(
            cpuTempC = parsedCpu,
            memPct = parsedMem,
            diskPct = if (metricPrimaryMode == "volt") null else parsedDisk,
        ),
        uiState =
            OverlayHudUiState(
                sourceText = sourceText,
                detailText = buildDetailText(
                    quality = qualityText,
                    host = hostLabel,
                    compatibilityHint = compatibilityHint,
                ),
                cpuText = formatTemp(cpuValue),
                memText = formatPercent(memValue),
                auxMetricLabel = diskLabel,
                auxMetricValue = disk,
                speedText = speedKph,
                setSpeedText = "SET $vSet",
                gearText = gear,
                gpsText = if (gpsOk) "GPS" else "NO GPS",
                gpsOk = gpsOk,
                tempSourceText = tempSource,
                tempSpeedText = tempSpeed,
                tempIsDecel = tempIsDecel,
                gapText = gapText,
                limitText = "$limitLabel $limit",
                limitOver = limitOver,
                connectivityText = connectivityText,
                modeText = modeName,
                modeKind = modeKind,
                tfBars = tfBars,
                signalState = visualState,
                redDot = redDot,
                statusText = buildStatusText(
                    sourceText = sourceText,
                    hostLabel = hostLabel,
                    qualityText = qualityText,
                    compatibilityHint = compatibilityHint,
                ),
                qualityText = qualityText,
                hostText = hostLabel.orEmpty(),
                compatibilityHint = compatibilityHint.orEmpty(),
                compatibilityBadgeText = compatibilityBadgeText,
            ),
    )
  }

  private fun optDouble(obj: JSONObject?, key: String): Double? {
    if (obj == null) return null
    if (!obj.has(key) || obj.isNull(key)) return null
    val value = obj.opt(key) ?: return null
    return when (value) {
      is Number -> value.toDouble()
      is String -> value.toDoubleOrNull()
      else -> null
    }
  }

  private fun mapSourceText(raw: String?): String {
    return when (raw?.trim()?.lowercase(Locale.US)) {
      "sidecar_hud" -> "HUD"
      "legacy_ws_carstate" -> "COMPAT"
      "ssh_fallback", "fallback" -> "FALLBACK"
      "unknown", "", null -> "REMOTE"
      else -> "LIVE"
    }
  }

  private fun normalizeModeText(raw: String?): String {
    val text = raw?.trim()?.takeIf { it.isNotEmpty() } ?: "NORM"
    return when (text.uppercase(Locale.US)) {
      "NORMAL", "NORM" -> "NORM"
      "SPORT", "FAST" -> "FAST"
      "ECO" -> "ECO"
      "SAFE" -> "SAFE"
      else -> text.uppercase(Locale.US)
    }
  }

  private fun buildDetailText(
      quality: String?,
      host: String?,
      compatibilityHint: String?,
  ): String {
    return listOfNotNull(
        quality?.trim()?.takeIf { it.isNotEmpty() },
        host?.trim()?.takeIf { it.isNotEmpty() },
        compatibilityHint?.trim()?.takeIf { it.isNotEmpty() },
    ).joinToString(" · ")
  }

  private fun buildStatusText(
      sourceText: String,
      hostLabel: String?,
      qualityText: String?,
      compatibilityHint: String?,
  ): String {
    val prefix = when (sourceText) {
      "COMPAT" -> "호환 모드"
      "FALLBACK" -> "Fallback"
      "PREVIEW" -> "미리보기"
      else -> {
        val quality = qualityText?.trim()?.lowercase(Locale.US).orEmpty()
        when {
          quality.isNotEmpty() && quality != "live" -> "저하 모드"
          compatibilityHint?.isNotBlank() == true -> "저하 모드"
          else -> "연결됨"
        }
      }
    }
    return listOfNotNull(
        prefix,
        hostLabel?.trim()?.takeIf { it.isNotEmpty() },
    ).joinToString(" · ")
  }

  private fun normalizeConnectivityText(label: String?, mode: String?): String {
    val rawLabel = label?.trim()?.uppercase(Locale.US).orEmpty()
    val rawMode = mode?.trim()?.lowercase(Locale.US).orEmpty()
    return when {
      rawLabel == "APN" || rawMode == "apn" -> "APN"
      rawLabel == "APM" || rawMode == "apm" -> "APM"
      else -> ""
    }
  }

  private fun optDoubleAny(obj: JSONObject?, vararg keys: String): Double? {
    for (key in keys) {
      val v = optDouble(obj, key)
      if (v != null) return v
    }
    return null
  }
}
