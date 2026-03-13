import '../entities/original_hud_snapshot.dart';

abstract interface class HudRepository {
  Stream<OriginalHudSnapshot> watchLive({required String host});
  Stream<OriginalHudSnapshot> watchPreview();
  Future<OriginalHudSnapshot?> getLatest({String? host});
  Future<void> warmUp({required String host});
  Future<void> disposeHost(String host);
  Future<void> dispose();
}
