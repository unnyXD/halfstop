import 'dart:math' as math;

import 'frame_format.dart';

/// The engine's planes are 12 bytes per pixel (three half-float RGB channels,
/// padded rows). Every buffer it binds is budgeted against
/// `maxStorageBufferRange` at this rate.
const double kPlaneBytesPerPixel = 12;

/// The share of the device budget the overscan canvas may use. The mask is one
/// allocation among several the pipeline keeps alive, and rows are padded to
/// the device's linear alignment.
const double kOverscanHeadroom = 0.94;

/// The film's width past the gate when a carrier is drawn, in mm (`kCarrierMM`
/// in overscan.cpp).
const double _kCarrierMm = 0.4;

/// How many millimetres of film the strip shows past the gate's long edges
/// (`overscan_layout`'s `margin_along`). The engine draws a random value inside
/// each range; this takes the top of it, so the estimate never comes out small.
double _marginAlong(FilmFormat format, String mode) {
  if (mode == 'filed') return 1.0;
  if (!format.isThirtyFive) return 2.1; // 120: 1.3–2.1
  return format.longEdge < 20 ? 0.5 : 0.95; // half frame advances 19 mm
}

/// Pixels the overscan canvas takes for a gate of [frameW] × [frameH].
///
/// The canvas is the gate plus the film around it, so it is always larger than
/// the frame: on 135 it is the film's full 35 mm across (1.44× the 24.3 mm
/// gate) and a further ~5% along; on 120 it is 61 mm across 56 mm. Getting this
/// wrong is what makes a frame that renders fine fail the moment 片边 is
/// switched on.
int estimateOverscanCanvasPixels({
  required int frameW,
  required int frameH,
  required FilmFormat format,
  required String mode,
  required String carrier,
  bool pair = false,
}) {
  if (frameW <= 0 || frameH <= 0) return 0;
  final gateArea = format.longEdge * format.shortEdge;
  if (gateArea <= 0) return 0;

  // A half-frame pair puts the second frame on the same strip, so the canvas
  // doubles along the film and the buffer has to grow with it.
  final canvasAlong = (format.longEdge + 2 * _marginAlong(format, mode)) *
      (pair ? 1.95 : 1.0);
  final double canvasAcross;
  if (mode == 'filed') {
    // 1.1 mm of holder a side, in from the gate's own edges.
    canvasAcross = format.shortEdge + 2.2;
  } else {
    final reach = carrier == 'none' ? 0.0 : _kCarrierMm;
    canvasAcross = format.filmWidth + 2 * reach;
  }

  final factor = canvasAlong * canvasAcross / gateArea;
  return (frameW * frameH * factor).round();
}

/// The largest long edge for a gate whose overscan canvas still fits
/// [budgetPixels], given the shape the editor is rendering at.
///
/// Returns [desiredEdge] untouched when it already fits (the usual case), so
/// callers can use it unconditionally.
int clampOverscanLongEdge({
  required int desiredEdge,
  required double frameAspect,
  required FilmFormat format,
  required String mode,
  required String carrier,
  required int budgetPixels,
  bool pair = false,
}) {
  if (desiredEdge <= 0 || budgetPixels <= 0) return desiredEdge;
  if (frameAspect <= 0) return desiredEdge;

  final longEdge = desiredEdge.toDouble();
  final shortEdge = math.max(1.0, longEdge / frameAspect);
  final canvas = estimateOverscanCanvasPixels(
    frameW: longEdge.round(),
    frameH: shortEdge.round(),
    format: format,
    mode: mode,
    carrier: carrier,
    pair: pair,
  );
  if (canvas <= budgetPixels) return desiredEdge;

  final factor = math.sqrt(budgetPixels / canvas);
  return math.max(800, (desiredEdge * factor * 0.985).floor());
}

/// The megapixels a device's plane budget allows at 12 B/px — the number the
/// status line shows next to 片边.
double planeBudgetMegapixels(int pixels) => pixels / 1000000;
