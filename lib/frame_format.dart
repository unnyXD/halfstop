/// The film formats the engine's overscan can lay out, and the crop that makes
/// a frame the right shape for one.
///
/// The engine refuses a frame whose aspect is more than 5% off the gate's
/// (`overscan_layout` in overscan.cpp), so picking a format is always two
/// things at once: the gate, and a centre crop of the picture to match it.
/// The numbers below are the gate sizes the engine measures against, in mm —
/// keep them in sync with `kFormats`.
class FilmFormat {
  const FilmFormat({
    required this.id,
    required this.label,
    required this.longEdge,
    required this.shortEdge,
    required this.filmWidth,
    required this.note,
  });

  /// The engine's `overscan_format` value.
  final String id;
  final String label;

  /// Gate size along the film, mm.
  final double longEdge;

  /// Gate size across the film, mm.
  final double shortEdge;

  /// The film's own width, mm. 35 for 135, 61 for 120.
  final double filmWidth;

  final String note;

  double get ratio => longEdge / shortEdge;

  /// 135 and 120 sit on different stocks — the rebate knows which.
  bool get isThirtyFive => filmWidth < 40;
}

const List<FilmFormat> kFilmFormats = [
  FilmFormat(
    id: '135',
    label: '135',
    longEdge: 36.25,
    shortEdge: 24.3,
    filmWidth: 35,
    note: '36 × 24，最常见的一格',
  ),
  FilmFormat(
    id: '135_half',
    label: '半格',
    longEdge: 24,
    shortEdge: 18,
    filmWidth: 35,
    note: '18 × 24，一格半张，竖构图',
  ),
  FilmFormat(
    id: '135_xpan',
    label: 'XPan',
    longEdge: 65,
    shortEdge: 24,
    filmWidth: 35,
    note: '65 × 24，宽幅 2.7:1',
  ),
  FilmFormat(
    id: '120_645',
    label: '645',
    longEdge: 56,
    shortEdge: 41.5,
    filmWidth: 61,
    note: '56 × 41.5，120 的最小一格',
  ),
  FilmFormat(
    id: '120_6x6',
    label: '6×6',
    longEdge: 56,
    shortEdge: 56,
    filmWidth: 61,
    note: '56 × 56，正方形',
  ),
  FilmFormat(
    id: '120_6x7',
    label: '6×7',
    longEdge: 69.5,
    shortEdge: 56,
    filmWidth: 61,
    note: '69.5 × 56',
  ),
  FilmFormat(
    id: '120_6x8',
    label: '6×8',
    longEdge: 76,
    shortEdge: 56,
    filmWidth: 61,
    note: '76 × 56',
  ),
  FilmFormat(
    id: '120_6x9',
    label: '6×9',
    longEdge: 84,
    shortEdge: 56,
    filmWidth: 61,
    note: '84 × 56，3:2 的大画幅',
  ),
  FilmFormat(
    id: '120_6x12',
    label: '6×12',
    longEdge: 112,
    shortEdge: 56,
    filmWidth: 61,
    note: '112 × 56，宽幅 2:1',
  ),
  FilmFormat(
    id: '120_6x17',
    label: '6×17',
    longEdge: 168,
    shortEdge: 56,
    filmWidth: 61,
    note: '168 × 56，宽幅 3:1',
  ),
];

FilmFormat? formatById(String? id) {
  if (id == null) return null;
  for (final format in kFilmFormats) {
    if (format.id == id) return format;
  }
  return null;
}

/// A crop expressed the way the engine's `geometry_crop_*` wants it: fractions
/// of the source, origin at the top-left.
class CropBox {
  const CropBox(this.x, this.y, this.width, this.height);

  static const CropBox full = CropBox(0, 0, 1, 1);

  final double x;
  final double y;
  final double width;
  final double height;

  bool get isFull => x == 0 && y == 0 && width == 1 && height == 1;
}

/// The largest centred crop of a [sourceWidth] × [sourceHeight] frame whose
/// aspect matches [targetRatio].
///
/// Orientation is not considered: the engine compares long against short, so a
/// portrait frame of the right shape passes the gate check too.
CropBox centreCropForRatio(double targetRatio, int sourceWidth, int sourceHeight) {
  if (sourceWidth <= 0 || sourceHeight <= 0 || targetRatio <= 0) {
    return CropBox.full;
  }
  final sourceRatio = sourceWidth / sourceHeight;
  // Exact match only: 135's 36.25 × 24.3 is 0.55% off 3:2, and hitting the
  // gate exactly is cheaper to reason about than a tolerance ladder.
  if ((sourceRatio - targetRatio).abs() < 1e-9) {
    return CropBox.full;
  }
  if (sourceRatio > targetRatio) {
    // Too wide: keep the full height, trim the sides.
    final width = targetRatio / sourceRatio;
    return CropBox((1 - width) / 2, 0, width, 1);
  }
  // Too tall: keep the full width, trim top and bottom.
  final height = sourceRatio / targetRatio;
  return CropBox(0, (1 - height) / 2, 1, height);
}
