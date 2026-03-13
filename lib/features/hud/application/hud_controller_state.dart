import '../domain/entities/original_hud_snapshot.dart';

class HudControllerState {
  final OriginalHudSnapshot snapshot;
  final bool isLoading;
  final bool isPreview;
  final String? host;
  final Object? lastError;
  final StackTrace? lastStackTrace;
  final int updateCount;

  const HudControllerState({
    this.snapshot = OriginalHudSnapshot.empty,
    this.isLoading = false,
    this.isPreview = false,
    this.host,
    this.lastError,
    this.lastStackTrace,
    this.updateCount = 0,
  });

  static const idle = HudControllerState();

  HudControllerState copyWith({
    OriginalHudSnapshot? snapshot,
    bool? isLoading,
    bool? isPreview,
    String? host,
    Object? lastError,
    StackTrace? lastStackTrace,
    int? updateCount,
    bool resetError = false,
  }) {
    return HudControllerState(
      snapshot: snapshot ?? this.snapshot,
      isLoading: isLoading ?? this.isLoading,
      isPreview: isPreview ?? this.isPreview,
      host: host ?? this.host,
      lastError: resetError ? null : (lastError ?? this.lastError),
      lastStackTrace:
          resetError ? null : (lastStackTrace ?? this.lastStackTrace),
      updateCount: updateCount ?? this.updateCount,
    );
  }
}
