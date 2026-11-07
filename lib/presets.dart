import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'photo_settings.dart';

/// A named bundle of what the panel can be set to.
///
/// The point is repetition: a shoot uses one film, one paper, one gate and one
/// rebate for all of it, and rebuilding that slider by slider on every import
/// is the slowest thing in the app. A preset is the same [PhotoSettings] the
/// per-picture memory already stores, with a name on it.
class Preset {
  const Preset({
    required this.name,
    required this.settings,
    required this.savedAt,
  });

  final String name;
  final PhotoSettings settings;
  final DateTime savedAt;

  Map<String, Object?> toJson() => {
        'name': name,
        'savedAt': savedAt.toIso8601String(),
        'settings': settings.toJson(),
      };

  factory Preset.fromJson(Map<String, Object?> json) {
    final settings = json['settings'];
    return Preset(
      name: (json['name'] as String?) ?? '未命名',
      settings: settings is Map
          ? PhotoSettings.fromJson(settings.cast<String, Object?>())
          : const PhotoSettings(),
      savedAt: DateTime.tryParse((json['savedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Presets live in one json file beside the per-picture settings.
class PresetStore {
  PresetStore._(this._file, this._presets);

  final File _file;
  final List<Preset> _presets;

  static Future<PresetStore> open() async {
    File file;
    try {
      final dir = await getApplicationSupportDirectory();
      file = File('${dir.path}/presets.json');
    } catch (_) {
      return PresetStore._(File(''), []);
    }
    var presets = <Preset>[];
    try {
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              presets.add(Preset.fromJson(entry.cast<String, Object?>()));
            }
          }
        }
      }
    } catch (_) {
      presets = [];
    }
    presets.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return PresetStore._(file, presets);
  }

  /// Newest first, which is the order a shoot creates them in.
  List<Preset> get all => List.unmodifiable(_presets);

  /// Saves under [preset]'s name, replacing a preset of the same name.
  void save(Preset preset) {
    _presets.removeWhere((other) => other.name == preset.name);
    _presets.insert(0, preset);
    _flush();
  }

  void remove(String name) {
    final before = _presets.length;
    _presets.removeWhere((preset) => preset.name == name);
    if (_presets.length != before) _flush();
  }

  void _flush() {
    if (_file.path.isEmpty) return;
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        jsonEncode([for (final preset in _presets) preset.toJson()]),
      );
    } catch (_) {
      // Losing a preset costs a re-setup, not the picture; no dialog.
    }
  }
}
