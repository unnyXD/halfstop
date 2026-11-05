import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:halfstop/photo_import.dart';

/// The contract with `spk_open`: linear light, ProPhoto primaries, and a
/// neutral pixel stays neutral.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('spk_photo_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  String writePng(List<int> rgbTriples, int width, int height) {
    final image = img.Image(width: width, height: height);
    for (var i = 0; i < rgbTriples.length ~/ 3; i++) {
      image.setPixelRgb(
        i % width,
        i ~/ width,
        rgbTriples[i * 3],
        rgbTriples[i * 3 + 1],
        rgbTriples[i * 3 + 2],
      );
    }
    final path = '${temp.path}/probe.png';
    File(path).writeAsBytesSync(img.encodePng(image));
    return path;
  }

  test('black stays black and white stays white', () async {
    final path = writePng([0, 0, 0, 255, 255, 255], 2, 1);
    final photo = await decodeToLinearProPhoto(path);

    expect(photo.width, 2);
    expect(photo.height, 1);
    expect(photo.pixels.length, 6);

    expect(photo.pixels[0], closeTo(0, 1e-6));
    expect(photo.pixels[1], closeTo(0, 1e-6));
    expect(photo.pixels[2], closeTo(0, 1e-6));

    for (var c = 0; c < 3; c++) {
      expect(photo.pixels[3 + c], closeTo(1.0, 1e-4), reason: 'white channel $c');
    }
  });

  test('a neutral grey stays neutral through the primaries change', () async {
    // 128 sRGB is 0.2158 linear; the ProPhoto matrix rows each sum to 1, so a
    // neutral must come out neutral.
    final path = writePng([128, 128, 128], 1, 1);
    final photo = await decodeToLinearProPhoto(path);

    final r = photo.pixels[0];
    final g = photo.pixels[1];
    final b = photo.pixels[2];
    expect(r, closeTo(0.2158, 0.002));
    expect(g, closeTo(r, 1e-5));
    expect(b, closeTo(r, 1e-5));
  });

  test('mid-grey is linearised, not passed through', () async {
    final path = writePng([128, 128, 128], 1, 1);
    final photo = await decodeToLinearProPhoto(path);
    // A no-op (gamma left in place) would give 0.502 here.
    expect(photo.pixels[1], lessThan(0.3));
  });

  test('oversized images are capped before conversion', () async {
    final wide = img.Image(width: 300, height: 100);
    img.fill(wide, color: img.ColorRgb8(40, 40, 40));
    final path = '${temp.path}/wide.png';
    File(path).writeAsBytesSync(img.encodePng(wide));

    final photo = await decodeToLinearProPhoto(path, maxEdge: 150);
    expect(photo.sourceWidth, 300);
    expect(photo.width, 150);
    expect(photo.height, 50);
  });

  test('a non-image file fails with a readable message', () async {
    final path = '${temp.path}/notes.txt';
    File(path).writeAsStringSync('not an image');
    expect(
      () => decodeToLinearProPhoto(path),
      throwsA(isA<PhotoImportFailure>()),
    );
  });
}
