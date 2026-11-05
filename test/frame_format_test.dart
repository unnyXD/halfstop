import 'package:flutter_test/flutter_test.dart';
import 'package:halfstop/frame_format.dart';

/// The engine rejects a frame whose aspect is more than 5% off the gate's, so
/// the crop has to be right before the request is ever sent.
void main() {
  _cropPlacementTests();
  _cropResizeTests();

  test('a 3:2 camera frame barely moves for 135, and not at all for 6x9', () {
    // 135's gate is 36.25 × 24.3 — 0.55% off 3:2, so the crop is a sliver.
    final for135 = centreCropForRatio(formatById('135')!.ratio, 6000, 4000);
    expect(for135.height, 1.0);
    expect(for135.width, greaterThan(0.99));
    expect(for135.width, lessThan(1.0));

    // 6x9 is exactly 3:2.
    final for6x9 = centreCropForRatio(formatById('120_6x9')!.ratio, 6000, 4000);
    expect(for6x9.isFull, isTrue);
  });

  test('a 3:2 frame is trimmed at the sides for 4:3 gates', () {
    final crop = centreCropForRatio(formatById('120_645')!.ratio, 6000, 4000);
    expect(crop.height, 1.0);
    expect(crop.width, closeTo(4000 * (56 / 41.5) / 6000, 1e-9));
    expect(crop.x, closeTo((1 - crop.width) / 2, 1e-9));
    expect(crop.y, 0);
  });

  test('a 3:2 frame is trimmed top and bottom for panoramic gates', () {
    final crop = centreCropForRatio(formatById('135_xpan')!.ratio, 6000, 4000);
    expect(crop.width, 1.0);
    expect(crop.y, greaterThan(0));
    expect(crop.y, closeTo((1 - crop.height) / 2, 1e-9));
  });

  test('the cropped aspect matches the gate, both orientations', () {
    for (final format in kFilmFormats) {
      final landscape = centreCropForRatio(format.ratio, 6000, 4000);
      final croppedRatio = (landscape.width * 6000) / (landscape.height * 4000);
      expect(
        croppedRatio,
        closeTo(format.ratio, format.ratio * 0.01),
        reason: '${format.id} landscape',
      );

      final portrait = centreCropForRatio(format.ratio, 4000, 6000);
      final portraitRatio = (portrait.width * 4000) / (portrait.height * 6000);
      // The engine compares long against short, so swapping them is fine.
      final normalised = portraitRatio >= 1 ? portraitRatio : 1 / portraitRatio;
      expect(
        normalised,
        closeTo(format.ratio, format.ratio * 0.01),
        reason: '${format.id} portrait',
      );
    }
  });

  test('a frame that already matches the gate is left essentially untouched', () {
    for (final format in kFilmFormats) {
      // Integer pixel heights cannot express every ratio exactly, so "already
      // matching" means the crop only shaves a rounding error.
      final height = (6000 / format.ratio).round();
      final crop = centreCropForRatio(format.ratio, 6000, height);
      expect(crop.width, greaterThan(0.999), reason: format.id);
      expect(crop.height, greaterThan(0.999), reason: format.id);
    }
  });

  test('degenerate input does not produce a zero crop', () {
    final crop = centreCropForRatio(1.5, 0, 0);
    expect(crop.isFull, isTrue);
  });

  test('every id the picker offers is one the engine knows', () {
    const engineFormats = {
      '135', '135_half', '120_645', '120_6x6', '120_6x7',
      '120_6x8', '120_6x9', '135_xpan', '120_6x12', '120_6x17',
    };
    expect(kFilmFormats.map((format) => format.id).toSet(), engineFormats);
  });
}

void _cropPlacementTests() {
  test('a centred crop reports itself as centred', () {
    final crop = centreCropForRatio(1.0, 6000, 4000); // square gate on 3:2
    expect(crop.isCentred, isTrue);
    expect(crop.placementLabel, '居中');
    expect(crop.positionX, closeTo(0.5, 0.01));
  });

  test('shifting stops at the edge of the frame', () {
    final crop = centreCropForRatio(1.0, 6000, 4000);
    final right = crop.shifted(5, 0);
    expect(right.x, closeTo(crop.slackX, 1e-9));
    expect(right.positionX, closeTo(1.0, 1e-9));

    final left = crop.shifted(-5, 0);
    expect(left.x, closeTo(0.0, 1e-9));
    expect(left.positionX, closeTo(0.0, 1e-9));
  });

  test('an axis with no slack does not move', () {
    // 3:2 gate on a 3:2 frame: nothing to trim, so nothing to pan.
    final crop = centreCropForRatio(1.5, 6000, 4000);
    expect(crop.isFull, isTrue);
    final moved = crop.shifted(0.2, 0.2);
    expect(moved.x, 0);
    expect(moved.y, 0);
  });

  test('the label shows the actual placement once moved', () {
    final crop = centreCropForRatio(1.0, 6000, 4000).shifted(0.1, 0);
    expect(crop.isCentred, isFalse);
    expect(crop.placementLabel, contains('水平'));
  });
}

void _cropResizeTests() {
  const crop = CropBox(0.2, 0.2, 0.6, 0.6);

  test('dragging the right edge only moves the right edge', () {
    final resized = resizeCrop(crop, CropHandle.right, 0.1, 0);
    expect(resized.x, closeTo(0.2, 1e-9));
    expect(resized.width, closeTo(0.7, 1e-9));
    expect(resized.height, closeTo(0.6, 1e-9));
  });

  test('dragging a corner moves both of its edges', () {
    final resized = resizeCrop(crop, CropHandle.topLeft, 0.05, 0.05);
    expect(resized.x, closeTo(0.25, 1e-9));
    expect(resized.y, closeTo(0.25, 1e-9));
    expect(resized.width, closeTo(0.55, 1e-9));
    expect(resized.height, closeTo(0.55, 1e-9));
  });

  test('the window cannot be dragged past the frame', () {
    final resized = resizeCrop(crop, CropHandle.right, 5, 0);
    expect(resized.x + resized.width, closeTo(1.0, 1e-9));
    final shrunk = resizeCrop(crop, CropHandle.right, -5, 0);
    expect(shrunk.width, greaterThanOrEqualTo(0.08));
  });

  test('a locked aspect keeps the ratio while resizing', () {
    // A 3:1 gate on a 3:2 frame: w/h must be 3 * 2 / 3 = 2 in normalised units.
    final start = const CropBox(0.1, 0.1, 0.5, 0.5);
    final resized = resizeCrop(
      start,
      CropHandle.right,
      0.2,
      0,
      lockedAspect: 3.0,
      frameWidth: 3.0,
      frameHeight: 2.0,
    );
    expect(resized.width / resized.height, closeTo(2.0, 0.01));
    // The dragged edge moved; the opposite one stayed.
    expect(resized.x, closeTo(0.1, 1e-9));
  });

  test('pinch scales about the centre', () {
    final scaled = scaleCrop(crop, 0.5);
    expect(scaled.width, closeTo(0.3, 1e-9));
    expect(scaled.centerX, closeTo(crop.centerX, 1e-9));
  });
}
