package com.example.carrot_pilot_manager

import kotlin.math.max
import kotlin.math.min

/**
 * Letterbox transform metadata — describes how a source image was placed
 * inside a square model input.  Used to reverse-map detection coordinates
 * from input-space back to source-pixel-space.
 */
internal data class LetterboxTransform(
    /** Uniform scale applied to the source image. */
    val scale: Float,
    /** Horizontal offset (left padding) in input pixels. */
    val padLeft: Float,
    /** Vertical offset (top padding) in input pixels. */
    val padTop: Float,
) {
  companion object {
    /** Identity (no letterbox — legacy stretch mode). */
    val IDENTITY = LetterboxTransform(scale = 1f, padLeft = 0f, padTop = 0f)

    /** Compute the letterbox transform for [srcW]×[srcH] → [dstW]×[dstH]. */
    fun compute(srcW: Int, srcH: Int, dstW: Int, dstH: Int): LetterboxTransform {
      if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) return IDENTITY
      val scale = minOf(dstW.toFloat() / srcW, dstH.toFloat() / srcH)
      val scaledW = (srcW * scale)
      val scaledH = (srcH * scale)
      return LetterboxTransform(
          scale = scale,
          padLeft = (dstW - scaledW) * 0.5f,
          padTop = (dstH - scaledH) * 0.5f,
      )
    }
  }
}

internal data class NativeDriveYoloDetection(
    val classId: Int,
    val label: String,
    val score: Float,
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
  fun toPayload(
      sourceWidth: Int,
      sourceHeight: Int,
      inputWidth: Int,
      inputHeight: Int,
      letterbox: LetterboxTransform = LetterboxTransform.IDENTITY,
  ): Map<String, Any?> {
    val safeSourceWidth = (if (sourceWidth > 0) sourceWidth else inputWidth).toFloat()
    val safeSourceHeight = (if (sourceHeight > 0) sourceHeight else inputHeight).toFloat()
    val sourceLeft: Float
    val sourceTop: Float
    val sourceRight: Float
    val sourceBottom: Float
    if (letterbox.scale > 0f && letterbox !== LetterboxTransform.IDENTITY) {
      // Reverse letterbox: subtract padding, then divide by scale.
      val invScale = 1f / letterbox.scale
      sourceLeft = ((left - letterbox.padLeft) * invScale).coerceIn(0f, safeSourceWidth)
      sourceTop = ((top - letterbox.padTop) * invScale).coerceIn(0f, safeSourceHeight)
      sourceRight = ((right - letterbox.padLeft) * invScale).coerceIn(0f, safeSourceWidth)
      sourceBottom = ((bottom - letterbox.padTop) * invScale).coerceIn(0f, safeSourceHeight)
    } else {
      // Legacy stretch mode — simple linear scaling.
      val safeInputWidth = inputWidth.coerceAtLeast(1).toFloat()
      val safeInputHeight = inputHeight.coerceAtLeast(1).toFloat()
      val scaleX = safeSourceWidth / safeInputWidth
      val scaleY = safeSourceHeight / safeInputHeight
      sourceLeft = (left * scaleX).coerceIn(0f, safeSourceWidth)
      sourceTop = (top * scaleY).coerceIn(0f, safeSourceHeight)
      sourceRight = (right * scaleX).coerceIn(0f, safeSourceWidth)
      sourceBottom = (bottom * scaleY).coerceIn(0f, safeSourceHeight)
    }
    return mapOf(
        "classId" to classId,
        "label" to label,
        "score" to score,
        "inputLeft" to left,
        "inputTop" to top,
        "inputRight" to right,
        "inputBottom" to bottom,
        "sourceLeft" to sourceLeft,
        "sourceTop" to sourceTop,
        "sourceRight" to sourceRight,
        "sourceBottom" to sourceBottom,
    )
  }
}

internal data class NativeDriveYoloParseResult(
    val outputShape: String,
    val candidateCount: Int,
    val acceptedCount: Int,
    val detections: List<NativeDriveYoloDetection>,
    val strategy: String,
    val coordinateMode: String,
    val scoreThreshold: Float,
    val maxClassScore: Float,
    val aboveThresholdCount: Int,
)

