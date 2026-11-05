import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// What `spk_mobile_probe` reports: the build stamp, what the Vulkan loader
/// found, and whether the real engine came up against the extracted resources.
class EngineProbe {
  EngineProbe({
    required this.build,
    required this.vulkan,
    required this.engine,
  });

  final String build;
  final Map<String, dynamic> vulkan;
  final Map<String, dynamic> engine;

  bool get vulkanOk => vulkan['ok'] == true;
  bool get engineOk => engine['ok'] == true;

  String? get gpuName => vulkan['device'] as String?;
  String? get apiVersion => vulkan['api'] as String?;

  Map<String, dynamic>? get capabilities {
    final caps = engine['capabilities'];
    return caps is Map<String, dynamic> ? caps : null;
  }

  static EngineProbe fromJson(Map<String, dynamic> json) {
    return EngineProbe(
      build: json['build'] as String? ?? 'unknown',
      vulkan: (json['vulkan'] as Map?)?.cast<String, dynamic>() ?? const {},
      engine: (json['engine'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }
}

/// A rendered frame plus what it took to make it.
///
/// The pixels are tightly packed RGBA8888, already sRGB-encoded by the engine,
/// so `ui.ImmutableBuffer` / `ImageDescriptor.raw` can take them unchanged.
class RawRender {
  RawRender({
    required this.pixels,
    required this.width,
    required this.height,
    required this.meta,
  });

  final Uint8List pixels;
  final int width;
  final int height;
  final Map<String, dynamic> meta;

  Map<String, dynamic> get input =>
      (meta['input'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get decode =>
      (meta['decode'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get render =>
      (meta['render'] as Map?)?.cast<String, dynamic>() ?? const {};
}

/// A file the user has already imported, kept in the app's cache so switching
/// tiers does not mean picking it again.
class CachedRaw {
  CachedRaw({
    required this.name,
    required this.path,
    required this.size,
    this.kind = 'raw',
  });

  final String name;
  final String path;
  final int size;

  /// `raw` (LibRaw decodes it) or `photo` (Dart decodes it, then the engine
  /// takes the pixels directly).
  final String kind;

  bool get isPhoto => kind == 'photo';

  String get sizeLabel => '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// A native failure that carried the engine's own message.
class RenderException implements Exception {
  RenderException(this.stage, this.message);

  final String stage;
  final String message;

  @override
  String toString() => '渲染失败 [$stage]: $message';
}

/// Thin dart:ffi binding over `libspektrafilm.so`.
///
/// The engine's C ABI is deliberately JSON-in / buffers-out, so this class
/// stays small: no structs mirror the parameter schema, and a field added
/// upstream never changes the signature here.
class EngineBridge {
  EngineBridge._();

  static const MethodChannel _channel = MethodChannel('spektrafilm/engine');
  static const int expectedAbi = 3;

  static DynamicLibrary? _cached;

  static DynamicLibrary _library() {
    final cached = _cached;
    if (cached != null) return cached;

    if (!Platform.isAndroid) {
      throw UnsupportedError('The Spektrafilm engine currently builds for Android only.');
    }

    final lib = DynamicLibrary.open('libspektrafilm.so');
    final abi = lib
        .lookupFunction<Int32 Function(), int Function()>('spk_mobile_abi_version')();
    if (abi != expectedAbi) {
      throw StateError('Native ABI $abi, expected $expectedAbi. Rebuild the native library.');
    }
    _cached = lib;
    return lib;
  }

  /// The engine's own build stamp, e.g.
  /// `spektrafilm-native 0.1.0 (Nov  2 2026 ..., math=probed)`.
  static String buildInfo() {
    final lib = _library();
    final fn = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
      'spk_mobile_build_info',
    );
    return fn().toDartString();
  }

  /// Creates and destroys a real engine, so a green result means the shaders,
  /// the baked profiles and the GPU all came up.
  static Map<String, dynamic> probeSync(String resourcesDir) {
    final lib = _library();
    final probe =
        lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(
      'spk_mobile_probe',
    );
    final free =
        lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
      'spk_mobile_string_free',
    );

    final dir = resourcesDir.toNativeUtf8();
    try {
      final result = probe(dir);
      if (result == nullptr) {
        throw StateError('Native probe returned null.');
      }
      try {
        final text = result.toDartString();
        return (jsonDecode(text) as Map).cast<String, dynamic>();
      } finally {
        free(result);
      }
    } finally {
      calloc.free(dir);
    }
  }

  /// Asks the Android side to extract `assets/engine/**` into filesDir once and
  /// returns that path. The engine opens its resources by path, not by fd.
  static Future<String> resourcesDir() async {
    final dir = await _channel.invokeMethod<String>('resourcesDir');
    if (dir == null || dir.isEmpty) {
      throw StateError('Engine resources were not extracted.');
    }
    return dir;
  }

  /// Runs the probe off the UI isolate: `spk_engine_create` parses profiles and
  /// uploads the shader bundle, which is far too slow for a frame callback.
  static Future<EngineProbe> probe() async {
    final dir = await resourcesDir();
    final json = await Isolate.run(() => probeSync(dir));
    return EngineProbe.fromJson(json);
  }

  /// Asks Android for a document, copies it into the app's cache and returns
  /// the path. `null` means the user dismissed the picker.
  static Future<String?> pickRaw() => _channel.invokeMethod<String>('pickRaw');

  /// Gallery picker for ordinary photos (JPEG / PNG / WebP / BMP).
  static Future<String?> pickImage() => _channel.invokeMethod<String>('pickImage');

  /// Copies shooting data from the imported file onto an exported JPEG.
  ///
  /// Returns how many tags were carried over; 0 means the source had none the
  /// platform could read (a RAW container it does not parse), and [make] /
  /// [model] from the engine reply were used instead.
  static Future<int> copyExif({
    String? source,
    required String destination,
    String? make,
    String? model,
  }) async {
    final copied = await _channel.invokeMethod<int>('copyExif', {
      'source': source,
      'destination': destination,
      'make': make,
      'model': model,
    });
    return copied ?? 0;
  }

  /// Imported files still in `cacheDir/imports`, newest first.
  static Future<List<CachedRaw>> cachedRaws() async {
    final list =
        await _channel.invokeListMethod<Map<Object?, Object?>>('cachedRaws') ?? const [];
    return list
        .map((entry) => CachedRaw(
              name: entry['name'] as String? ?? 'RAW',
              path: entry['path'] as String? ?? '',
              size: (entry['size'] as num?)?.toInt() ?? 0,
              kind: entry['kind'] as String? ?? 'raw',
            ))
        .where((entry) => entry.path.isNotEmpty)
        .toList();
  }

  /// Decodes a RAW, renders one tier and returns sRGB RGBA8888 pixels.
  ///
  /// Decoding a 24 MP ARW and running the print chain takes seconds, so this
  /// never runs on the UI isolate: the whole native session lives inside one
  /// `Isolate.run`, which also transfers the pixel `Uint8List` back without a
  /// copy.
  static Future<RawRender> renderRaw({
    required String rawPath,
    String tier = 'preview',
    String paramsJson = '{}',
  }) async {
    final dir = await resourcesDir();
    return Isolate.run(
      () => renderRawSync(
        dir,
        rawPath: rawPath,
        tier: tier,
        paramsJson: paramsJson,
      ),
    );
  }

  /// The blocking half of [renderRaw], for a worker isolate.
  ///
  /// `paramsJson` is the engine's delta; the IO colour fields are forced
  /// natively (linear ProPhoto in, sRGB out), so a slider only has to name the
  /// parameter it changes.
  static RawRender renderRawSync(
    String resourcesDir, {
    required String rawPath,
    String tier = 'preview',
    String paramsJson = '{}',
  }) {
    final lib = _library();
    final openRaw = lib.lookupFunction<
        Pointer<Void> Function(
            Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        Pointer<Void> Function(
            Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_open_raw',
    );
    final renderTier = lib.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_session_render',
    );
    final framePixels = lib.lookupFunction<Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)>('spk_mobile_frame_rgba8');
    final frameWidth = lib.lookupFunction<Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('spk_mobile_frame_width');
    final frameHeight = lib.lookupFunction<Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('spk_mobile_frame_height');
    final frameRelease = lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('spk_mobile_frame_release');
    final sessionRelease = lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('spk_mobile_session_release');

    final dirPtr = resourcesDir.toNativeUtf8();
    final pathPtr = rawPath.toNativeUtf8();
    final paramsPtr = paramsJson.toNativeUtf8();
    final tierPtr = tier.toNativeUtf8();
    final openSlot = malloc<Pointer<Utf8>>();
    final renderSlot = malloc<Pointer<Utf8>>();
    openSlot.value = nullptr;
    renderSlot.value = nullptr;

    Pointer<Void> session = nullptr;
    Pointer<Void> frame = nullptr;
    try {
      session = openRaw(dirPtr, pathPtr, paramsPtr, openSlot);
      final openReply = _takeReply(lib, openSlot);
      if (session == nullptr) {
        throw RenderException(
          openReply['stage'] as String? ?? 'open',
          openReply['error'] as String? ?? 'engine returned no session',
        );
      }

      frame = renderTier(session, tierPtr, renderSlot);
      final renderReply = _takeReply(lib, renderSlot);
      if (frame == nullptr) {
        throw RenderException(
          renderReply['stage'] as String? ?? 'render',
          renderReply['error'] as String? ?? 'engine returned no frame',
        );
      }

      final width = frameWidth(frame);
      final height = frameHeight(frame);
      final pixels = framePixels(frame);
      if (pixels == nullptr || width == 0 || height == 0) {
        throw RenderException('render', 'engine returned an empty frame');
      }
      // Copy out before the frame is released; the native buffer dies with it.
      final rgba = Uint8List.fromList(pixels.asTypedList(width * height * 4));
      return RawRender(
        pixels: rgba,
        width: width,
        height: height,
        meta: {...openReply, 'render': renderReply},
      );
    } finally {
      if (frame != nullptr) frameRelease(frame);
      if (session != nullptr) sessionRelease(session);
      malloc.free(dirPtr);
      malloc.free(pathPtr);
      malloc.free(paramsPtr);
      malloc.free(tierPtr);
      malloc.free(openSlot);
      malloc.free(renderSlot);
    }
  }

  /// Reads a caller-owned JSON reply and frees the native string.
  static Map<String, dynamic> _takeReply(DynamicLibrary lib, Pointer<Pointer<Utf8>> slot) {
    final pointer = slot.value;
    if (pointer == nullptr) return const {};
    try {
      final text = pointer.toDartString();
      if (text.isEmpty) return const {};
      try {
        return (jsonDecode(text) as Map).cast<String, dynamic>();
      } on FormatException {
        return {'ok': false, 'error': text};
      }
    } finally {
      final free = lib.lookupFunction<Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)>('spk_mobile_string_free');
      free(pointer);
      slot.value = nullptr;
    }
  }
}
