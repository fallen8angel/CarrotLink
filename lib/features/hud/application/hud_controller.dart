import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/entities/original_hud_snapshot.dart';
import '../domain/repositories/hud_repository.dart';
import 'hud_controller_state.dart';

class HudController extends ChangeNotifier {
  final HudRepository _repository;

  HudController(this._repository);

  StreamSubscription<OriginalHudSnapshot>? _subscription;
  HudControllerState _state = HudControllerState.idle;

  HudControllerState get state => _state;

  Future<void> bindLive(String host) async {
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty) {
      return;
    }
    if (!_state.isPreview &&
        _state.host == normalizedHost &&
        _subscription != null) {
      return;
    }
    await _bind(
      isPreview: false,
      host: normalizedHost,
      stream: _repository.watchLive(host: normalizedHost),
    );
  }

  Future<void> bindPreview() async {
    if (_state.isPreview && _subscription != null) {
      return;
    }
    await _bind(
      isPreview: true,
      host: null,
      stream: _repository.watchPreview(),
    );
  }

  Future<void> warmUp(String host) {
    return _repository.warmUp(host: host);
  }

  Future<OriginalHudSnapshot?> getLatest({
    String? host,
  }) {
    return _repository.getLatest(host: host ?? _state.host);
  }

  Future<void> clear({
    bool releaseHost = false,
  }) async {
    final host = _state.host;
    await _subscription?.cancel();
    _subscription = null;
    if (releaseHost && host != null && host.trim().isNotEmpty) {
      await _repository.disposeHost(host);
    }
    _state = HudControllerState.idle;
    notifyListeners();
  }

  void reportBindingError({
    required String? host,
    required bool isPreview,
    required Object error,
    StackTrace? stackTrace,
  }) {
    _state = _state.copyWith(
      isLoading: false,
      isPreview: isPreview,
      host: host,
      lastError: error,
      lastStackTrace: stackTrace,
    );
    notifyListeners();
  }

  Future<void> _bind({
    required bool isPreview,
    required String? host,
    required Stream<OriginalHudSnapshot> stream,
  }) async {
    await _subscription?.cancel();
    _state = _state.copyWith(
      isLoading: true,
      isPreview: isPreview,
      host: host,
      resetError: true,
    );
    notifyListeners();

    _subscription = stream.listen((snapshot) {
      _state = _state.copyWith(
        snapshot: snapshot,
        isLoading: false,
        isPreview: isPreview,
        host: host,
        updateCount: _state.updateCount + 1,
        resetError: true,
      );
      notifyListeners();
    }, onError: (error, stackTrace) {
      _state = _state.copyWith(
        isLoading: false,
        isPreview: isPreview,
        host: host,
        lastError: error,
        lastStackTrace: stackTrace,
      );
      notifyListeners();
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