internal object NativeDriveYoloParser {
  private const val defaultScoreThreshold = 0.22f
  private const val defaultIouThreshold = 0.42f
  private const val defaultMaxDetections = 12
  private const val defaultPreNmsCandidateLimit = 96
  private const val lowScoreThreshold = 0.08f
  private const val sigmoidScoreThreshold = 0.50f
  private const val minVehicleWidthPx = 12f
  private const val minVehicleHeightPx = 10f
  private const val minVehicleAreaPx = 180f
  private const val minPersonWidthPx = 8f
  private const val minPersonHeightPx = 14f
  private const val minPersonAreaPx = 120f
  private const val minTrafficWidthPx = 5f
  private const val minTrafficHeightPx = 8f
  private const val minTrafficAreaPx = 40f
  private const val defaultMinWidthPx = 8f
  private const val defaultMinHeightPx = 8f
  private const val defaultMinAreaPx = 90f

  private data class ClassThresholdProfile(
      val direct: Float,
      val directLow: Float,
      val sigmoid: Float,
  )

  private data class ParseStrategy(
      val name: String,
      val scoreThreshold: Float,
      val decodeScore: (Float) -> Float,
  ) {
    fun thresholdFor(classId: Int, profiles: Map<Int, ClassThresholdProfile> = classThresholdProfiles): Float {
      val profile = profiles[classId] ?: return scoreThreshold
      return when (name) {
        "direct" -> min(scoreThreshold, profile.direct)
        "direct_low" -> min(scoreThreshold, profile.directLow)
        "sigmoid" -> max(scoreThreshold, profile.sigmoid)
        else -> scoreThreshold
      }
    }
  }

  private data class ClassSizeGate(
      val minWidth: Float,
      val minHeight: Float,
      val minArea: Float,
      val maxCount: Int,
  )

  private val defaultAllowedClassIds = setOf(0, 1, 2, 3, 5, 7, 9)
  private val liveRoadAllowedClassIds = setOf(2, 5, 7, 9)
  // yolo26n: lower thresholds to compensate for weaker feature extraction.
  private val classThresholdProfiles =
      mapOf(
          0 to ClassThresholdProfile(0.17f, 0.09f, 0.54f),
          1 to ClassThresholdProfile(0.16f, 0.09f, 0.54f),
          2 to ClassThresholdProfile(0.17f, 0.10f, 0.54f),
          3 to ClassThresholdProfile(0.16f, 0.09f, 0.54f),
          5 to ClassThresholdProfile(0.18f, 0.10f, 0.56f),
          7 to ClassThresholdProfile(0.18f, 0.10f, 0.56f),
          9 to ClassThresholdProfile(0.10f, 0.04f, 0.53f),
      )
  // yolo26s: stronger features allow higher thresholds → fewer false positives.
  private val classThresholdProfilesSmall =
      mapOf(
          0 to ClassThresholdProfile(0.24f, 0.14f, 0.58f),
          1 to ClassThresholdProfile(0.22f, 0.14f, 0.58f),
          2 to ClassThresholdProfile(0.24f, 0.15f, 0.58f),
          3 to ClassThresholdProfile(0.22f, 0.14f, 0.58f),
          5 to ClassThresholdProfile(0.25f, 0.15f, 0.60f),
          7 to ClassThresholdProfile(0.25f, 0.15f, 0.60f),
          9 to ClassThresholdProfile(0.14f, 0.06f, 0.56f),
      )
  private val classSizeGates =
      mapOf(
          0 to ClassSizeGate(minPersonWidthPx, minPersonHeightPx, minPersonAreaPx, 2),
          1 to ClassSizeGate(defaultMinWidthPx, defaultMinHeightPx, defaultMinAreaPx, 2),
          2 to ClassSizeGate(minVehicleWidthPx, minVehicleHeightPx, minVehicleAreaPx, 8),
          3 to ClassSizeGate(minVehicleWidthPx, minVehicleHeightPx, minVehicleAreaPx, 2),
          5 to ClassSizeGate(minVehicleWidthPx, minVehicleHeightPx, minVehicleAreaPx, 2),
          7 to ClassSizeGate(minVehicleWidthPx, minVehicleHeightPx, minVehicleAreaPx, 3),
          9 to ClassSizeGate(minTrafficWidthPx, minTrafficHeightPx, minTrafficAreaPx, 4),
      )
  // export 경로마다 score post-processing이 완전히 같다고 보장하기 어려워
  // 1차 bring-up 단계에선 road-object 범위 안에서 몇 가지 score decode를 순차 시도한다.
  private val parseStrategies =
      listOf(
          ParseStrategy(
              name = "direct",
              scoreThreshold = defaultScoreThreshold,
              decodeScore = { value -> value },
          ),
          ParseStrategy(
              name = "direct_low",
              scoreThreshold = lowScoreThreshold,
              decodeScore = { value -> value },
          ),
          ParseStrategy(
              name = "sigmoid",
              scoreThreshold = sigmoidScoreThreshold,
              decodeScore = { value -> sigmoid(value) },
          ),
      )
  private val parseStrategiesByName = parseStrategies.associateBy { it.name }

