package com.example.carrot_pilot_manager

internal data class NativeDriveArLayoutProfileSpec(
    val key: String,
    val forceCompact: Boolean,
    val nonArrivalBudgetCap: Int?,
    val supportsAnchoredStatus: Boolean,
    val supportsAnchoredGuide: Boolean,
    val supportsTrail: Boolean,
    val supportsGuideSecondary: Boolean,
    val supportsCard: Boolean,
    val supportsGateChip: Boolean,
    val cardCompactWidthFraction: Float,
    val cardRegularWidthFraction: Float,
    val cardMetaHeightFraction: Float,
    val cardBodyHeightFraction: Float,
    val statusHorizontalPaddingCompact: Float,
    val statusHorizontalPaddingRegular: Float,
    val gateCompactHeight: Float,
    val gateRegularHeight: Float,
    val gateCompactTextSize: Float,
    val gateRegularTextSize: Float,
) {
    val isWideMonitor: Boolean
        get() = key == "wide_monitor"
}

internal object NativeDriveArLayoutProfileTuning {
    private val roadAttached =
        NativeDriveArLayoutProfileSpec(
            key = "road_attached",
            forceCompact = false,
            nonArrivalBudgetCap = null,
            supportsAnchoredStatus = true,
            supportsAnchoredGuide = true,
            supportsTrail = true,
            supportsGuideSecondary = true,
            supportsCard = true,
            supportsGateChip = true,
            cardCompactWidthFraction = 0.21f,
            cardRegularWidthFraction = 0.24f,
            cardMetaHeightFraction = 0.11f,
            cardBodyHeightFraction = 0.085f,
            statusHorizontalPaddingCompact = 14f,
            statusHorizontalPaddingRegular = 18f,
            gateCompactHeight = 34f,
            gateRegularHeight = 38f,
            gateCompactTextSize = 11.5f,
            gateRegularTextSize = 12.5f,
        )

    private val wideMonitor =
        NativeDriveArLayoutProfileSpec(
            key = "wide_monitor",
            forceCompact = true,
            nonArrivalBudgetCap = 1,
            supportsAnchoredStatus = false,
            supportsAnchoredGuide = false,
            supportsTrail = false,
            supportsGuideSecondary = false,
            supportsCard = false,
            supportsGateChip = false,
            cardCompactWidthFraction = 0.21f,
            cardRegularWidthFraction = 0.24f,
            cardMetaHeightFraction = 0.11f,
            cardBodyHeightFraction = 0.085f,
            statusHorizontalPaddingCompact = 14f,
            statusHorizontalPaddingRegular = 18f,
            gateCompactHeight = 34f,
            gateRegularHeight = 38f,
            gateCompactTextSize = 11.5f,
            gateRegularTextSize = 12.5f,
        )

    fun resolve(layoutProfile: String): NativeDriveArLayoutProfileSpec =
        when (layoutProfile) {
            "wide_monitor" -> wideMonitor
            else -> roadAttached
        }

    fun buildDebugMap(layoutProfile: String?): Map<String, Any?> {
        val profile = resolve(layoutProfile.orEmpty())
        return mapOf(
            "key" to profile.key,
            "forceCompact" to profile.forceCompact,
            "nonArrivalBudgetCap" to profile.nonArrivalBudgetCap,
            "supportsAnchoredStatus" to profile.supportsAnchoredStatus,
            "supportsAnchoredGuide" to profile.supportsAnchoredGuide,
            "supportsTrail" to profile.supportsTrail,
            "supportsGuideSecondary" to profile.supportsGuideSecondary,
            "supportsCard" to profile.supportsCard,
            "supportsGateChip" to profile.supportsGateChip,
            "cardCompactWidthFraction" to profile.cardCompactWidthFraction,
            "cardRegularWidthFraction" to profile.cardRegularWidthFraction,
            "statusHorizontalPaddingCompact" to profile.statusHorizontalPaddingCompact,
            "statusHorizontalPaddingRegular" to profile.statusHorizontalPaddingRegular,
            "gateCompactHeight" to profile.gateCompactHeight,
            "gateRegularHeight" to profile.gateRegularHeight,
            "gateCompactTextSize" to profile.gateCompactTextSize,
            "gateRegularTextSize" to profile.gateRegularTextSize,
        )
    }
}
