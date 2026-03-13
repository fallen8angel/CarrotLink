package com.example.carrot_pilot_manager

internal data class NativeDriveArScene(
    val sceneVersion: Int,
    val cameraKind: String,
    val routePoints: List<RoutePoint>,
    val turnCue: TurnCue?,
    val health: Health,
    val presentation: Presentation,
    val screenAnchors: ScreenAnchors?,
    val summary: Summary,
) {
    data class RoutePoint(
        val x: Float,
        val y: Float,
        val d: Float,
    )

    data class TurnCue(
        val turnInfo: Int,
        val distanceMeters: Float?,
        val primaryText: String,
        val isArrival: Boolean,
        val directionKey: String,
    )

    data class Health(
        val modelFrameId: Int?,
        val cameraFrameId: Int?,
        val frameGap: Int?,
        val frameGapOk: Boolean,
        val calibrationOk: Boolean,
        val hasRoute: Boolean,
        val hasTurnCue: Boolean,
    )

    data class Summary(
        val statusText: String,
        val turnLabel: String,
        val routePointCount: Int,
    )

    data class Presentation(
        val mode: String,
        val accentKey: String,
        val layoutProfile: String,
        val turnDirectionKey: String,
        val distanceBucket: String,
        val renderBudget: Int,
        val shellAlphaHint: Float,
        val showGuidePrimitive: Boolean,
        val showGuideTrail: Boolean,
        val showCard: Boolean,
        val showStatusPill: Boolean,
        val showMeta: Boolean,
        val compactPreferred: Boolean,
        val detailLevel: Int,
        val emphasisLevel: Int,
        val guideAlpha: Float,
        val trailAlpha: Float,
    )

    data class ScreenPoint(
        val x: Float,
        val y: Float,
    )

    data class ScreenAnchors(
        val pathPoints: List<ScreenPoint>,
        val pathDistances: List<Float>,
        val gateAnchor: ScreenPoint?,
        val statusAnchor: ScreenPoint?,
        val visibleDistanceMeters: Float,
        val pathSpanX: Float,
        val pathSpanY: Float,
        val qualityScore: Float,
    ) {
        val hasPath: Boolean
            get() = pathPoints.size >= 2

        val hasStablePath: Boolean
            get() = hasPath && qualityScore >= 0.34f && visibleDistanceMeters >= 10f

        fun supportsAnchoredGuide(mode: String): Boolean =
            when (mode) {
                "arrival" -> hasPath && qualityScore >= 0.28f
                "turn" -> hasStablePath
                "route" -> hasStablePath
                else -> false
            }

        fun supportsGateChip(mode: String): Boolean =
            gateAnchor != null &&
                mode in setOf("turn", "arrival") &&
                qualityScore >= 0.30f

        fun supportsAnchoredStatus(): Boolean =
            statusAnchor != null && qualityScore >= 0.18f
    }

    val hasRoute: Boolean
        get() = routePoints.size >= 2

    val isEmpty: Boolean
        get() = !hasRoute && turnCue == null

    fun statusLabel(): String {
        if (summary.statusText.isNotBlank()) return summary.statusText
        if (!health.calibrationOk) return "캘리브레이션 대기"
        if (!health.frameGapOk) return "프레임 정합 대기"
        if (turnCue?.isArrival == true) return "도착 임박"
        if (hasRoute) return "정상 경로"
        return "경로 탐색 중"
    }

    fun turnLabel(): String {
        if (summary.turnLabel.isNotBlank()) return summary.turnLabel
        val cue = turnCue ?: return ""
        val text = cue.primaryText.trim().ifEmpty { fallbackTurnText(cue.turnInfo) }
        val distanceText = formatDistanceMeters(cue.distanceMeters)
        if (text.isEmpty()) return distanceText
        if (distanceText.isEmpty()) return text
        return "$distanceText $text"
    }

    companion object {
        fun fromPayload(payload: Map<String, Any?>?): NativeDriveArScene? {
            if (payload == null) return null
            val routePoints = parseRoutePoints(payload["routePoints"])
            val turnCue = parseTurnCue(payload["turnCue"])
            val health = parseHealth(payload["health"])
            val scene = NativeDriveArScene(
                sceneVersion = payload.readInt("sceneVersion") ?: 0,
                cameraKind = payload.readString("cameraKind").orEmpty(),
                routePoints = routePoints,
                turnCue = turnCue,
                health = health,
                presentation = parsePresentation(payload["presentation"], turnCue),
                screenAnchors = parseScreenAnchors(payload["screenAnchors"]),
                summary = parseSummary(payload["summary"], routePoints.size),
            )
            return if (scene.isEmpty) null else scene
        }

        private fun parseRoutePoints(raw: Any?): List<RoutePoint> {
            val list = raw as? List<*> ?: return emptyList()
            val out = ArrayList<RoutePoint>(list.size)
            for (entry in list) {
                val point = entry as? List<*> ?: continue
                if (point.size < 3) continue
                val x = (point[0] as? Number)?.toFloat() ?: continue
                val y = (point[1] as? Number)?.toFloat() ?: continue
                val d = (point[2] as? Number)?.toFloat() ?: continue
                out.add(RoutePoint(x = x, y = y, d = d))
            }
            return out
        }

        private fun parseTurnCue(raw: Any?): TurnCue? {
            val map = raw as? Map<*, *> ?: return null
            val turnInfo = map.readInt("turnInfo") ?: 0
            val primaryText = map.readString("primaryText").orEmpty()
            if (turnInfo == 0 && primaryText.isBlank()) return null
            return TurnCue(
                turnInfo = turnInfo,
                distanceMeters = map.readFloat("distanceMeters"),
                primaryText = primaryText,
                isArrival = map.readBool("isArrival") ?: false,
                directionKey = map.readString("directionKey").orEmpty(),
            )
        }

        private fun parseHealth(raw: Any?): Health {
            val map = raw as? Map<*, *>
            return Health(
                modelFrameId = map.readInt("modelFrameId"),
                cameraFrameId = map.readInt("cameraFrameId"),
                frameGap = map.readInt("frameGap"),
                frameGapOk = map.readBool("frameGapOk") ?: true,
                calibrationOk = map.readBool("calibrationOk") ?: false,
                hasRoute = map.readBool("hasRoute") ?: false,
                hasTurnCue = map.readBool("hasTurnCue") ?: false,
            )
        }

        private fun parseSummary(raw: Any?, routePointCount: Int): Summary {
            val map = raw as? Map<*, *>
            return Summary(
                statusText = map.readString("statusText").orEmpty(),
                turnLabel = map.readString("turnLabel").orEmpty(),
                routePointCount = map.readInt("routePointCount") ?: routePointCount,
            )
        }

        private fun parsePresentation(raw: Any?, turnCue: TurnCue?): Presentation {
            val map = raw as? Map<*, *>
            return Presentation(
                mode = map.readString("mode").orEmpty(),
                accentKey = map.readString("accentKey").orEmpty(),
                layoutProfile = map.readString("layoutProfile").orEmpty(),
                turnDirectionKey = map.readString("turnDirectionKey")
                    ?.ifBlank { turnCue?.directionKey.orEmpty() }
                    .orEmpty(),
                distanceBucket = map.readString("distanceBucket").orEmpty(),
                renderBudget = map.readInt("renderBudget") ?: 0,
                shellAlphaHint = map.readFloat("shellAlphaHint") ?: 1f,
                showGuidePrimitive = map.readBool("showGuidePrimitive") ?: false,
                showGuideTrail = map.readBool("showGuideTrail") ?: false,
                showCard = map.readBool("showCard") ?: true,
                showStatusPill = map.readBool("showStatusPill") ?: true,
                showMeta = map.readBool("showMeta") ?: false,
                compactPreferred = map.readBool("compactPreferred") ?: false,
                detailLevel = map.readInt("detailLevel") ?: 0,
                emphasisLevel = map.readInt("emphasisLevel") ?: 0,
                guideAlpha = map.readFloat("guideAlpha") ?: 0f,
                trailAlpha = map.readFloat("trailAlpha") ?: 0f,
            )
        }

        private fun parseScreenAnchors(raw: Any?): ScreenAnchors? {
            val map = raw as? Map<*, *> ?: return null
            val pathPoints = parseScreenPoints(map["pathPoints"])
            val pathDistances = parseFloatList(map["pathDistances"])
            val gateAnchor = parseScreenPoint(map["gateAnchor"])
            val statusAnchor = parseScreenPoint(map["statusAnchor"])
            return ScreenAnchors(
                pathPoints = pathPoints,
                pathDistances = pathDistances,
                gateAnchor = gateAnchor,
                statusAnchor = statusAnchor,
                visibleDistanceMeters = map.readFloat("visibleDistanceMeters") ?: 0f,
                pathSpanX = map.readFloat("pathSpanX") ?: 0f,
                pathSpanY = map.readFloat("pathSpanY") ?: 0f,
                qualityScore = map.readFloat("qualityScore") ?: 0f,
            )
        }

        private fun parseScreenPoints(raw: Any?): List<ScreenPoint> {
            val list = raw as? List<*> ?: return emptyList()
            val out = ArrayList<ScreenPoint>(list.size)
            for (entry in list) {
                val point = parseScreenPoint(entry) ?: continue
                out.add(point)
            }
            return out
        }

        private fun parseScreenPoint(raw: Any?): ScreenPoint? {
            val point = raw as? List<*> ?: return null
            if (point.size < 2) return null
            val x = (point[0] as? Number)?.toFloat() ?: return null
            val y = (point[1] as? Number)?.toFloat() ?: return null
            return ScreenPoint(x = x, y = y)
        }

        private fun parseFloatList(raw: Any?): List<Float> {
            val list = raw as? List<*> ?: return emptyList()
            val out = ArrayList<Float>(list.size)
            for (entry in list) {
                val value = (entry as? Number)?.toFloat() ?: continue
                out.add(value)
            }
            return out
        }

        private fun fallbackTurnText(turnInfo: Int): String =
            when (turnInfo) {
                1 -> "좌회전"
                2 -> "우회전"
                3 -> "좌차선 변경"
                4 -> "우차선 변경"
                7 -> "유턴"
                8 -> "도착"
                else -> ""
            }

        private fun formatDistanceMeters(distanceMeters: Float?): String {
            if (distanceMeters == null || !distanceMeters.isFinite() || distanceMeters <= 0f) {
                return ""
            }
            if (distanceMeters >= 1000f) {
                return String.format("%.1fkm", distanceMeters / 1000f)
            }
            return "${distanceMeters.toInt()}m"
        }

        private fun Map<String, Any?>.readInt(key: String): Int? =
            (this[key] as? Number)?.toInt()
    }
}

private fun Map<*, *>?.readInt(key: String): Int? =
    (this?.get(key) as? Number)?.toInt()

private fun Map<*, *>?.readFloat(key: String): Float? =
    (this?.get(key) as? Number)?.toFloat()

private fun Map<*, *>?.readBool(key: String): Boolean? =
    when (val value = this?.get(key)) {
        is Boolean -> value
        is Number -> value.toInt() != 0
        is String -> {
            when (value.trim().lowercase()) {
                "true", "1" -> true
                "false", "0" -> false
                else -> null
            }
        }
        else -> null
    }

private fun Map<*, *>?.readString(key: String): String? =
    this?.get(key)?.toString()
