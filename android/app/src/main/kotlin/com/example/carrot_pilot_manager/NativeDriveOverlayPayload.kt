package com.example.carrot_pilot_manager

import android.graphics.Color

internal data class NativeDriveOverlayPayload(
    val canvasWidth: Float,
    val canvasHeight: Float,
    val polygons: List<Polygon>,
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
    )

    val isEmpty: Boolean
        get() = polygons.isEmpty() && labels.isEmpty()

    val complexityScore: Float
        get() {
            val polygonScore = (polygons.size / 140f).coerceIn(0f, 1f)
            val labelScore = (labels.size / 16f).coerceIn(0f, 1f)
            val strokeScore = (polygons.count { it.strokeColor != null } / 72f).toFloat().coerceIn(0f, 1f)
            return ((polygonScore * 0.56f) + (labelScore * 0.28f) + (strokeScore * 0.16f))
                .coerceIn(0f, 1f)
        }

    companion object {
        fun fromPayload(payload: Map<String, Any?>?): NativeDriveOverlayPayload? {
            if (payload == null) return null
            val rawPolygons = payload["polygons"] as? List<*> ?: return null
            val parsedPolygons = parsePolygons(rawPolygons)
            val parsedLabels = parseLabels(payload["labels"] as? List<*>)
            return NativeDriveOverlayPayload(
                canvasWidth = (payload["canvasWidth"] as? Number)?.toFloat() ?: 0f,
                canvasHeight = (payload["canvasHeight"] as? Number)?.toFloat() ?: 0f,
                polygons = parsedPolygons,
                labels = parsedLabels,
            )
        }

        private fun parsePolygons(rawPolygons: List<*>): List<Polygon> {
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
                        size = ((item["size"] as? Number)?.toFloat() ?: 10f).coerceAtLeast(7f),
                    )
                )
            }
            return out
        }
    }
}
