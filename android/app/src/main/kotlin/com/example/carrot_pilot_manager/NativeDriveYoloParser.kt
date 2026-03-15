package com.example.carrot_pilot_manager

import kotlin.math.max
import kotlin.math.min

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
  ): Map<String, Any?> {
    val safeInputWidth = inputWidth.coerceAtLeast(1)
    val safeInputHeight = inputHeight.coerceAtLeast(1)
    // Developer playback can decode to a smaller frame than the model input
    // size (for example 526x330 into 416x416). Keep source projection tied to
    // the real decoded frame, otherwise box placement drifts vertically/horizontally.
    val safeSourceWidth = if (sourceWidth > 0) sourceWidth else safeInputWidth
    val safeSourceHeight = if (sourceHeight > 0) sourceHeight else safeInputHeight
    val scaleX = safeSourceWidth.toFloat() / safeInputWidth.toFloat()
    val scaleY = safeSourceHeight.toFloat() / safeInputHeight.toFloat()
    val sourceLeft = (left * scaleX).coerceIn(0f, safeSourceWidth.toFloat())
    val sourceTop = (top * scaleY).coerceIn(0f, safeSourceHeight.toFloat())
    val sourceRight = (right * scaleX).coerceIn(0f, safeSourceWidth.toFloat())
    val sourceBottom = (bottom * scaleY).coerceIn(0f, safeSourceHeight.toFloat())
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
    val scoreThreshold: Float,
    val maxClassScore: Float,
    val aboveThresholdCount: Int,
)

internal object NativeDriveYoloParser {
  private const val defaultScoreThreshold = 0.22f
  private const val defaultIouThreshold = 0.50f
  private const val defaultMaxDetections = 28
  private const val lowScoreThreshold = 0.08f
  private const val sigmoidScoreThreshold = 0.50f

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
    fun thresholdFor(classId: Int): Float {
      val profile = classThresholdProfiles[classId] ?: return scoreThreshold
      return when (name) {
        "direct" -> min(scoreThreshold, profile.direct)
        "direct_low" -> min(scoreThreshold, profile.directLow)
        "sigmoid" -> min(scoreThreshold, profile.sigmoid)
        else -> scoreThreshold
      }
    }
  }

  // 1차 범위는 road-facing 주요 객체만 유지한다.
  private val allowedClassIds = setOf(0, 1, 2, 3, 5, 7, 9)
  private val classThresholdProfiles =
      mapOf(
          0 to ClassThresholdProfile(0.16f, 0.07f, 0.40f),
          1 to ClassThresholdProfile(0.15f, 0.07f, 0.38f),
          2 to ClassThresholdProfile(0.16f, 0.08f, 0.40f),
          3 to ClassThresholdProfile(0.15f, 0.07f, 0.38f),
          5 to ClassThresholdProfile(0.17f, 0.08f, 0.42f),
          7 to ClassThresholdProfile(0.17f, 0.08f, 0.42f),
          9 to ClassThresholdProfile(0.11f, 0.05f, 0.32f),
      )
  // QNN / generic export 결과가 score post-processing을 동일하게 보장하지 않아
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
  ): NativeDriveYoloParseResult? {
    for (index in outputShapes.indices) {
      val shape = outputShapes[index]
      val data = outputTensors.getOrNull(index) ?: continue
      val attempts =
          parseStrategies.mapNotNull { strategy ->
            parseTensor(
                shape = shape,
                data = data,
                inputWidth = inputWidth,
                inputHeight = inputHeight,
                scoreThreshold = strategy.scoreThreshold,
                iouThreshold = iouThreshold,
                maxDetections = maxDetections,
                strategy = strategy,
            )
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

  private fun parseTensor(
      shape: LongArray,
      data: FloatArray,
      inputWidth: Int,
      inputHeight: Int,
      scoreThreshold: Float,
      iouThreshold: Float,
      maxDetections: Int,
      strategy: ParseStrategy,
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

    val decoded = mutableListOf<NativeDriveYoloDetection>()
    var maxClassScore = Float.NEGATIVE_INFINITY
    var aboveThresholdCount = 0
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
          if (bestClassId >= 0) strategy.thresholdFor(bestClassId) else scoreThreshold
      if (bestClassId >= 0 && bestScore >= effectiveThreshold) {
        aboveThresholdCount += 1
      }
      if (bestClassId < 0 || bestScore < effectiveThreshold) continue

      val cx = value(0, candidateIndex)
      val cy = value(1, candidateIndex)
      val width = max(0f, value(2, candidateIndex))
      val height = max(0f, value(3, candidateIndex))
      if (width < 1f || height < 1f) continue

      val left = (cx - (width * 0.5f)).coerceIn(0f, inputWidth.toFloat())
      val top = (cy - (height * 0.5f)).coerceIn(0f, inputHeight.toFloat())
      val right = (cx + (width * 0.5f)).coerceIn(0f, inputWidth.toFloat())
      val bottom = (cy + (height * 0.5f)).coerceIn(0f, inputHeight.toFloat())
      if ((right - left) < 1f || (bottom - top) < 1f) continue

      decoded +=
          NativeDriveYoloDetection(
              classId = bestClassId,
              label = cocoLabels.getOrElse(bestClassId) { "cls_$bestClassId" },
              score = bestScore,
              left = left,
              top = top,
              right = right,
              bottom = bottom,
          )
    }

    if (decoded.isEmpty()) {
      return NativeDriveYoloParseResult(
          outputShape = shape.joinToString(prefix = "[", postfix = "]"),
          candidateCount = candidateCount,
          acceptedCount = 0,
          detections = emptyList(),
          strategy = strategy.name,
          scoreThreshold = scoreThreshold,
          maxClassScore = maxClassScore.takeIf { it.isFinite() } ?: 0f,
          aboveThresholdCount = aboveThresholdCount,
      )
    }

    val sorted = decoded.sortedByDescending { it.score }
    val selected = mutableListOf<NativeDriveYoloDetection>()
    for (candidate in sorted) {
      var suppressed = false
      for (kept in selected) {
        if (candidate.classId != kept.classId) continue
        if (iou(candidate, kept) > iouThreshold) {
          suppressed = true
          break
        }
      }
      if (suppressed) continue
      selected += candidate
      if (selected.size >= maxDetections) break
    }

    return NativeDriveYoloParseResult(
        outputShape = shape.joinToString(prefix = "[", postfix = "]"),
        candidateCount = candidateCount,
        acceptedCount = selected.size,
        detections = selected,
        strategy = strategy.name,
        scoreThreshold = scoreThreshold,
        maxClassScore = maxClassScore.takeIf { it.isFinite() } ?: 0f,
        aboveThresholdCount = aboveThresholdCount,
    )
  }

  private fun sigmoid(value: Float): Float {
    if (!value.isFinite()) return 0f
    val clamped = value.coerceIn(-40f, 40f)
    return (1.0 / (1.0 + kotlin.math.exp((-clamped).toDouble()))).toFloat()
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
