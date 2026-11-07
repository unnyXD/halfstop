import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'layer2.dart';

/// Everything about one picture that the editor lets you change.
///
/// Held per file: opening another picture used to carry the last one's film,
/// format and rebate over to it, which is wrong for every one of those — a
/// 6×6 shot and a 135 shot do not want the same frame.
///
/// The shape is deliberately flat and json-friendly: this is written to disk
/// on every switch, so it has to survive a version change without a migration.
class PhotoSettings {
  const PhotoSettings({
    this.film = 'kodak_portra_400',
    this.paper = 'kodak_portra_endura',
    this.exposureEv = 0,
    this.magenta = 0,
    this.yellow = 0,
    this.shiftScale = 1,
    this.preflash = 0,
    this.strength = 1,
    this.grain = 1,
    this.halation = 1,
    this.glare = 0,
    this.scatter = 1,
    this.noAntihalation = false,
    this.cameraFilter = '',
    this.latitudeHighlight = 0,
    this.latitudeShadow = 0,
    this.layer2 = Layer2Params.neutral,
    this.formatId,
    this.crop,
    this.cropOnWidth,
    this.cropOnHeight,
    this.overscanOn = false,
    this.overscanMode = 'strip',
    this.holes = 'white',
    this.carrier = 'none',
    this.gate = 'auto',
    this.edgeText = '',
    this.edgeFog = 1,
    this.leaks = 0,
    this.frameNumber = -1,
    this.fNumber = 0,
    this.pair = false,
    this.dateOn = false,
    this.dateText = '',
    this.dateStyle = 'lcd',
    this.datePlacement = 'frame',
    this.dateCorner = 'br',
    this.dateSize = 1,
    this.dataText = '',
  });

  final String film;
  final String paper;

  final double exposureEv;
  final double magenta;
  final double yellow;
  final double shiftScale;
  final double preflash;

  final double strength;
  final double grain;
  final double halation;
  final double glare;
  final double scatter;
  final bool noAntihalation;
  final String cameraFilter;

  /// Stops pulled off each end of the scene, 0 = that side off. Only the
  /// request is stored; the curve is re-fitted when the picture is reopened.
  final double latitudeHighlight;
  final double latitudeShadow;
  final Layer2Params layer2;

  /// `135`, `120_6x6`, … or null for "leave the frame alone".
  final String? formatId;

  /// Normalised to the picture, so it carries across files of any size.
  final CropRect? crop;

  /// The source the crop was drawn on. A crop is only geometrically right on a
  /// picture of the same shape — re-importing at another size would turn its
  /// ratio into something the engine refuses to lay a rebate around.
  final int? cropOnWidth;
  final int? cropOnHeight;

  final bool overscanOn;
  final String overscanMode;
  final String holes;
  final String carrier;
  final String gate;
  final String edgeText;
  final double edgeFog;
  final double leaks;
  final int frameNumber;
  final double fNumber;
  final bool pair;

  final bool dateOn;
  final String dateText;
  final String dateStyle;
  final String datePlacement;
  final String dateCorner;
  final double dateSize;
  final String dataText;

  Map<String, Object?> toJson() => {
        'film': film,
        'paper': paper,
        'exposureEv': exposureEv,
        'magenta': magenta,
        'yellow': yellow,
        'shiftScale': shiftScale,
        'preflash': preflash,
        'strength': strength,
        'grain': grain,
        'halation': halation,
        'glare': glare,
        'scatter': scatter,
        'noAntihalation': noAntihalation,
        'cameraFilter': cameraFilter,
        'latitudeHighlight': latitudeHighlight,
        'latitudeShadow': latitudeShadow,
        'layer2': {
          'brightness': layer2.brightness,
          'contrast': layer2.contrast,
          'saturation': layer2.saturation,
          'temperature': layer2.temperature,
          'tint': layer2.tint,
        },
        if (formatId != null) 'formatId': formatId,
        if (crop != null)
          'crop': {
            'x': crop!.x,
            'y': crop!.y,
            'w': crop!.width,
            'h': crop!.height,
            if (cropOnWidth != null) 'onWidth': cropOnWidth,
            if (cropOnHeight != null) 'onHeight': cropOnHeight,
          },
        'overscanOn': overscanOn,
        'overscanMode': overscanMode,
        'holes': holes,
        'carrier': carrier,
        'gate': gate,
        'edgeText': edgeText,
        'edgeFog': edgeFog,
        'leaks': leaks,
        'frameNumber': frameNumber,
        'fNumber': fNumber,
        'pair': pair,
        'dateOn': dateOn,
        'dateText': dateText,
        'dateStyle': dateStyle,
        'datePlacement': datePlacement,
        'dateCorner': dateCorner,
        'dateSize': dateSize,
        'dataText': dataText,
      };