  // COCO 80-class labels, matching the exported YOLO26 detection head.
  private val cocoLabels =
      listOf(
          "person",
          "bicycle",
          "car",
          "motorcycle",
          "airplane",
          "bus",
          "train",
          "truck",
          "boat",
          "traffic light",
          "fire hydrant",
          "stop sign",
          "parking meter",
          "bench",
          "bird",
          "cat",
          "dog",
          "horse",
          "sheep",
          "cow",
          "elephant",
          "bear",
          "zebra",
          "giraffe",
          "backpack",
          "umbrella",
          "handbag",
          "tie",
          "suitcase",
          "frisbee",
          "skis",
          "snowboard",
          "sports ball",
          "kite",
          "baseball bat",
          "baseball glove",
          "skateboard",
          "surfboard",
          "tennis racket",
          "bottle",
          "wine glass",
          "cup",
          "fork",
          "knife",
          "spoon",
          "bowl",
          "banana",
          "apple",
          "sandwich",
          "orange",
          "broccoli",
          "carrot",
          "hot dog",
          "pizza",
          "donut",
          "cake",
          "chair",
          "couch",
          "potted plant",
          "bed",
          "dining table",
          "toilet",
          "tv",
          "laptop",
          "mouse",
          "remote",
          "keyboard",
          "cell phone",
          "microwave",
          "oven",
          "toaster",
          "sink",
          "refrigerator",
          "book",
          "clock",
          "vase",
          "scissors",
          "teddy bear",
          "hair drier",
          "toothbrush",
      )

  fun parse(
      outputShapes: List<LongArray>,
      outputTensors: List<FloatArray>,
      inputWidth: Int,
      inputHeight: Int,
      scoreThreshold: Float = defaultScoreThreshold,
      iouThreshold: Float = defaultIouThreshold,
      maxDetections: Int = defaultMaxDetections,
      preNmsCandidateLimit: Int = defaultPreNmsCandidateLimit,
      strategyHint: String? = null,
      liveRoadMode: Boolean = false,
      includeTrafficLights: Boolean = true,
      modelVariant: String? = null,
  ): NativeDriveYoloParseResult? {
    val orderedStrategies =
        orderedParseStrategies(strategyHint)
    val effectiveLiveRoadMode = liveRoadMode && inputWidth >= 320 && inputHeight >= 320
    val effectiveProfiles = thresholdProfilesFor(modelVariant)
    val allowedClassIds =
        allowedClassIdsFor(
            liveRoadMode = effectiveLiveRoadMode,
            includeTrafficLights = includeTrafficLights,
        )
    val effectivePreNmsCandidateLimit =
        if (effectiveLiveRoadMode) min(preNmsCandidateLimit, 48) else preNmsCandidateLimit
    val effectiveMaxDetections =
        if (effectiveLiveRoadMode) min(maxDetections, 8) else maxDetections
    for (index in outputShapes.indices) {
      val shape = outputShapes[index]
      val data = outputTensors.getOrNull(index) ?: continue
      val attempts = mutableListOf<NativeDriveYoloParseResult>()
      for (strategy in orderedStrategies) {
        val attempt =
            parseTensor(
                shape = shape,
                data = data,
                inputWidth = inputWidth,
                inputHeight = inputHeight,
                scoreThreshold = strategy.scoreThreshold,
                iouThreshold = iouThreshold,
                maxDetections = effectiveMaxDetections,
                preNmsCandidateLimit = effectivePreNmsCandidateLimit,
                strategy = strategy,
                liveRoadMode = effectiveLiveRoadMode,
                allowedClassIds = allowedClassIds,
                thresholdProfiles = effectiveProfiles,
            )
        if (attempt == null) continue
        if (!strategyHint.isNullOrBlank() &&
            attempt.strategy == strategyHint &&
            attempt.acceptedCount > 0) {
          return attempt
        }
        attempts += attempt
      }
      if (attempts.isNotEmpty()) {
        return attempts.maxWithOrNull(
            compareBy<NativeDriveYoloParseResult> { it.acceptedCount }
                .thenBy { it.aboveThresholdCount }
                .thenBy { it.maxClassScore },
        )
      }
    }
    return null
  }

