import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A gallery photo, already in the form `spk_open` wants: linear light,
/// ProPhoto RGB primaries, interleaved float32.
///
/// The engine's other input is a RAW, which LibRaw delivers in exactly this
/// space. Ordinary JPEGs are sRGB with a gamma curve, so they need decoding,
/// undo-ing that curve, and a primaries change before the film model sees them
/// — that is all this file does.
class LinearPhoto {
  const LinearPhoto({
    required this.pixels,
    required this.width,
    required this.height,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final Float32List pixels;
  final int width;
  final int height;

  /// Dimensions of the file, before the size cap.
  final int sourceWidth;
  final int sourceHeight;

  int get byteLength => pixels.lengthInBytes;
}

class PhotoImportFailure implements Exception {
  PhotoImportFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Decodes on a worker isolate: a 12 MP JPEG is ~2 s of matrix maths and would
/// stutter the UI if it ran inline.
///
/// [maxEdge] caps the long side before conversion. A phone JPEG is 4000 px,
/// which is 144 MB as float32 triples; anything larger is downsampled first so
/// the isolate does not have to hold the whole thing twice.
Future<LinearPhoto> decodeToLinearProPhoto(String path, {int maxEdge = 4096}) {
  return Isolate.run(() => _decode(path, maxEdge));
}

LinearPhoto _decode(String path, int maxEdge) {
  final file = File(path);
  if (!file.existsSync()) {
    throw PhotoImportFailure('文件不存在：$path');
  }

  img.Image? decoded;
  try {
    decoded = img.decodeImage(file.readAsBytesSync());
  } on Exception catch (error) {
    throw PhotoImportFailure('这个文件解不开：$error');
  }
  if (decoded == null) {
    throw PhotoImportFailure('不支持的图片格式（支持 JPEG / PNG / WebP / BMP）。');
  }

  // Phone photos almost always carry EXIF orientation; without this the film
  // gets a sideways negative.
  var image = img.bakeOrientation(decoded);
  final sourceWidth = image.width;
  final sourceHeight = image.height;

  final longest = math.max(image.width, image.height);
  if (longest > maxEdge) {
    final scale = maxEdge / longest;
    image = img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.cubic,
    );
  }

  final width = image.width;
  final height = image.height;
  final rgba = image.getBytes(order: img.ChannelOrder.rgba);
  final out = Float32List(width * height * 3);

  for (var i = 0, o = 0; i < rgba.length; i += 4, o += 3) {
    final r = _srgbToLinear[rgba[i]];
    final g = _srgbToLinear[rgba[i + 1]];
    final b = _srgbToLinear[rgba[i + 2]];
    // linear sRGB (D65) -> linear ProPhoto (D50), Bradford-adapted.
    out[o] = r * 0.5293709 + g * 0.3300164 + b * 0.1406127;
    out[o + 1] = r * 0.0984619 + g * 0.8735154 + b * 0.0280227;
    out[o + 2] = r * 0.0168760 + g * 0.1094927 + b * 0.8736313;
  }

  return LinearPhoto(
    pixels: out,
    width: width,
    height: height,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
}

/// The sRGB EOTF, tabulated per 8-bit code value. Avoids a `pow` per channel
/// per pixel (36 M of them at 12 MP), which is most of the conversion cost.
final Float32List _srgbToLinear = _buildLut();

Float32List _buildLut() {
  final lut = Float32List(256);
  for (var i = 0; i < 256; i++) {
    final c = i / 255.0;
    lut[i] = c <= 0.04045
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }
  return lut;
}
