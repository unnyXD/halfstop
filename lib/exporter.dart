import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'engine_bridge.dart';
import 'layer2.dart';

/// Result of a finished export.
class ExportedPhoto {
  const ExportedPhoto({
    required this.path,
    required this.width,
    required this.height,
    required this.bytes,
    required this.inGallery,
    this.exifTags = 0,
  });

  final String path;
  final int width;
  final int height;
  final int bytes;

  /// False when the gallery write failed and the file only lives in app storage.
  final bool inGallery;

  /// How many shooting-data tags came across from the imported file.
  final int exifTags;

  String get sizeLabel {
    final mb = bytes / (1024 * 1024);
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(bytes / 1024).round()} KB';
  }
}

class ExportFailure implements Exception {
  ExportFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Encode on a separate isolate: a 24 MP frame takes seconds in pure Dart and
/// would drop frames on the UI thread if it ran there.
///
/// The engine's pixels are already sRGB-encoded RGBA8 (see `frame_from_result`
/// in spk_mobile.cpp), so they go straight into a JPEG without any colour
/// conversion — what the preview shows is what the file contains.
Future<ExportedPhoto> encodeAndSave({
  required Uint8List pixels,
  required int width,
  required int height,
  required String fileName,
  int? longEdge,
  int quality = 92,
  List<double>? matrix,
  String? sourcePath,
  String? make,
  String? model,
}) async {
  final encoded = await Isolate.run(
    () => _encodeJpeg(
      pixels: pixels,
      width: width,
      height: height,
      longEdge: longEdge,
      quality: quality,
      matrix: matrix,
    ),
  );

  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}/$fileName');
  await file.writeAsBytes(encoded.bytes, flush: true);

  // Shooting data goes on before the gallery write, because `gal` copies the
  // file: whatever EXIF the temp file has is what the album entry gets.
  var exifTags = 0;
  try {
    exifTags = await EngineBridge.copyExif(
      source: sourcePath,
      destination: file.path,
      make: make,
      model: model,
    );
  } catch (_) {
    // Losing EXIF should never cost the export itself.
  }

  var inGallery = false;
  try {
    if (!await Gal.hasAccess(toAlbum: true)) {
      await Gal.requestAccess(toAlbum: true);
    }
    await Gal.putImage(file.path, album: 'Spektrafilm');
    inGallery = true;
  } on GalException {
    // Saving to the gallery is the goal, not a precondition: keep the file in
    // the app's own storage so a failed MediaStore write still yields a result.
    final fallback = await getApplicationDocumentsDirectory();
    final copy = File('${fallback.path}/$fileName');
    await file.copy(copy.path);
    return ExportedPhoto(
      path: copy.path,
      width: encoded.width,
      height: encoded.height,
      bytes: encoded.bytes.length,
      inGallery: false,
      exifTags: exifTags,
    );
  }

  return ExportedPhoto(
    path: file.path,
    width: encoded.width,
    height: encoded.height,
    bytes: encoded.bytes.length,
    inGallery: inGallery,
    exifTags: exifTags,
  );
}

class _Encoded {
  _Encoded(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;
}

_Encoded _encodeJpeg({
  required Uint8List pixels,
  required int width,
  required int height,
  int? longEdge,
  required int quality,
  List<double>? matrix,
}) {
  if (matrix != null) {
    // Same matrix the preview drew with, replayed on the real pixels.
    Layer2Params.applyToRgba8(pixels, matrix);
  }
  img.Image image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: pixels.buffer,
    order: img.ChannelOrder.rgba,
    numChannels: 4,
  );

  final longest = width > height ? width : height;
  if (longEdge != null && longEdge > 0 && longest > longEdge) {
    final scale = longEdge / longest;
    final targetW = (width * scale).round();
    final targetH = (height * scale).round();
    image = img.copyResize(
      image,
      width: targetW,
      height: targetH,
      interpolation: img.Interpolation.cubic,
    );
  }

  final bytes = img.encodeJpg(image, quality: quality.clamp(40, 100));
  return _Encoded(bytes, image.width, image.height);
}

/// `spektrafilm_20261105_121503_kodak_portra_400.jpg`
String exportFileName(String filmId, {DateTime? now}) {
  final stamp = (now ?? DateTime.now());
  String two(int v) => v.toString().padLeft(2, '0');
  final date =
      '${stamp.year}${two(stamp.month)}${two(stamp.day)}_${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}';
  final slug = filmId.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
  return 'spektrafilm_${date}_$slug.jpg';
}