  private fun orderedParseStrategies(strategyHint: String?): List<ParseStrategy> {
    val hint = strategyHint?.trim()?.ifEmpty { null } ?: return parseStrategies
    val preferred = parseStrategiesByName[hint] ?: return parseStrategies
    return buildList(parseStrategies.size) {
      add(preferred)
      addAll(parseStrategies.filterNot { it.name == preferred.name })
    }
  }

  private fun parseTensor(
      shape: LongArray,
      data: FloatArray,
      inputWidth: Int,
      inputHeight: Int,
      scoreThreshold: Float,
      iouThreshold: Float,
      maxDetections: Int,
      preNmsCandidateLimit: Int,
      strategy: ParseStrategy,
      liveRoadMode: Boolean,
      allowedClassIds: Set<Int>,
      thresholdProfiles: Map<Int, ClassThresholdProfile> = classThresholdProfiles,
  ): NativeDriveYoloParseResult? {
    val normalizedShape = shape.toList()
    if (normalizedShape.isEmpty()) return null

    val axisA: Int
    val axisB: Int
    val channelFirst: Boolean

    when (normalizedShape.size) {
      2 -> {
        axisA = normalizedShape[0].toInt()
        axisB = normalizedShape[1].toInt()
        channelFirst = axisA <= axisB
      }
      3 -> {
        if (normalizedShape[0] != 1L) return null
        val dim1 = normalizedShape[1].toInt()
        val dim2 = normalizedShape[2].toInt()
        axisA = dim1
        axisB = dim2
        channelFirst = dim1 <= dim2
      }
      else -> return null
    }

    val channelCount = if (channelFirst) axisA else axisB
    val candidateCount = if (channelFirst) axisB else axisA
    if (channelCount <= 4 || candidateCount <= 0) return null
    if (data.size < channelCount * candidateCount) return null

    fun value(channel: Int, candidate: Int): Float {
      return if (channelFirst) {
        data[(channel * candidateCount) + candidate]
      } else {
        data[(candidate * channelCount) + channel]
      }
    }

    val decoded = ArrayList<NativeDriveYoloDetection>(min(preNmsCandidateLimit, candidateCount))
    val decodedPriorities = ArrayList<Float>(min(preNmsCandidateLimit, candidateCount))
    var minDecodedScore = Float.NEGATIVE_INFINITY
    var maxClassScore = Float.NEGATIVE_INFINITY
    var aboveThresholdCount = 0
    val coordinateMode = detectCoordinateMode(candidateCount, ::value)
    for (candidateIndex in 0 until candidateCount) {
      var bestClassId = -1
      var bestScore = 0f
      for (channel in 4 until channelCount) {
        val classId = channel - 4
        if (!allowedClassIds.contains(classId)) continue
        val score = strategy.decodeScore(value(channel, candidateIndex))
        if (score > maxClassScore) {
          maxClassScore = score
        }
        if (score > bestScore) {
          bestScore = score
          bestClassId = classId
        }
      }
      val effectiveThreshold =
          if (bestClassId >= 0) strategy.thresholdFor(bestClassId, thresholdProfiles) else scoreThreshold
      if (bestClassId >= 0 && bestScore >= effectiveThreshold) {
        aboveThresholdCount += 1
      }
      if (bestClassId < 0 || bestScore < effectiveThreshold) continue

      var cx = value(0, candidateIndex)
      var cy = value(1, candidateIndex)
      var width = max(0f, value(2, candidateIndex))
      var height = max(0f, value(3, candidateIndex))
      if (coordinateMode == "normalized_xywh") {
        cx *= inputWidth.toFloat()
        cy *= inputHeight.toFloat()
        width *= inputWidth.toFloat()
        height *= inputHeight.toFloat()
      }
      if (width < 1f || height < 1f) continue

      val left = (cx - (width * 0.5f)).coerceIn(0f, inputWidth.toFloat())
      val top = (cy - (height * 0.5f)).coerceIn(0f, inputHeight.toFloat())
      val right = (cx + (width * 0.5f)).coerceIn(0f, inputWidth.toFloat())
      val bottom = (cy + (height * 0.5f)).coerceIn(0f, inputHeight.toFloat())
      if ((right - left) < 1f || (bottom - top) < 1f) continue

      val candidate =
          NativeDriveYoloDetection(
              classId = bestClassId,
              label = cocoLabels.getOrElse(bestClassId) { "cls_$bestClassId" },
              score = bestScore,
              left = left,
              top = top,
              right = right,
              bottom = bottom,
      )
      if (!passesSizeGate(candidate, inputWidth, inputHeight, liveRoadMode)) continue
      if (!passesSemanticGate(candidate, inputWidth, inputHeight, liveRoadMode)) continue
      val candidatePriority =
          detectionPriority(
              detection = candidate,
              inputWidth = inputWidth,
              inputHeight = inputHeight,
              liveRoadMode = liveRoadMode,
          )
      if (decoded.size >= preNmsCandidateLimit && candidatePriority <= minDecodedScore) continue

      insertByPriorityCached(
          decoded = decoded,
          decodedPriorities = decodedPriorities,
          candidate = candidate,
          candidatePriority = candidatePriority,
          limit = preNmsCandidateLimit,
      )
      minDecodedScore =
          if (decoded.size >= preNmsCandidateLimit) {
            decodedPriorities.last()
          } else {
            Float.NEGATIVE_INFINITY
          }
    }

    if (decoded.isEmpty()) {
      return NativeDriveYoloParseResult(
          outputShape = shape.joinToString(prefix = "[", postfix = "]"),
          candidateCount = candidateCount,
          acceptedCount = 0,
          detections = emptyList(),
          strategy = strategy.name,
          coordinateMode = coordinateMode,
          scoreThreshold = scoreThreshold,
          maxClassScore = maxClassScore.takeIf { it.isFinite() } ?: 0f,
          aboveThresholdCount = aboveThresholdCount,
      )
    }

    val selected = mutableListOf<NativeDriveYoloDetection>()
    val classCounts = mutableMapOf<Int, Int>()
    for (candidate in decoded) {
      var suppressed = false
      for (kept in selected) {
        if (suppressionGroup(candidate.classId) != suppressionGroup(kept.classId)) {
          continue
        }
        if (iou(candidate, kept) > iouThreshold) {
          suppressed = true
          break
        }
      }
      if (suppressed) continue
      val gate = classSizeGates[candidate.classId]
      val classCount = classCounts[candidate.classId] ?: 0
      if (gate != null && classCount >= gate.maxCount) continue
      selected += candidate
      classCounts[candidate.classId] = classCount + 1
      if (selected.size >= maxDetections) break
    }
    if (liveRoadMode && selected.size > 1) {
      selected.sortByDescending { detection ->
        detectionPriority(
            detection = detection,
            inputWidth = inputWidth,
            inputHeight = inputHeight,
            liveRoadMode = true,
        )
      }
    }

    return NativeDriveYoloParseResult(
        outputShape = shape.joinToString(prefix = "[", postfix = "]"),
        candidateCount = candidateCount,
        acceptedCount = selected.size,
        detections = selected,
        strategy = strategy.name,
        coordinateMode = coordinateMode,
        scoreThreshold = scoreThreshold,
        maxClassScore = maxClassScore.takeIf { it.isFinite() } ?: 0f,
        aboveThresholdCount = aboveThresholdCount,
    )
  }

