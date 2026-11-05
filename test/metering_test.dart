import 'dart:typed_data';

import 'package:halfstop/histogram.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _flat(int r, int g, int b, {int pixels = 64}) {
  final bytes = Uint8List(pixels * 4);
  for (var i = 0; i < pixels; i++) {
    bytes[i * 4] = r;
    bytes[i * 4 + 1] = g;
    bytes[i * 4 + 2] = b;
    bytes[i * 4 + 3] = 255;
  }
  return bytes;
}

void main() {
  test('a mid-grey frame reads as mid-grey and asks for little correction', () {
    final meter = Metering.fromHistogram(Histogram.fromRgba8(_flat(128, 128, 128)));
    expect(meter.mean, closeTo(0.50, 0.02));
    expect(meter.suggestedEv.abs(), lessThanOrEqualTo(0.5));
    expect(meter.highlights, 0);
    expect(meter.shadows, 0);
  });

  test('a dark frame asks for positive exposure without claiming clipping', () {
    final meter = Metering.fromHistogram(Histogram.fromRgba8(_flat(20, 20, 20)));
    expect(meter.mean, lessThan(0.1));
    expect(meter.suggestedEv, greaterThan(0.5));
    // 20/255 is dark, not crushed: detail still exists there.
    expect(meter.shadows, 0);
  });

  test('a crushed black frame is reported as shadow clipping', () {
    final meter = Metering.fromHistogram(Histogram.fromRgba8(_flat(0, 0, 0)));
    expect(meter.shadows, greaterThan(0.9));
    expect(meter.suggestedEv, 2.0);
  });

  test('a blown frame asks for negative exposure and reports clipping', () {
    final meter = Metering.fromHistogram(Histogram.fromRgba8(_flat(255, 255, 255)));
    expect(meter.mean, greaterThan(0.95));
    expect(meter.suggestedEv, lessThan(-0.5));
    expect(meter.highlights, greaterThan(0.9));
  });

  test('the suggestion is clamped to what the slider can do', () {
    final meter = Metering.fromHistogram(Histogram.fromRgba8(_flat(1, 1, 1)));
    expect(meter.suggestedEv, lessThanOrEqualTo(2.0));
    expect(meter.suggestedEv, greaterThanOrEqualTo(-2.0));
  });

  test('an empty histogram has no reading rather than a wrong one', () {
    final empty = Histogram.fromRgba8(Uint8List(0));
    expect(Metering.fromHistogram(empty).isEmpty, isTrue);
  });
}
