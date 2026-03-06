package com.example.carrot_pilot_manager

internal data class NativeDriveArCardLayout(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
    val accentWidth: Float,
    val titleSize: Float,
    val bodySize: Float,
    val metaSize: Float,
    val textLeft: Float,
    val titleY: Float,
    val bodyY: Float,
    val metaY: Float,
)

internal data class NativeDriveArStatusPillLayout(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
    val radius: Float,
    val textSize: Float,
    val cueWidth: Float,
)

internal data class NativeDriveArGateChipLayout(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
    val radius: Float,
    val textSize: Float,
    val cueWidth: Float,
    val drawCenterX: Float,
    val tetherAnchorX: Float,
    val tetherAnchorY: Float,
    val accentWidth: Float,
)

internal object NativeDriveArShellLayout {
    fun card(
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        compactLayout: Boolean,
    ): NativeDriveArCardLayout {
        val profile = NativeDriveArLayoutProfileTuning.resolve(scene.presentation.layoutProfile)
        val showMeta = scene.presentation.showMeta && !compactLayout
        val width =
            (drawWidth *
                if (compactLayout) profile.cardCompactWidthFraction else profile.cardRegularWidthFraction)
                .coerceIn(172f, 290f)
        val height =
            (drawHeight *
                if (showMeta) profile.cardMetaHeightFraction else profile.cardBodyHeightFraction)
                .coerceIn(52f, 92f)
        val left = 18f * strokeScale
        val top = 18f * strokeScale
        val accentWidth = (5f * strokeScale).coerceAtLeast(4f)
        val titleSize = (11f * strokeScale).coerceIn(10f, 18f)
        val bodySize = (((if (compactLayout) 12f else 13f) * strokeScale)).coerceIn(11f, 20f)
        val metaSize = (10f * strokeScale).coerceIn(9f, 16f)
        val textLeft = left + accentWidth + (12f * strokeScale)
        val titleY = top + (18f * strokeScale)
        val bodyY = if (showMeta) top + (39f * strokeScale) else top + (34f * strokeScale)
        val metaY = top + height - (10f * strokeScale)
        return NativeDriveArCardLayout(
            left = left,
            top = top,
            width = width,
            height = height,
            accentWidth = accentWidth,
            titleSize = titleSize,
            bodySize = bodySize,
            metaSize = metaSize,
            textLeft = textLeft,
            titleY = titleY,
            bodyY = bodyY,
            metaY = metaY,
        )
    }

    fun statusPill(
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
        textWidth: Float,
        cueWidth: Float,
    ): NativeDriveArStatusPillLayout {
        val compactLayout = policy.compactLayout
        val profile = NativeDriveArLayoutProfileTuning.resolve(scene.presentation.layoutProfile)
        val radius = (18f * strokeScale).coerceIn(16f, 28f)
        val textSize = (13f * strokeScale).coerceIn(11f, 19f)
        val horizontalPadding =
            (if (compactLayout) profile.statusHorizontalPaddingCompact else profile.statusHorizontalPaddingRegular) *
                strokeScale
        val width =
            textWidth + (horizontalPadding * 2f) +
                if (cueWidth > 0f) cueWidth + (10f * strokeScale) else 0f
        val height = (radius * 2f).coerceIn(34f, 54f)
        val safeInset = 12f * strokeScale
        val fallbackCenterX = drawWidth * 0.5f
        val fallbackCenterY = drawHeight - (22f * strokeScale) - (height * 0.5f)
        val anchor = if (policy.preferAnchoredStatus) scene.screenAnchors?.statusAnchor else null
        val centerX =
            clampCenter(
                center =
                    NativeDriveArGeometry.blendedScalar(
                        fallback = fallbackCenterX,
                        anchor = anchor?.x,
                        blend = if (policy.preferAnchoredStatus) policy.anchoredPlacementBlend else 0f,
                    ),
                halfExtent = width * 0.5f,
                fullExtent = drawWidth,
                inset = safeInset,
            )
        val centerY =
            clampCenter(
                center =
                    NativeDriveArGeometry.blendedScalar(
                        fallback = fallbackCenterY,
                        anchor = anchor?.y,
                        blend = if (policy.preferAnchoredStatus) policy.anchoredPlacementBlend else 0f,
                    ),
                halfExtent = height * 0.5f,
                fullExtent = drawHeight,
                inset = safeInset,
            )
        return NativeDriveArStatusPillLayout(
            left = centerX - (width * 0.5f),
            top = centerY - (height * 0.5f),
            width = width,
            height = height,
            radius = radius,
            textSize = textSize,
            cueWidth = cueWidth,
        )
    }

