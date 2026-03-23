import 'package:flutter/services.dart';

class YoloAndroidDeviceProfile {
  const YoloAndroidDeviceProfile({
    required this.platform,
    required this.manufacturer,
    required this.brand,
    required this.model,
    required this.device,
    required this.hardware,
    required this.board,
    required this.product,
    required this.socModel,
    required this.socManufacturer,
    required this.supportedAbis,
  });

  static const unknown = YoloAndroidDeviceProfile(
    platform: '',
    manufacturer: '',
    brand: '',
    model: '',
    device: '',
    hardware: '',
    board: '',
    product: '',
    socModel: '',
    socManufacturer: '',
    supportedAbis: <String>[],
  );

  final String platform;
  final String manufacturer;
  final String brand;
  final String model;
  final String device;
  final String hardware;
  final String board;
  final String product;
  final String socModel;
  final String socManufacturer;
  final List<String> supportedAbis;

  String get _soc => socModel.trim().toLowerCase();

  bool get allowsYolo26sByDefault {
    const highEndSocMarkers = <String>[
      'sm8550',
      'sm8650',
      'sm8750',
      'exynos2400',
    ];
    return highEndSocMarkers.any(_soc.contains);
  }

  factory YoloAndroidDeviceProfile.fromMap(Map<Object?, Object?> raw) {
    String readString(String key) => raw[key]?.toString().trim() ?? '';
    List<String> readList(String key) {
      final value = raw[key];
      if (value is List) {
        return value.map((item) => item.toString()).toList(growable: false);
      }
      return const <String>[];
    }

    return YoloAndroidDeviceProfile(
      platform: readString('platform'),
      manufacturer: readString('manufacturer'),
      brand: readString('brand'),
      model: readString('model'),
      device: readString('device'),
      hardware: readString('hardware'),
      board: readString('board'),
      product: readString('product'),
      socModel: readString('socModel'),
      socManufacturer: readString('socManufacturer'),
      supportedAbis: readList('supportedAbis'),
    );
  }
}

class YoloDeviceProfileService {
  YoloDeviceProfileService._();

  static const MethodChannel _channel =
      MethodChannel('carrotlink/device_profile');

  static Future<YoloAndroidDeviceProfile>? _pending;
  static YoloAndroidDeviceProfile? _cached;

  static Future<YoloAndroidDeviceProfile> load() {
    final cached = _cached;
    if (cached != null) {
      return Future<YoloAndroidDeviceProfile>.value(cached);
    }
    final pending = _pending;
    if (pending != null) {
      return pending;
    }
    final future = _loadInternal();
    _pending = future;
    return future;
  }

  static Future<YoloAndroidDeviceProfile> _loadInternal() async {
    try {
      final raw =
          await _channel.invokeMethod<dynamic>('getAndroidDeviceProfile');
      if (raw is Map) {
        final profile = YoloAndroidDeviceProfile.fromMap(raw);
        _cached = profile;
        return profile;
      }
    } on MissingPluginException {
      // Widget tests and non-Android targets can ignore this and use defaults.
    } catch (_) {}
    const fallback = YoloAndroidDeviceProfile.unknown;
    _cached = fallback;
    return fallback;
  }
}
