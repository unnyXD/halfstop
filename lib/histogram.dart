import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Per-channel luminance distribution of one frame, after the Layer 2 matrix.
///
/// Sampling (rather than counting every pixel) keeps this cheap enough to
/// recompute while a slider moves: 64k samples is ~3 ms, where a 12 MP frame
/// would be ~150 ms and drop the frame the user is dragging.
@immutable
class Histogram {
  const Histogram({
    required this.red,
    required this.green,
    required this.blue,
    required this.peak,
  });

  final List<int> red;
  final List<int> green;
  final List<int> blue;

  /// Highest bin across all channels, for normalising the drawing.
  final int peak;

  bool get isEmpty => peak == 0;

  static const int _bins = 256;
  static const int _targetSamples = 65536;

  static Histogram fromRgba8(
    Uint8List pixels, {
    List<double>? matrix,
    int targetSamples = _targetSamples,
  }) {
    final total = pixels.length ~/ 4;
    if (total == 0) {
      final empty = List<int>.filled(_bins, 0);
      return Histogram(red: empty, green: empty, blue: empty, peak: 0);
    }
    final stride = (total / targetSamples).ceil().clamp(1, total);
    final red = List<int>.filled(_bins, 0);
    final green = List<int>.filled(_bins, 0);
    final blue = List<int>.filled(_bins, 0);

    final m = matrix;
    for (var p = 0; p < total; p += stride) {
      final i = p * 4;
      int r = pixels[i];
      int g = pixels[i + 1];
      int b = pixels[i + 2];
      if (m != null) {
        final fr = r.toDouble(), fg = g.toDouble(), fb = b.toDouble();
        final nr = fr * m[0] + fg * m[1] + fb * m[2] + m[4];
        final ng = fr * m[5] + fg * m[6] + fb * m[7] + m[9];
        final nb = fr * m[10] + fg * m[11] + fb * m[12] + m[14];
        r = nr < 0 ? 0 : (nr > 255 ? 255 : nr.round());
        g = ng < 0 ? 0 : (ng > 255 ? 255 : ng.round());
        b = nb < 0 ? 0 : (nb > 255 ? 255 : nb.round());
      }
      red[r]++;
      green[g]++;
      blue[b]++;
    }

    var peak = 0;
    for (var i = 0; i < _bins; i++) {
      if (red[i] > peak) peak = red[i];
      if (green[i] > peak) peak = green[i];
      if (blue[i] > peak) peak = blue[i];
    }
    return Histogram(red: red, green: green, blue: blue, peak: peak);
  }
}

/// A light-meter reading taken from one rendered frame.
///
/// This is what the meter in a film-simulation app is for: the engine has
/// already decided the look, so the honest question is "how is this frame
/// sitting?" — mean level, how much is clipping at each end, and how far the
/// exposure would have to move to put the mean on a mid-grey target.
///
/// Computing it from the histogram (rather than the pixels again) costs
/// nothing: the bins are already there for the graph.
@immutable
class Metering {
  const Metering({
    required this.mean,
    required this.shadows,
    required this.highlights,
    required this.suggestedEv,
  });

  /// Mean luminance, 0..1.
  final double mean;

  /// Fraction of samples sitting in the clipped bins at either end.
  final double shadows;
  final double highlights;

  /// Exposure offset that would bring [mean] to [target], clamped to what the
  /// exposure slider can actually do.
  final double suggestedEv;

  /// A pleasing mid-tone for a print, a little above 18% grey.
  static const double target = 0.46;

  static const Metering empty =
      Metering(mean: 0, shadows: 0, highlights: 0, suggestedEv: 0);

  bool get isEmpty => mean <= 0;

  /// Whether the frame is far enough off target for the suggestion to matter.
  bool get needsExposure => suggestedEv.abs() >= 0.1;

  static Metering fromHistogram(Histogram histogram) {
    if (histogram.isEmpty) return empty;

    final red = histogram.red;
    final green = histogram.green;
    final blue = histogram.blue;
    final bins = red.length;
    if (bins == 0) return empty;

    var total = 0;
    var sumR = 0.0, sumG = 0.0, sumB = 0.0;
    var dark = 0;
    var bright = 0;
    // Clipping is an absolute property of the code values, not a percentage
    // of the histogram: the bottom three and top three bins are where detail
    // is actually gone.
    const darkEdge = 2;
    final brightEdge = bins - 3;

    for (var i = 0; i < bins; i++) {
      final r = red[i], g = green[i], b = blue[i];
      final count = r + g + b;
      if (count == 0) continue;
      total += count;
      sumR += i * r;
      sumG += i * g;
      sumB += i * b;
      if (i <= darkEdge) dark += count;
      if (i >= brightEdge) bright += count;
    }
    if (total == 0) return empty;

    final scale = 255.0 * (total / 3);
    final luma = (0.2126 * sumR + 0.7152 * sumG + 0.0722 * sumB) / scale;
    final mean = luma.clamp(0.0, 1.0);

    // A pure black or pure white frame has no ratio to take a log of, but it
    // still deserves a suggestion: the slider stops at ±2 anyway.
    var ev = mean <= 0.002
        ? 2.0
        : mean >= 0.998
            ? -2.0
            : (math.log(target / mean) / math.ln2);
    ev = ev.clamp(-2.0, 2.0);
    // Quarter-stop steps: the readout is a suggestion, not a measurement.
    ev = (ev * 4).roundToDouble() / 4;

    return Metering(
      mean: mean,
      shadows: dark / total,
      highlights: bright / total,
      suggestedEv: ev,
    );
  }
}

/// The little RGB histogram drawn over the preview corner.
class HistogramView extends StatelessWidget {
  const HistogramView({super.key, required this.data, this.width = 104, this.height = 40});

  final Histogram? data;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: data == null || data!.isEmpty
          ? const SizedBox.shrink()
          : CustomPaint(painter: _HistogramPainter(data!)),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.data);

  final Histogram data;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
    );
    // Sqrt scaling: linear bins are dominated by the mid-tone spike and the
    // shadows/highlights end up invisible.
    final peak = _sqrt(data.peak.toDouble());
    final paint = Paint()
      ..blendMode = BlendMode.plus
      ..style = PaintingStyle.fill;

    void channel(List<int> bins, Color color) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i < bins.length; i++) {
        final x = size.width * i / (bins.length - 1);
        final y = size.height - (_sqrt(bins[i].toDouble()) / peak) * size.height;
        path.lineTo(x, y);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, paint..color = color.withValues(alpha: 0.55));
    }

    channel(data.red, const Color(0xFFFF5A5A));
    channel(data.green, const Color(0xFF5AFF8A));
    channel(data.blue, const Color(0xFF5A8AFF));
  }

  static double _sqrt(double v) => v <= 0 ? 0 : math.sqrt(v);

  @override
  bool shouldRepaint(_HistogramPainter old) => old.data != data;
}
