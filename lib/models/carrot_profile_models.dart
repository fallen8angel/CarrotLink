import 'carrot_settings_models.dart';

class CarrotProfileHeader {
  final String id;
  final String name;
  final int createdAtMs;
  final int updatedAtMs;
  final String sourceBranch;
  final String? sourceDongleId;
  final String? sourceSerial;
  final String? sourceCar;
  final int paramCount;
  final String schemaVersion;

  const CarrotProfileHeader({
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.sourceBranch,
    required this.sourceDongleId,
    required this.sourceSerial,
    required this.sourceCar,
    required this.paramCount,
    required this.schemaVersion,
  });

  factory CarrotProfileHeader.fromJson(Map<String, dynamic> json) {
    return CarrotProfileHeader(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      createdAtMs: _asInt(json['createdAtMs']) ?? 0,
      updatedAtMs: _asInt(json['updatedAtMs']) ?? 0,
      sourceBranch: (json['sourceBranch'] ?? '').toString(),
      sourceDongleId: _asString(json['sourceDongleId']),
      sourceSerial: _asString(json['sourceSerial']),
      sourceCar: _asString(json['sourceCar']),
      paramCount: _asInt(json['paramCount']) ?? 0,
      schemaVersion: (json['schemaVersion'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAtMs': createdAtMs,
        'updatedAtMs': updatedAtMs,
        'sourceBranch': sourceBranch,
        'sourceDongleId': sourceDongleId,
        'sourceSerial': sourceSerial,
        'sourceCar': sourceCar,
        'paramCount': paramCount,
        'schemaVersion': schemaVersion,
      };

  CarrotProfileHeader copyWith({
    String? name,
    int? updatedAtMs,
    String? sourceBranch,
    String? sourceDongleId,
    String? sourceSerial,
    String? sourceCar,
    int? paramCount,
    String? schemaVersion,
  }) {
    return CarrotProfileHeader(
      id: id,
      name: name ?? this.name,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      sourceBranch: sourceBranch ?? this.sourceBranch,
      sourceDongleId: sourceDongleId ?? this.sourceDongleId,
      sourceSerial: sourceSerial ?? this.sourceSerial,
      sourceCar: sourceCar ?? this.sourceCar,
      paramCount: paramCount ?? this.paramCount,
      schemaVersion: schemaVersion ?? this.schemaVersion,
    );
  }
}

class CarrotProfileDocument {
  final CarrotProfileHeader header;
  final Map<String, dynamic> settingsBundleJson;
  final Map<String, dynamic> values;

  const CarrotProfileDocument({
    required this.header,
    required this.settingsBundleJson,
    required this.values,
  });

  factory CarrotProfileDocument.fromJson(Map<String, dynamic> json) {
    final settingsJson = json['settingsBundleJson'];
    final valuesJson = json['values'];
    return CarrotProfileDocument(
      header: CarrotProfileHeader.fromJson(
        Map<String, dynamic>.from((json['header'] as Map?) ?? const {}),
      ),
      settingsBundleJson: settingsJson is Map
          ? Map<String, dynamic>.from(settingsJson)
          : const <String, dynamic>{},
      values: valuesJson is Map
          ? Map<String, dynamic>.from(valuesJson)
          : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => {
        'header': header.toJson(),
        'settingsBundleJson': settingsBundleJson,
        'values': values,
      };

  CarrotSettingsBundle get bundle =>
      CarrotSettingsBundle.fromJson(settingsBundleJson);

  CarrotProfileDocument copyWith({
    CarrotProfileHeader? header,
    Map<String, dynamic>? settingsBundleJson,
    Map<String, dynamic>? values,
  }) {
    return CarrotProfileDocument(
      header: header ?? this.header,
      settingsBundleJson: settingsBundleJson ?? this.settingsBundleJson,
      values: values ?? this.values,
    );
  }
}

class CarrotProfileIndex {
  final int version;
  final List<CarrotProfileHeader> profiles;

  const CarrotProfileIndex({
    required this.version,
    required this.profiles,
  });

  factory CarrotProfileIndex.fromJson(Map<String, dynamic> json) {
    final rawProfiles = (json['profiles'] as List?) ?? const [];
    return CarrotProfileIndex(
      version: _asInt(json['version']) ?? 1,
      profiles: rawProfiles
          .whereType<Map>()
          .map(
            (e) => CarrotProfileHeader.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'profiles': profiles.map((e) => e.toJson()).toList(),
      };
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _asString(dynamic value) {
  final text = value?.toString();
  if (text == null || text.trim().isEmpty) return null;
  return text;
}