    fun gateChip(
        scene: NativeDriveArScene,
        drawWidth: Float,
        drawHeight: Float,
        strokeScale: Float,
        policy: NativeDriveArRenderPolicy,
        textWidth: Float,
        cueWidth: Float,
    ): NativeDriveArGateChipLayout? {
        val anchor = scene.screenAnchors?.gateAnchor ?: return null
        val compactLayout = policy.compactLayout
        val profile = NativeDriveArLayoutProfileTuning.resolve(scene.presentation.layoutProfile)
        val emphasized = scene.presentation.distanceBucket == "immediate"
        val anchoredBlend = policy.anchoredPlacementBlend
        val chipHeight =
            (
                (if (compactLayout) profile.gateCompactHeight else profile.gateRegularHeight) *
                    strokeScale *
                    if (emphasized) 1.08f else 1f
            )
                .coerceIn(30f, 52f)
        val radius = chipHeight * 0.48f
        val textSize =
            (
                (if (compactLayout) profile.gateCompactTextSize else profile.gateRegularTextSize) *
                    strokeScale *
                    if (emphasized) 1.06f else 1f
            )
                .coerceIn(10f, 19f)
        val horizontalPadding = (15f * strokeScale).coerceAtLeast(12f)
        val width =
            textWidth + (horizontalPadding * 2f) +
                if (cueWidth > 0f) cueWidth + (10f * strokeScale) else 0f
        val safeInset = 12f * strokeScale
        val fallbackCenterX =
            NativeDriveArGeometry.defaultDirectionalCenterX(
                scene.presentation.turnDirectionKey.ifBlank { scene.turnCue?.directionKey.orEmpty() },
                drawWidth,
            )
        val fallbackAnchorY =
            NativeDriveArGuideTuning.gateFallbackAnchorY(
                scene.presentation.distanceBucket,
                drawHeight,
            )
        val centerX =
            clampCenter(
                center =
                    NativeDriveArGeometry.blendedScalar(
                        fallback = fallbackCenterX,
                        anchor = anchor.x,
                        blend = anchoredBlend,
                    ),
                halfExtent = width * 0.5f,
                fullExtent = drawWidth,
                inset = safeInset,
            )
        val requestedCenterY =
            NativeDriveArGeometry.blendedScalar(
                fallback = fallbackAnchorY,
                anchor = anchor.y,
                blend = anchoredBlend,
            ) - (chipHeight * 0.95f) - (24f * strokeScale)
        val minCenterY = safeInset + (chipHeight * 0.5f)
        val maxCenterY = drawHeight - safeInset - (chipHeight * 0.5f)
        var centerY = requestedCenterY.coerceIn(minCenterY, maxCenterY)
        var left = centerX - (width * 0.5f)
        var top = centerY - (chipHeight * 0.5f)
        if (policy.drawCard) {
            val reservedCard = card(scene, drawWidth, drawHeight, strokeScale, compactLayout)
            val reservedWidth = reservedCard.width + (24f * strokeScale)
            val reservedHeight = reservedCard.height + (24f * strokeScale)
            if (left < reservedWidth && top < reservedHeight) {
                centerY = (reservedHeight + (chipHeight * 0.5f)).coerceIn(minCenterY, maxCenterY)
                left = centerX - (width * 0.5f)
                top = centerY - (chipHeight * 0.5f)
            }
        }
        val statusAnchorY = scene.screenAnchors?.statusAnchor?.y
        if (statusAnchorY != null) {
            val safeBottom = statusAnchorY - chipHeight - (22f * strokeScale)
            top = top.coerceAtMost(safeBottom)
        }
        left = clampStart(left, width, drawWidth, safeInset)
        top = clampStart(top, chipHeight, drawHeight, safeInset)
        return NativeDriveArGateChipLayout(
            left = left,
            top = top,
            width = width,
            height = chipHeight,
            radius = radius,
            textSize = textSize,
            cueWidth = cueWidth,
            drawCenterX = left + (width * 0.5f),
            tetherAnchorX = NativeDriveArGeometry.blendedScalar(fallbackCenterX, anchor.x, anchoredBlend),
            tetherAnchorY = NativeDriveArGeometry.blendedScalar(fallbackAnchorY, anchor.y, anchoredBlend),
            accentWidth = (4.5f * strokeScale).coerceAtLeast(4f),
        )
    }

    private fun clampCenter(
        center: Float,
        halfExtent: Float,
        fullExtent: Float,
        inset: Float,
    ): Float {
        val minCenter = inset + halfExtent
        val maxCenter = (fullExtent - inset - halfExtent).coerceAtLeast(minCenter)
        return center.coerceIn(minCenter, maxCenter)
    }

    private fun clampStart(
        start: Float,
        extent: Float,
        fullExtent: Float,
        inset: Float,
    ): Float {
        val maxStart = (fullExtent - inset - extent).coerceAtLeast(inset)
        return start.coerceIn(inset, maxStart)
    }
}
