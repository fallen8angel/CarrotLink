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
)

internal data class NativeDriveYoloParseResult(
    val outputShape: String,
    val candidateCount: Int,
    val acceptedCount: Int,
    val detections: List<NativeDriveYoloDetection>,
)

internal object NativeDriveYoloParser {
  private const val defaultScoreThreshold = 0.25f
  private const val defaultIouThreshold = 0.50f
  private const val defaultMaxDetections = 20

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
      val candidate = parseTensor(
          shape = shape,
          data = data,
          inputWidth = inputWidth,
          inputHeight = inputHeight,
          scoreThreshold = scoreThreshold,
          iouThreshold = iouThreshold,
          maxDetections = maxDetections,
      )
      if (candidate != null) {
        return candidate
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
    for (candidateIndex in 0 until candidateCount) {
      var bestClassId = -1
      var bestScore = 0f
      for (channel in 4 until channelCount) {
        val score = value(channel, candidateIndex)
        if (score > bestScore) {
          bestScore = score
          bestClassId = channel - 4
        }
      }
      if (bestClassId < 0 || bestScore < scoreThreshold) continue

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
    )
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
