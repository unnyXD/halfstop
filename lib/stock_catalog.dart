import 'dart:convert';
import 'dart:io';

/// One film or paper profile the engine can open.
class Stock {
  const Stock({
    required this.id,
    required this.name,
    required this.stage,
    required this.support,
  });

  final String id;
  final String name;
  final String stage;
  final String support;

  bool get isFilm => stage == 'filming';
  bool get isPaper => stage == 'printing' && support == 'paper';
}

/// Lists the profiles under `<resourcesDir>/profiles` without decoding the
/// whole file: a profile carries its spectral tables and is hundreds of KB,
/// while everything the picker needs is in the first few lines.
///
/// Product overlays (for example CineStill 800T) can be partial: they name a
/// `derived_from` base and override only a few `info` keys. Those inherit the
/// base's stage/support, so the picker still gets one entry for them.
Future<List<Stock>> loadStocks(String resourcesDir) async {
  final directory = Directory('$resourcesDir/profiles');
  if (!await directory.exists()) return const [];

  final entries = <_Entry>[];
  await for (final entity in directory.list()) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.json')) {
      continue;
    }
    try {
      final head = await _readHead(entity, 4096);
      final name = _stringField(head, 'name');
      if (name == null) continue;
      final fileName = entity.path.split(RegExp(r'[\\/]')).last;
      entries.add(_Entry(
        id: _stringField(head, 'stock') ??
            fileName.substring(0, fileName.length - '.json'.length),
        name: name,
        stage: _stringField(head, 'stage'),
        support: _stringField(head, 'support'),
        derivedFrom: _stringField(head, 'derived_from'),
      ));
    } catch (_) {
      // One unreadable profile must not hide the rest of the catalog.
    }
  }

  final byId = {for (final entry in entries) entry.id: entry};
  for (final entry in entries) {
    if (entry.stage != null && entry.support != null) continue;
    final base = entry.derivedFrom == null ? null : byId[entry.derivedFrom];
    if (base == null) continue;
    entry.stage ??= base.stage;
    entry.support ??= base.support;
  }

  final stocks = <Stock>[
    for (final entry in entries)
      if (entry.stage != null)
        Stock(
          id: entry.id,
          name: entry.name,
          stage: entry.stage!,
          support: entry.support ?? '',
        ),
  ];
  stocks.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return stocks;
}

class _Entry {
  _Entry({
    required this.id,
    required this.name,
    required this.stage,
    required this.support,
    required this.derivedFrom,
  });

  final String id;
  final String name;
  String? stage;
  String? support;
  final String? derivedFrom;
}

Future<String> _readHead(File file, int bytes) async {
  final handle = await file.open();
  try {
    final length = await file.length();
    final data = await handle.read(length < bytes ? length : bytes);
    return utf8.decode(data, allowMalformed: true);
  } finally {
    await handle.close();
  }
}

String? _stringField(String json, String field) {
  final match = RegExp('"$field"\\s*:\\s*"([^"]*)"').firstMatch(json);
  return match?.group(1);
}
