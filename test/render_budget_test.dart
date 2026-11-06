import 'package:flutter_test/flutter_test.dart';
import 'package:halfstop/frame_format.dart';
import 'package:halfstop/render_budget.dart';

FilmFormat _format(String id) =>
    kFilmFormats.firstWhere((format) => format.id == id);

void main() {
  test('a 135 gate costs more than its own pixels once the rebate is laid', () {
    final format = _format('135');
    final gate = 3400 * 2267;
    final canvas = estimateOverscanCanvasPixels(
      frameW: 3400,
      frameH: 2267,
      format: format,
      mode: 'strip',
      carrier: 'none',
    );
    // The film is 35 mm wide against a 24.3 mm gate: 1.44x across alone.
    expect(canvas, greaterThan(gate * 1.4));
    expect(canvas, lessThan(gate * 1.7));
  });

  test('a 120 gate costs about 20% more, not 50%', () {
    final format = _format('120_6x6');
    final gate = 3400 * 3400;
    final canvas = estimateOverscanCanvasPixels(
      frameW: 3400,
      frameH: 3400,
      format: format,
      mode: 'strip',
      carrier: 'none',
    );
    expect(canvas, greaterThan(gate));
    expect(canvas, lessThan(gate * 1.3));
  });

  test('filed lays less film around the gate than a strip', () {
    final format = _format('120_6x7');
    final strip = estimateOverscanCanvasPixels(
      frameW: 3400,
      frameH: 2766,
      format: format,
      mode: 'strip',
      carrier: 'none',
    );
    final filed = estimateOverscanCanvasPixels(
      frameW: 3400,
      frameH: 2766,
      format: format,
      mode: 'filed',
      carrier: 'none',
    );
    expect(filed, lessThan(strip));
  });

  test('a carrier widens the canvas: the scan reaches past the film edge', () {
    final format = _format('135');
    final none = estimateOverscanCanvasPixels(
      frameW: 3400,
      frameH: 2267,
      format: format,
      mode: 'strip',
      carrier: 'none',
    );
    final open = estimateOverscanCanvasPixels(
      frameW: 3400,
      frameH: 2267,
      format: format,
      mode: 'strip',
      carrier: 'open',
    );
    expect(open, greaterThan(none));
  });

  test('an edge that already fits comes back untouched', () {
    final format = _format('135');
    final edge = clampOverscanLongEdge(
      desiredEdge: 1600,
      frameAspect: format.ratio,
      format: format,
      mode: 'strip',
      carrier: 'none',
      budgetPixels: 10600000,
    );
    expect(edge, 1600);
  });

  test('a 3400 px 6x6 gate is shrunk to the device budget', () {
    final format = _format('120_6x6');
    const budget = 10600000;
    final edge = clampOverscanLongEdge(
      desiredEdge: 3400,
      frameAspect: format.ratio,
      format: format,
      mode: 'strip',
      carrier: 'none',
      budgetPixels: budget,
    );
    expect(edge, lessThan(3400));
    // Whatever it picks must actually fit, or the retry loop just fails again.
    final canvas = estimateOverscanCanvasPixels(
      frameW: edge,
      frameH: (edge / format.ratio).round(),
      format: format,
      mode: 'strip',
      carrier: 'none',
    );
    expect(canvas, lessThanOrEqualTo(budget));
  });

  test('the clamp never goes below the engine minimum tier size', () {
    final format = _format('120_6x17');
    final edge = clampOverscanLongEdge(
      desiredEdge: 3400,
      frameAspect: format.ratio,
      format: format,
      mode: 'strip',
      carrier: 'open',
      budgetPixels: 100000,
    );
    expect(edge, greaterThanOrEqualTo(800));
  });
}
