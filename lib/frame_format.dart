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

  /// Room to move on each axis. A crop that already spans the frame has none.
  double get slackX => (1 - width).clamp(0.0, 1.0);
  double get slackY => (1 - height).clamp(0.0, 1.0);

  /// The same window moved by (dx, dy) in normalised units, clamped so it
  /// cannot leave the frame. Axes without slack simply do not move.
  CropBox shifted(double dx, double dy) => CropBox(
        (x + dx).clamp(0.0, slackX),
        (y + dy).clamp(0.0, slackY),
        width,
        height,
      );

  /// Where the window sits inside the available slack: 0.5 is centred.
  double get positionX => slackX <= 0 ? 0.5 : (x / slackX).clamp(0.0, 1.0);
  double get positionY => slackY <= 0 ? 0.5 : (y / slackY).clamp(0.0, 1.0);

  bool get isCentred =>
      (positionX - 0.5).abs() < 0.02 && (positionY - 0.5).abs() < 0.02;

  double get centerX => x + width / 2;
  double get centerY => y + height / 2;

  /// Ratio in normalised units. Only equal to the picture's ratio when the
  /// frame and the crop have the same aspect, which is why callers that need a
  /// real aspect pass the frame's size along.
  double get ratio => height <= 0 ? 1 : width / height;

  /// The aspect as the viewer sees it, given the frame's pixel size.
  double aspect(double frameWidth, double frameHeight) =>
      height <= 0 ? 1 : (width * frameWidth) / (height * frameHeight);

  /// Human-readable placement, e.g. `水平 62% · 垂直 50%`.
  String get placementLabel {
    if (isCentred) return '居中';
    final h = (positionX * 100).round();
    final v = (positionY * 100).round();
    return '水平 $h% · 垂直 $v%';
  }
}

/// Which grip of the crop window is being dragged.
enum CropHandle { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

/// Move one edge or corner of [crop] by (dx, dy) in normalised units.
///
/// [lockedAspect] is the ratio the *picture* must keep (`width * frameWidth /
/// (height * frameHeight)`); when given, the other axis follows so the window
/// keeps that shape. Without it the window is free.
CropBox resizeCrop(
  CropBox crop,
  CropHandle handle,
  double dx,
  double dy, {
  double? lockedAspect,
  double minSize = 0.08,
  double frameWidth = 1,
  double frameHeight = 1,
}) {
  var left = crop.x;
  var top = crop.y;
  var right = crop.x + crop.width;
  var bottom = crop.y + crop.height;

  switch (handle) {
    case CropHandle.topLeft:
      left += dx;
      top += dy;
    case CropHandle.top:
      top += dy;
    case CropHandle.topRight:
      right += dx;
      top += dy;
    case CropHandle.right:
      right += dx;
    case CropHandle.bottomRight:
      right += dx;
      bottom += dy;
    case CropHandle.bottom:
      bottom += dy;
    case CropHandle.bottomLeft:
      left += dx;
      bottom += dy;
    case CropHandle.left:
      left += dx;
  }

  // Bring both edges back into the frame first (a big drag can overshoot by
  // any amount), then enforce the minimum size on whichever edge moved.
  left = left.clamp(0.0, 1.0);
  right = right.clamp(0.0, 1.0);
  top = top.clamp(0.0, 1.0);
  bottom = bottom.clamp(0.0, 1.0);

  if (right - left < minSize) {
    final draggedLeft = handle == CropHandle.topLeft ||
        handle == CropHandle.bottomLeft ||
        handle == CropHandle.left;
    if (draggedLeft) {
      left = (right - minSize).clamp(0.0, 1.0);
    } else {
      right = (left + minSize).clamp(0.0, 1.0);
    }
    if (right - left < minSize) return crop;
  }
  if (bottom - top < minSize) {
    final draggedTop = handle == CropHandle.topLeft ||
        handle == CropHandle.topRight ||
        handle == CropHandle.top;
    if (draggedTop) {
      top = (bottom - minSize).clamp(0.0, 1.0);
    } else {
      bottom = (top + minSize).clamp(0.0, 1.0);
    }
    if (bottom - top < minSize) return crop;
  }

  if (lockedAspect != null && lockedAspect > 0 && frameWidth > 0 && frameHeight > 0) {
    // Target width/height expressed in normalised units.
    final k = lockedAspect * frameHeight / frameWidth;
    final horizontal = handle == CropHandle.left || handle == CropHandle.right;

    if (horizontal) {
      var width = right - left;
      var height = width / k;
      final centreY = (top + bottom) / 2;
      if (height > 1) {
        height = 1;
        width = height * k;
        left = left.clamp(0.0, 1.0 - width);
        right = left + width;
      }
      top = centreY - height / 2;
      bottom = top + height;
    } else {
      var height = bottom - top;
      var width = height * k;
      final centreX = (left + right) / 2;
      if (width > 1) {
        width = 1;
        height = width / k;
        top = top.clamp(0.0, 1.0 - height);
        bottom = top + height;
      }
      left = centreX - width / 2;
      right = left + width;
    }

    // Pull the window back inside the frame, shrinking if it must.
    if (left < 0) {
      right -= left;
      left = 0;
    }
    if (right > 1) {
      left -= right - 1;
      right = 1;
    }
    if (top < 0) {
      bottom -= top;
      top = 0;
    }
    if (bottom > 1) {
      top -= bottom - 1;
      bottom = 1;
    }
    if (right - left < minSize || bottom - top < minSize) {
      return crop;
    }
  }

  return CropBox(left, top, right - left, bottom - top);
}

/// Scale [crop] about its own centre, keeping it inside the frame. This is
/// what a pinch does: the window shrinks or grows but never leaves the picture.
CropBox scaleCrop(CropBox crop, double factor, {double minSize = 0.08}) {
  if (factor <= 0) return crop;
  final width = (crop.width * factor).clamp(minSize, 1.0);
  final height = (crop.height * factor).clamp(minSize, 1.0);
  final x = (crop.x + (crop.width - width) / 2).clamp(0.0, 1.0 - width);
  final y = (crop.y + (crop.height - height) / 2).clamp(0.0, 1.0 - height);
  return CropBox(x, y, width, height);
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
