import 'dart:convert';
import 'dart:io';

/// Where a stock sits in the photographic chain.
///
/// The profiles already say this with two fields: `stage` (`filming` or
/// `printing`) and `support` (`film` or `paper`). A `printing` stock on `film`
/// is a print/internegative stock — 2383 and 2393 in the shipped bundle — which
/// is neither a film you shoot nor a paper you print on, so it gets its own
/// group instead of being hidden.
enum StockCategory {
  /// 拍摄胶片：负片、反转片、电影卷。
  shootFilm,

  /// 相纸：印片用的涂塑相纸。
  paper,

  /// 印片胶片（拷贝片）：把负片翻制到另一条胶片上，再印到相纸。
  printFilm,
}

extension StockCategoryLabel on StockCategory {
  String get label => switch (this) {
        StockCategory.shootFilm => '拍摄胶片',
        StockCategory.paper => '相纸',
        StockCategory.printFilm => '印片胶片（拷贝片）',
      };

  String get hint => switch (this) {
        StockCategory.shootFilm => '决定画面的色彩与颗粒',
        StockCategory.paper => '决定成品的纸基色调与反差',
        StockCategory.printFilm => '先翻底再印片，电影拷贝流程',
      };
}

/// One film, paper or print-film profile the engine can open.
class Stock {
  const Stock({
    required this.id,
    required this.name,
    required this.stage,
    required this.support,
    required this.category,
  });

  final String id;
  final String name;
  final String stage;
  final String support;
  final StockCategory category;

  /// True for stocks that go in the camera.
  bool get isFilm => category == StockCategory.shootFilm;

  /// True for anything used at the printing stage — paper *and* print film.
  bool get isPrintStock =>
      category == StockCategory.paper || category == StockCategory.printFilm;
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
      if (entry.category != null)
        Stock(
          id: entry.id,
          name: entry.name,
          stage: entry.stage!,
          support: entry.support ?? '',
          category: entry.category!,
        ),
  ];
  stocks.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return stocks;
}

/// Groups stocks by category, keeping [StockCategory.values] order so the
/// picker always reads film → paper → print film.
Map<StockCategory, List<Stock>> groupStocks(Iterable<Stock> stocks) {
  final grouped = <StockCategory, List<Stock>>{};
  for (final category in StockCategory.values) {
    final inGroup = stocks.where((stock) => stock.category == category).toList();
    if (inGroup.isNotEmpty) grouped[category] = inGroup;
  }
  return grouped;
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

  StockCategory? get category {
    if (stage == 'filming') return StockCategory.shootFilm;
    if (stage != 'printing') return null;
    return support == 'paper' ? StockCategory.paper : StockCategory.printFilm;
  }
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