  private fun allowedClassIdsFor(
      liveRoadMode: Boolean,
      includeTrafficLights: Boolean,
  ): Set<Int> {
    val base = if (liveRoadMode) liveRoadAllowedClassIds else defaultAllowedClassIds
    return if (includeTrafficLights) {
      base
    } else {
      base - 9
    }
  }

  private fun detectCoordinateMode(
      candidateCount: Int,
      value: (channel: Int, candidate: Int) -> Float,
  ): String {
    val sampleCount = min(candidateCount, 24)
    if (sampleCount <= 0) return "absolute_xywh"

    var maxCx = 0f
    var maxCy = 0f
    var maxW = 0f
    var maxH = 0f
    for (candidateIndex in 0 until sampleCount) {
      maxCx = max(maxCx, kotlin.math.abs(value(0, candidateIndex)))
      maxCy = max(maxCy, kotlin.math.abs(value(1, candidateIndex)))
      maxW = max(maxW, kotlin.math.abs(value(2, candidateIndex)))
      maxH = max(maxH, kotlin.math.abs(value(3, candidateIndex)))
    }

    val looksNormalized =
        maxCx <= 2.5f &&
            maxCy <= 2.5f &&
            maxW <= 2.5f &&
            maxH <= 2.5f
    return if (looksNormalized) "normalized_xywh" else "absolute_xywh"
  }

