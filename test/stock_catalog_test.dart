import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halfstop/stock_catalog.dart';

/// The picker's three groups come straight from the profiles, so a bundle
/// update that adds a stock lands in the right section without a code change.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('spk_stocks');
    Directory('${root.path}/profiles').createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(String name, String body) {
    File('${root.path}/profiles/$name.json').writeAsStringSync(body);
  }

  test('stage and support map onto the three categories', () async {
    write('shoot', '{"info": {"stock": "shoot", "name": "Portra 400", "stage": "filming", "support": "film"}}');
    write('paper', '{"info": {"stock": "paper", "name": "Endura", "stage": "printing", "support": "paper"}}');
    write('print', '{"info": {"stock": "print", "name": "Vision 2383", "stage": "printing", "support": "film"}}');

    final stocks = await loadStocks(root.path);
    expect(stocks.length, 3);

    final byId = {for (final stock in stocks) stock.id: stock};
    expect(byId['shoot']!.category, StockCategory.shootFilm);
    expect(byId['shoot']!.isFilm, isTrue);
    expect(byId['shoot']!.isPrintStock, isFalse);

    expect(byId['paper']!.category, StockCategory.paper);
    expect(byId['paper']!.isPrintStock, isTrue);

    expect(byId['print']!.category, StockCategory.printFilm);
    expect(byId['print']!.isPrintStock, isTrue);
    // A print stock is not a film you can shoot.
    expect(byId['print']!.isFilm, isFalse);
  });

  test('a partial overlay inherits its base stage', () async {
    write('base', '{"info": {"stock": "base", "name": "Portra 800", "stage": "filming", "support": "film"}}');
    write('overlay', '{"info": {"stock": "overlay", "name": "CineStill 800T", "derived_from": "base"}}');

    final stocks = await loadStocks(root.path);
    final overlay = stocks.firstWhere((stock) => stock.id == 'overlay');
    expect(overlay.category, StockCategory.shootFilm);
    expect(overlay.stage, 'filming');
  });

  test('groups come out in film, paper, print order', () async {
    write('a', '{"info": {"stock": "a", "name": "Zeta Film", "stage": "filming", "support": "film"}}');
    write('b', '{"info": {"stock": "b", "name": "Alpha Paper", "stage": "printing", "support": "paper"}}');
    write('c', '{"info": {"stock": "c", "name": "Beta Print", "stage": "printing", "support": "film"}}');

    final grouped = groupStocks(await loadStocks(root.path));
    expect(grouped.keys.toList(), [
      StockCategory.shootFilm,
      StockCategory.paper,
      StockCategory.printFilm,
    ]);
  });

  test('a profile without a stage is dropped instead of shown uncategorised', () async {
    write('ok', '{"info": {"stock": "ok", "name": "Trix", "stage": "filming", "support": "film"}}');
    write('broken', '{"info": {"stock": "broken", "name": "Mystery"}}');

    final stocks = await loadStocks(root.path);
    expect(stocks.map((stock) => stock.id), ['ok']);
  });
}
