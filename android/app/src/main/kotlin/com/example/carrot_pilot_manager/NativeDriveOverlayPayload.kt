package com.example.carrot_pilot_manager

import android.graphics.Color

internal data class NativeDriveOverlayPayload(
    val canvasWidth: Float,
    val canvasHeight: Float,
    val polygons: List<Polygon>,
    val gradients: List<GradientRect>,
    val labels: List<Label>,
) {
    data class Polygon(
        val points: FloatArray,
        val fillColor: Int,
        val strokeColor: Int?,
        val strokeWidth: Float,
    )

    data class Label(
        val x: Float,
        val y: Float,
        val text: String,
        val color: Int,
        val size: Float,
        val strokeColor: Int? = null,
        val strokeWidth: Float = 0f,
        val fontWeight: Int = 700,
        val alignX: String = "left",
        val alignY: String = "baseline",
        val maxWidth: Float? = null,
        val maxLines: Int? = null,
        val ellipsis: String? = null,
    )

    data class GradientRect(
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
        val startX: Float,
        val startY: Float,
        val endX: Float,
        val endY: Float,
        val colors: IntArray,
        val stops: FloatArray,
    )

    val isEmpty: Boolean
        get() = polygons.isEmpty() && gradients.isEmpty() && labels.isEmpty()

    val complexityScore: Float
        get() {
            val polygonScore = (polygons.size / 140f).coerceIn(0f, 1f)
            val gradientScore = (gradients.size / 6f).coerceIn(0f, 1f)
            val labelScore = (labels.size / 16f).coerceIn(0f, 1f)
            val strokeScore = (polygons.count { it.strokeColor != null } / 72f).toFloat().coerceIn(0f, 1f)
            return ((polygonScore * 0.48f) + (gradientScore * 0.12f) + (labelScore * 0.24f) + (strokeScore * 0.16f))
                .coerceIn(0f, 1f)
        }

    companion object {
        fun fromPayload(payload: Map<String, Any?>?): NativeDriveOverlayPayload? {
            if (payload == null) return null
            val parsedPolygons = parsePolygons(payload["polygons"] as? List<*>)
            val parsedGradients = parseGradients(payload["gradients"] as? List<*>)
            val parsedLabels = parseLabels(payload["labels"] as? List<*>)
            return NativeDriveOverlayPayload(
                canvasWidth = (payload["canvasWidth"] as? Number)?.toFloat() ?: 0f,
                canvasHeight = (payload["canvasHeight"] as? Number)?.toFloat() ?: 0f,
                polygons = parsedPolygons,
                gradients = parsedGradients,
                labels = parsedLabels,
            )
        }

        private fun parsePolygons(rawPolygons: List<*>?): List<Polygon> {
            if (rawPolygons.isNullOrEmpty()) return emptyList()
            val out = ArrayList<Polygon>(rawPolygons.size)
            for (raw in rawPolygons) {
                val item = raw as? Map<*, *> ?: continue
                val pointsRaw = item["points"] as? List<*> ?: continue
                if (pointsRaw.size < 6 || pointsRaw.size % 2 != 0) continue
                val points = FloatArray(pointsRaw.size)
                var ok = true
                for (i in pointsRaw.indices) {
                    val number = pointsRaw[i] as? Number
                    if (number == null) {
                        ok = false
                        break
                    }
                    points[i] = number.toFloat()
                }
                if (!ok) continue
                out.add(
                    Polygon(
                        points = points,
                        fillColor = (item["fillColor"] as? Number)?.toInt() ?: Color.TRANSPARENT,
                        strokeColor = (item["strokeColor"] as? Number)?.toInt(),
                        strokeWidth = ((item["strokeWidth"] as? Number)?.toFloat() ?: 0f)
                            .coerceAtLeast(0f),
                    )
                )
            }
            return out
        }

        private fun parseGradients(rawGradients: List<*>?): List<GradientRect> {
            if (rawGradients.isNullOrEmpty()) return emptyList()
            val out = ArrayList<GradientRect>(rawGradients.size)
            for (raw in rawGradients) {
                val item = raw as? Map<*, *> ?: continue
                val left = (item["left"] as? Number)?.toFloat() ?: continue
                val top = (item["top"] as? Number)?.toFloat() ?: continue
                val right = (item["right"] as? Number)?.toFloat() ?: continue
                val bottom = (item["bottom"] as? Number)?.toFloat() ?: continue
                if (right <= left || bottom <= top) continue
                val startX = (item["startX"] as? Number)?.toFloat() ?: left
                val startY = (item["startY"] as? Number)?.toFloat() ?: top
                val endX = (item["endX"] as? Number)?.toFloat() ?: left
                val endY = (item["endY"] as? Number)?.toFloat() ?: bottom
                val colorsRaw = item["colors"] as? List<*> ?: continue
                val stopsRaw = item["stops"] as? List<*> ?: continue
                if (colorsRaw.size < 2 || colorsRaw.size != stopsRaw.size) continue
                val colors = IntArray(colorsRaw.size)
                val stops = FloatArray(stopsRaw.size)
                var ok = true
                for (i in colorsRaw.indices) {
                    val color = colorsRaw[i] as? Number
                    val stop = stopsRaw[i] as? Number
                    if (color == null || stop == null) {
                        ok = false
                        break
                    }
                    colors[i] = color.toInt()
                    stops[i] = stop.toFloat().coerceIn(0f, 1f)
                }
                if (!ok) continue
                out.add(
                    GradientRect(
                        left = left,
                        top = top,
                        right = right,
                        bottom = bottom,
                        startX = startX,
                        startY = startY,
                        endX = endX,
                        endY = endY,
                        colors = colors,
                        stops = stops,
                    )
                )
            }
            return out
        }

        private fun parseLabels(rawLabels: List<*>?): List<Label> {
            if (rawLabels.isNullOrEmpty()) return emptyList()
            val out = ArrayList<Label>(rawLabels.size)
            for (raw in rawLabels) {
                val item = raw as? Map<*, *> ?: continue
                val x = (item["x"] as? Number)?.toFloat() ?: continue
                val y = (item["y"] as? Number)?.toFloat() ?: continue
                val text = item["text"]?.toString()?.trim().orEmpty()
                if (text.isEmpty()) continue
                out.add(
                    Label(
                        x = x,
                        y = y,
                        text = text,
                        color = (item["color"] as? Number)?.toInt() ?: Color.WHITE,
                        size = ((item["size"] as? Number)?.toFloat() ?: 10f).coerceAtLeast(4f),
                        strokeColor = (item["strokeColor"] as? Number)?.toInt(),
                        strokeWidth = ((item["strokeWidth"] as? Number)?.toFloat() ?: 0f)
                            .coerceAtLeast(0f),
                        fontWeight = ((item["fontWeight"] as? Number)?.toInt() ?: 700)
                            .coerceIn(100, 900),
                        alignX = item["alignX"]?.toString()?.trim()?.ifEmpty { "left" } ?: "left",
                        alignY = item["alignY"]?.toString()?.trim()?.ifEmpty { "baseline" } ?: "baseline",
                        maxWidth = (item["maxWidth"] as? Number)?.toFloat()?.takeIf { it > 0f },
                        maxLines = (item["maxLines"] as? Number)?.toInt()?.takeIf { it > 0 },
                        ellipsis = item["ellipsis"]?.toString()?.trim()?.ifEmpty { null },
                    )
                )
            }
            return out
        }
    }
}
