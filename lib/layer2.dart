import 'dart:math' as math;
import 'dart:ui' show ColorFilter;

import 'package:flutter/foundation.dart';

/// The "scan后" colour layer: adjustments applied to the *rendered* frame, not
/// to the film or the enlarger.
///
/// Everything here is a 4x5 colour matrix, so Flutter applies it on the GPU as
/// a `ColorFilter` — a slider moves the pixels at 60 fps without asking the
/// engine for a new frame. That is the whole point of Layer 2: the engine owns
/// film physics, this owns taste.
///
/// The same matrix is replayed in Dart by [applyToRgba8] on export, so the file
/// matches what the screen showed.
@immutable
class Layer2Params {
  const Layer2Params({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.temperature = 0,
    this.tint = 0,
  });

  /// Stops, -2..2. Not the enlarger's exposure — that one costs a reprint.
  final double brightness;

  /// -1..1, applied around mid-grey.
  final double contrast;

  /// -1..1, 0 leaves the scan alone.
  final double saturation;

  /// -1..1, negative is cooler.
  final double temperature;

  /// -1..1, negative is greener.
  final double tint;

  static const Layer2Params neutral = Layer2Params();

  bool get isNeutral =>
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      temperature == 0 &&
      tint == 0;

  Layer2Params copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? temperature,
    double? tint,
  }) {
    return Layer2Params(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      temperature: temperature ?? this.temperature,
      tint: tint ?? this.tint,
    );
  }

  /// 20 values, row-major 4x5, in the layout `ColorFilter.matrix` wants.
  List<double> get matrix {
    // Exposure in stops: a straight gain. The frame is already sRGB-encoded,
    // so this is a display-referred gain, which is what a slider should feel
    // like at this stage of the chain.
    final gain = 1.0 * _pow2(brightness);

    // White balance as channel gains. Temperature pushes red against blue,
    // tint green against magenta; both are scaled to ~±30% so the extremes
    // stay usable rather than nuclear.
    final warm = temperature * 0.3;
    final green = tint * 0.3;
    final rGain = gain * (1 + warm);
    final gGain = gain * (1 + green);
    final bGain = gain * (1 - warm);

    // Saturation around Rec.709 luma.
    final s = 1 + saturation;
    final lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sat = <List<double>>[
      [lr + (1 - lr) * s, lg - lg * s, lb - lb * s, 0, 0],
      [lr - lr * s, lg + (1 - lg) * s, lb - lb * s, 0, 0],
      [lr - lr * s, lg - lg * s, lb + (1 - lb) * s, 0, 0],
      [0, 0, 0, 1, 0],
      [0, 0, 0, 0, 1],
    ];

    // Contrast around mid-grey. `c` of 1 is "no-op", so ±1 maps to 0.5..2.
    final c = 1 + contrast;
    final offset = (0.5 - 0.5 * c) * 255;
    final con = <List<double>>[
      [c, 0, 0, 0, offset],
      [0, c, 0, 0, offset],
      [0, 0, c, 0, offset],
      [0, 0, 0, 1, 0],
      [0, 0, 0, 0, 1],
    ];

    final wb = <List<double>>[
      [rGain, 0, 0, 0, 0],
      [0, gGain, 0, 0, 0],
      [0, 0, bGain, 0, 0],
      [0, 0, 0, 1, 0],
      [0, 0, 0, 0, 1],
    ];

    // exposure+WB, then saturation, then contrast
    final combined = _multiply(con, _multiply(sat, wb));
    return [
      combined[0][0], combined[0][1], combined[0][2], combined[0][3], combined[0][4],
      combined[1][0], combined[1][1], combined[1][2], combined[1][3], combined[1][4],
      combined[2][0], combined[2][1], combined[2][2], combined[2][3], combined[2][4],
      combined[3][0], combined[3][1], combined[3][2], combined[3][3], combined[3][4],
    ];
  }

  ColorFilter get colorFilter => ColorFilter.matrix(matrix);

  static double _pow2(double ev) => math.pow(2, ev).toDouble();

  static List<List<double>> _multiply(List<List<double>> a, List<List<double>> b) {
    final out = List.generate(5, (_) => List<double>.filled(5, 0));
    for (var row = 0; row < 5; row++) {
      for (var col = 0; col < 5; col++) {
        var sum = 0.0;
        for (var k = 0; k < 5; k++) {
          sum += a[row][k] * b[k][col];
        }
        out[row][col] = sum;
      }
    }
    return out;
  }

  /// Replays [matrix] over packed RGBA8 in place. Used on export, where the
  /// frame has to reach disk looking like the preview.
  static void applyToRgba8(Uint8List pixels, List<double> matrix) {
    final m0 = matrix[0], m1 = matrix[1], m2 = matrix[2], m3 = matrix[3], m4 = matrix[4];
    final n0 = matrix[5], n1 = matrix[6], n2 = matrix[7], n3 = matrix[8], n4 = matrix[9];
    final o0 = matrix[10], o1 = matrix[11], o2 = matrix[12], o3 = matrix[13], o4 = matrix[14];
    for (var i = 0; i < pixels.length; i += 4) {
      final r = pixels[i].toDouble();
      final g = pixels[i + 1].toDouble();
      final b = pixels[i + 2].toDouble();
      final a = pixels[i + 3].toDouble();
      final nr = r * m0 + g * m1 + b * m2 + a * m3 + m4;
      final ng = r * n0 + g * n1 + b * n2 + a * n3 + n4;
      final nb = r * o0 + g * o1 + b * o2 + a * o3 + o4;
      pixels[i] = nr < 0 ? 0 : (nr > 255 ? 255 : nr.round());
      pixels[i + 1] = ng < 0 ? 0 : (ng > 255 ? 255 : ng.round());
      pixels[i + 2] = nb < 0 ? 0 : (nb > 255 ? 255 : nb.round());
    }
  }
}
