import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halfstop/layer2.dart';

/// The two guarantees this layer has to keep: neutral means "do nothing", and
/// what export bakes matches what the preview drew.
void main() {
  test('neutral is the identity matrix', () {
    final m = Layer2Params.neutral.matrix;
    expect(m.length, 20);
    const identity = [
      1.0, 0.0, 0.0, 0.0, 0.0, //
      0.0, 1.0, 0.0, 0.0, 0.0, //
      0.0, 0.0, 1.0, 0.0, 0.0, //
      0.0, 0.0, 0.0, 1.0, 0.0, //
    ];
    for (var i = 0; i < 20; i++) {
      expect(m[i], closeTo(identity[i], 1e-9), reason: 'matrix[$i]');
    }
  });

  test('one stop of brightness doubles the channels', () {
    final m = Layer2Params.neutral.copyWith(brightness: 1).matrix;
    expect(m[0], closeTo(2.0, 1e-6));
    expect(m[6], closeTo(2.0, 1e-6));
    expect(m[12], closeTo(2.0, 1e-6));
  });

  test('the red channel gain and the blue channel gain move in opposite ways', () {
    final warm = Layer2Params.neutral.copyWith(temperature: 1).matrix;
    expect(warm[0], greaterThan(1.0));
    expect(warm[12], lessThan(1.0));
  });

  test('full desaturation collapses the channels onto luma', () {
    final m = Layer2Params.neutral.copyWith(saturation: -1).matrix;
    // With s = 0 every output row is the luma weights of the input.
    expect(m[0], closeTo(0.2126, 1e-6));
    expect(m[1], closeTo(0.7152, 1e-6));
    expect(m[2], closeTo(0.0722, 1e-6));
    expect(m[5], closeTo(0.2126, 1e-6));
    expect(m[10], closeTo(0.2126, 1e-6));
  });

  test('applying the neutral matrix leaves pixels untouched', () {
    final pixels = Uint8List.fromList([10, 20, 30, 255, 200, 100, 50, 255]);
    Layer2Params.applyToRgba8(pixels, Layer2Params.neutral.matrix);
    expect(pixels, [10, 20, 30, 255, 200, 100, 50, 255]);
  });

  test('applying the matrix clamps instead of wrapping', () {
    final pixels = Uint8List.fromList([250, 250, 250, 255]);
    Layer2Params.applyToRgba8(
      pixels,
      Layer2Params.neutral.copyWith(brightness: 2).matrix,
    );
    expect(pixels, [255, 255, 255, 255]);
  });

  test('alpha is never touched', () {
    final pixels = Uint8List.fromList([10, 20, 30, 128]);
    Layer2Params.applyToRgba8(
      pixels,
      Layer2Params.neutral.copyWith(contrast: 1, saturation: -1).matrix,
    );
    expect(pixels[3], 128);
  });
}