  /// Reads back what [toJson] wrote. Unknown keys are ignored and missing ones
  /// fall back to a default, so an older file still opens after a field is
  /// added or removed.
  factory PhotoSettings.fromJson(Map<String, Object?> json) {
    double d(String key, double fallback) =>
        (json[key] as num?)?.toDouble() ?? fallback;
    String s(String key, String fallback) =>
        (json[key] as String?) ?? fallback;
    bool b(String key, bool fallback) => (json[key] as bool?) ?? fallback;
    int i(String key, int fallback) => (json[key] as num?)?.toInt() ?? fallback;

    final layer = json['layer2'];
    final layerMap = layer is Map ? layer.cast<String, Object?>() : const <String, Object?>{};
    final cropJson = json['crop'];
    final cropMap = cropJson is Map ? cropJson.cast<String, Object?>() : null;

    return PhotoSettings(
      film: s('film', 'kodak_portra_400'),
      paper: s('paper', 'kodak_portra_endura'),
      exposureEv: d('exposureEv', 0),
      magenta: d('magenta', 0),
      yellow: d('yellow', 0),
      shiftScale: d('shiftScale', 1),
      preflash: d('preflash', 0),
      strength: d('strength', 1),
      grain: d('grain', 1),
      halation: d('halation', 1),
      glare: d('glare', 0),
      scatter: d('scatter', 1),
      noAntihalation: b('noAntihalation', false),
      cameraFilter: s('cameraFilter', ''),
      latitudeHighlight: d('latitudeHighlight', 0),
      latitudeShadow: d('latitudeShadow', 0),
      layer2: Layer2Params(
        brightness: (layerMap['brightness'] as num?)?.toDouble() ?? 0,
        contrast: (layerMap['contrast'] as num?)?.toDouble() ?? 0,
        saturation: (layerMap['saturation'] as num?)?.toDouble() ?? 0,
        temperature: (layerMap['temperature'] as num?)?.toDouble() ?? 0,
        tint: (layerMap['tint'] as num?)?.toDouble() ?? 0,
      ),
      formatId: json['formatId'] as String?,
      crop: cropMap == null
          ? null
          : CropRect(
              x: (cropMap['x'] as num?)?.toDouble() ?? 0,
              y: (cropMap['y'] as num?)?.toDouble() ?? 0,
              width: (cropMap['w'] as num?)?.toDouble() ?? 1,
              height: (cropMap['h'] as num?)?.toDouble() ?? 1,
            ),
      cropOnWidth: (cropMap?['onWidth'] as num?)?.toInt(),
      cropOnHeight: (cropMap?['onHeight'] as num?)?.toInt(),
      overscanOn: b('overscanOn', false),
      overscanMode: s('overscanMode', 'strip'),
      holes: s('holes', 'white'),
      carrier: s('carrier', 'none'),
      gate: s('gate', 'auto'),
      edgeText: s('edgeText', ''),
      edgeFog: d('edgeFog', 1),
      leaks: d('leaks', 0),
      frameNumber: i('frameNumber', -1),
      fNumber: d('fNumber', 0),
      pair: b('pair', false),
      dateOn: b('dateOn', false),
      dateText: s('dateText', ''),
      dateStyle: s('dateStyle', 'lcd'),
      datePlacement: s('datePlacement', 'frame'),
      dateCorner: s('dateCorner', 'br'),
      dateSize: d('dateSize', 1),
      dataText: s('dataText', ''),
    );
  }
}

/// A crop in the picture's own 0..1 coordinates.
///
/// Deliberately not `CropBox`: that one is a UI type that knows about aspect
/// locks and placements, and this has to stay readable from a json file.
class CropRect {
  const CropRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;
}

/// One json file beside the app's support data, keyed by picture path.
///
/// A photo picked from the gallery is re-copied on each import under a new
/// name, so its entry ages out with the cache; [prune] drops those.
class PhotoSettingsStore {
  PhotoSettingsStore._(this._file, this._entries);

  final File _file;
  final Map<String, PhotoSettings> _entries;

  static Future<PhotoSettingsStore> open() async {
    File file;
    try {
      final dir = await getApplicationSupportDirectory();
      file = File('${dir.path}/photo_settings.json');
    } catch (_) {
      // No support directory (a test harness): keep it in memory only.
      return PhotoSettingsStore._(File(''), {});
    }
    var entries = <String, PhotoSettings>{};
    try {
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is Map) {
              entries[key.toString()] =
                  PhotoSettings.fromJson(value.cast<String, Object?>());
            }
          });
        }
      }
    } catch (_) {
      // A corrupt file is not worth a dialog; start clean.
      entries = {};
    }
    return PhotoSettingsStore._(file, entries);
  }

  PhotoSettings? operator [](String path) => _entries[path];

  void put(String path, PhotoSettings settings) {
    _entries[path] = settings;
    _flush();
  }

  void forget(String path) {
    if (_entries.remove(path) == null) return;
    _flush();
  }

  /// Drops entries whose picture is gone, so the file does not grow forever.
  void prune(bool Function(String path) exists) {
    final stale = _entries.keys.where((path) => !exists(path)).toList();
    if (stale.isEmpty) return;
    for (final path in stale) {
      _entries.remove(path);
    }
    _flush();
  }

  void _flush() {
    if (_file.path.isEmpty) return;
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode({
        for (final entry in _entries.entries) entry.key: entry.value.toJson(),
      }));
    } catch (_) {
      // A read-only data dir only costs the user a re-pick; not worth a crash.
    }
  }
}