  private fun sigmoid(value: Float): Float {
    if (!value.isFinite()) return 0f
    val clamped = value.coerceIn(-40f, 40f)
    return (1.0 / (1.0 + kotlin.math.exp((-clamped).toDouble()))).toFloat()
  }

  private fun passesSizeGate(
      detection: NativeDriveYoloDetection,
      inputWidth: Int,
      inputHeight: Int,
      liveRoadMode: Boolean,
  ): Boolean {
    val width = max(0f, detection.right - detection.left)
    val height = max(0f, detection.bottom - detection.top)
    val area = width * height
    val gate =
        classSizeGates[detection.classId]
            ?: ClassSizeGate(
                minWidth = defaultMinWidthPx,
                minHeight = defaultMinHeightPx,
                minArea = defaultMinAreaPx,
                maxCount = defaultMaxDetections,
            )
    if (width < gate.minWidth || height < gate.minHeight || area < gate.minArea) {
      return false
    }

    val horizontalMargin = inputWidth.toFloat() * 0.015f
    val verticalMargin = inputHeight.toFloat() * 0.015f
    val touchesEdge =
        detection.left <= horizontalMargin ||
            detection.top <= verticalMargin ||
            detection.right >= (inputWidth.toFloat() - horizontalMargin) ||
            detection.bottom >= (inputHeight.toFloat() - verticalMargin)
    if (touchesEdge && area < (gate.minArea * 1.6f)) {
      return false
    }
    if (liveRoadMode && detection.classId in setOf(2, 5, 7)) {
      val widthRatio = width / inputWidth.toFloat().coerceAtLeast(1f)
      val heightRatio = height / inputHeight.toFloat().coerceAtLeast(1f)
      if (touchesEdge && widthRatio < 0.08f && heightRatio < 0.10f) {
        return false
      }
    }
    return true
  }

  private fun passesSemanticGate(
      detection: NativeDriveYoloDetection,
      inputWidth: Int,
      inputHeight: Int,
      liveRoadMode: Boolean,
  ): Boolean {
    val width = max(0f, detection.right - detection.left)
    val height = max(0f, detection.bottom - detection.top)
    val area = width * height
    val safeWidth = inputWidth.toFloat().coerceAtLeast(1f)
    val safeHeight = inputHeight.toFloat().coerceAtLeast(1f)
    val areaRatio = area / (safeWidth * safeHeight)
    val widthRatio = width / safeWidth
    val heightRatio = height / safeHeight
    val centerX = ((detection.left + detection.right) * 0.5f) / safeWidth
    val centerY = ((detection.top + detection.bottom) * 0.5f) / safeHeight
    val bottomRatio = detection.bottom / safeHeight
    val aspect = width / max(1f, height)

    return when (detection.classId) {
      0 -> {
        if (bottomRatio < 0.28f) return false
        if (centerY < 0.36f && heightRatio < 0.09f) return false
        aspect in 0.16f..0.95f
      }
      1, 3 -> {
        if (bottomRatio < 0.30f) return false
        if (centerY < 0.34f && areaRatio < 0.0012f) return false
        aspect in 0.45f..2.20f
      }
      2, 5, 7 -> {
        if (bottomRatio < 0.26f) return false
        if (centerY < 0.34f && heightRatio < 0.040f) return false
        if (centerY < 0.42f && areaRatio < 0.0010f) return false
        if (widthRatio > 0.82f && centerY < 0.78f) return false
        if (heightRatio > 0.58f && bottomRatio < 0.90f) return false
        if (liveRoadMode) {
          if (centerX < 0.02f || centerX > 0.98f) return false
          if ((centerX < 0.08f || centerX > 0.92f) && areaRatio < 0.008f) return false
          if (centerY < 0.38f && areaRatio < 0.0014f) return false
          if (centerY < 0.46f && widthRatio < 0.040f && heightRatio < 0.050f) return false
          aspect in 0.70f..4.80f
        } else {
          aspect in 0.55f..5.60f
        }
      }
      9 -> {
        if (centerY > 0.58f) return false
        if (bottomRatio > 0.66f) return false
        if (heightRatio > 0.20f || widthRatio > 0.18f) return false
        if (areaRatio > 0.018f) return false
        if (centerY < 0.08f && areaRatio < 0.0005f) return false
        if (centerX < 0.04f || centerX > 0.98f) return false
        if (liveRoadMode) {
          if (centerY > 0.52f) return false
          if (widthRatio > 0.14f || heightRatio > 0.16f) return false
          if (areaRatio > 0.012f) return false
          if (centerX < 0.08f || centerX > 0.92f) return false
          aspect in 0.18f..2.20f
        } else {
          aspect in 0.12f..2.60f
        }
      }
      else -> true
    }
  }

