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
