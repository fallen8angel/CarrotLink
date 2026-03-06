package com.example.carrot_pilot_manager

internal class NativeDriveArSceneSanitizer {
    private var lastDebug: Map<String, Any?> = mapOf("enabled" to false)

    fun sanitize(scene: NativeDriveArScene?): NativeDriveArScene? {
        if (scene == null) {
            lastDebug = mapOf("enabled" to false, "reason" to "scene_null")
            return null
        }
        val routePoints = sanitizeRoutePoints(scene.routePoints)
        val turnCue = sanitizeTurnCue(scene.turnCue)
        val presentation = sanitizePresentation(scene.presentation)
        val screenAnchors = sanitizeScreenAnchors(scene.screenAnchors)
        val sanitized =
            scene.copy(
                routePoints = routePoints,
                turnCue = turnCue,
                presentation = presentation,
                screenAnchors = screenAnchors,
                summary =
                    scene.summary.copy(
                        routePointCount = routePoints.size,
                    ),
            )
        lastDebug =
            mapOf(
                "enabled" to true,
                "routePoints" to routePoints.size,
                "hasTurnCue" to (turnCue != null),
                "layoutProfile" to presentation.layoutProfile,
                "renderBudget" to presentation.renderBudget,
                "screenAnchors" to
                    mapOf(
                        "hasAnchors" to (screenAnchors != null),
                        "pathPoints" to (screenAnchors?.pathPoints?.size ?: 0),
                        "pathDistances" to (screenAnchors?.pathDistances?.size ?: 0),
                        "hasGate" to (screenAnchors?.gateAnchor != null),
                        "hasStatus" to (screenAnchors?.statusAnchor != null),
                        "qualityScore" to (screenAnchors?.qualityScore ?: 0f),
                    ),
            )
        return if (sanitized.isEmpty) null else sanitized
    }

    fun buildDebugMap(): Map<String, Any?> = lastDebug

    private fun sanitizeRoutePoints(
        routePoints: List<NativeDriveArScene.RoutePoint>,
    ): List<NativeDriveArScene.RoutePoint> =
        routePoints.filter {
            it.x.isFinite() && it.y.isFinite() && it.d.isFinite()
        }

    private fun sanitizeTurnCue(
        turnCue: NativeDriveArScene.TurnCue?,
    ): NativeDriveArScene.TurnCue? {
        turnCue ?: return null
        val distanceMeters =
            turnCue.distanceMeters
                ?.takeIf { it.isFinite() && it >= 0f }
        return turnCue.copy(
            distanceMeters = distanceMeters,
            primaryText = turnCue.primaryText.trim(),
            directionKey = turnCue.directionKey.trim(),
        )
    }

    private fun sanitizePresentation(
        presentation: NativeDriveArScene.Presentation,
    ): NativeDriveArScene.Presentation =
        presentation.copy(
            mode = presentation.mode.trim(),
            accentKey = presentation.accentKey.trim(),
            layoutProfile = presentation.layoutProfile.trim(),
            turnDirectionKey = presentation.turnDirectionKey.trim(),
            distanceBucket = presentation.distanceBucket.trim(),
            renderBudget = presentation.renderBudget.coerceIn(0, 3),
            shellAlphaHint = presentation.shellAlphaHint.coerceIn(0f, 1f),
            detailLevel = presentation.detailLevel.coerceIn(0, 4),
            emphasisLevel = presentation.emphasisLevel.coerceIn(0, 4),
            guideAlpha = presentation.guideAlpha.coerceIn(0f, 1f),
            trailAlpha = presentation.trailAlpha.coerceIn(0f, 1f),
        )

    private fun sanitizeScreenAnchors(
        anchors: NativeDriveArScene.ScreenAnchors?,
    ): NativeDriveArScene.ScreenAnchors? {
        anchors ?: return null
        val points = anchors.pathPoints.filter { it.x.isFinite() && it.y.isFinite() }
        val distances =
            if (anchors.pathDistances.size == anchors.pathPoints.size) {
                val out = ArrayList<Float>(points.size)
                for (i in points.indices) {
                    val value = anchors.pathDistances.getOrNull(i)
                    if (value != null && value.isFinite() && value >= 0f) {
                        out.add(value)
                    }
                }
                if (out.size == points.size) out else emptyList()
            } else {
                emptyList()
            }
        val gateAnchor = anchors.gateAnchor?.takeIf { it.x.isFinite() && it.y.isFinite() }
        val statusAnchor = anchors.statusAnchor?.takeIf { it.x.isFinite() && it.y.isFinite() }
        val sanitized =
            anchors.copy(
                pathPoints = points,
                pathDistances = distances,
                gateAnchor = gateAnchor,
                statusAnchor = statusAnchor,
                visibleDistanceMeters =
                    anchors.visibleDistanceMeters.takeIf { it.isFinite() && it >= 0f } ?: 0f,
                pathSpanX = anchors.pathSpanX.takeIf { it.isFinite() && it >= 0f } ?: 0f,
                pathSpanY = anchors.pathSpanY.takeIf { it.isFinite() && it >= 0f } ?: 0f,
                qualityScore = anchors.qualityScore.coerceIn(0f, 1f),
            )
        return if (
            sanitized.pathPoints.size < 2 &&
            sanitized.gateAnchor == null &&
            sanitized.statusAnchor == null
        ) {
            null
        } else {
            sanitized
        }
    }
}