  private fun suppressionGroup(classId: Int): Int {
    return when (classId) {
      1, 2, 3, 5, 7 -> 1
      0 -> 2
      9 -> 3
      else -> classId + 100
    }
  }

  private fun insertByPriorityCached(
      decoded: MutableList<NativeDriveYoloDetection>,
      decodedPriorities: MutableList<Float>,
      candidate: NativeDriveYoloDetection,
      candidatePriority: Float,
      limit: Int,
  ) {
    var insertIndex = decoded.size
    for (index in decoded.indices) {
      if (candidatePriority > decodedPriorities[index]) {
        insertIndex = index
        break
      }
    }
    if (insertIndex >= limit) return
    decoded.add(insertIndex, candidate)
    decodedPriorities.add(insertIndex, candidatePriority)
    if (decoded.size > limit) {
      decoded.removeAt(decoded.lastIndex)
      decodedPriorities.removeAt(decodedPriorities.lastIndex)
    }
  }

  private fun detectionPriority(
      detection: NativeDriveYoloDetection,
      inputWidth: Int,
      inputHeight: Int,
      liveRoadMode: Boolean,
  ): Float {
    if (!liveRoadMode) {
      return detection.score
    }
    val safeWidth = inputWidth.toFloat().coerceAtLeast(1f)
    val safeHeight = inputHeight.toFloat().coerceAtLeast(1f)
    val width = max(0f, detection.right - detection.left)
    val height = max(0f, detection.bottom - detection.top)
    val areaRatio = (width * height) / (safeWidth * safeHeight)
    val centerX = ((detection.left + detection.right) * 0.5f) / safeWidth
    val centerY = ((detection.top + detection.bottom) * 0.5f) / safeHeight
    val centerBias = (1f - (kotlin.math.abs(centerX - 0.5f) / 0.5f)).coerceIn(0f, 1f)
    return when (detection.classId) {
      2, 5, 7 -> {
        val bottomBias = centerY.coerceIn(0f, 1f)
        val areaBoost = min(0.45f, areaRatio * 14f)
        (detection.score * 1.55f) + (centerBias * 0.55f) + (bottomBias * 0.70f) + areaBoost
      }
      9 -> {
        val topBias = (1f - centerY).coerceIn(0f, 1f)
        (detection.score * 1.45f) + (topBias * 0.55f) + (centerBias * 0.18f)
      }
      else -> detection.score
    }
  }

  private fun thresholdProfilesFor(modelVariant: String?): Map<Int, ClassThresholdProfile> {
    val normalized = modelVariant?.trim()?.lowercase().orEmpty()
    return if (normalized.contains("26s")) classThresholdProfilesSmall else classThresholdProfiles
  }

  private fun iou(a: NativeDriveYoloDetection, b: NativeDriveYoloDetection): Float {
    val interLeft = max(a.left, b.left)
    val interTop = max(a.top, b.top)
    val interRight = min(a.right, b.right)
    val interBottom = min(a.bottom, b.bottom)
    val interWidth = max(0f, interRight - interLeft)
    val interHeight = max(0f, interBottom - interTop)
    val interArea = interWidth * interHeight
    if (interArea <= 0f) return 0f
    val areaA = max(0f, a.right - a.left) * max(0f, a.bottom - a.top)
    val areaB = max(0f, b.right - b.left) * max(0f, b.bottom - b.top)
    val union = areaA + areaB - interArea
    if (union <= 0f) return 0f
    return interArea / union
  }
}
