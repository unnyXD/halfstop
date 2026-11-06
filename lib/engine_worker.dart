import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// One rendered frame, already sRGB-encoded by the engine.
class RenderFrame {
  RenderFrame({
    required this.pixels,
    required this.width,
    required this.height,
    required this.meta,
  });

  final Uint8List pixels;
  final int width;
  final int height;
  final Map<String, dynamic> meta;

  double? get renderMs => (meta['render_ms'] as num?)?.toDouble();
  double? get convertMs => (meta['convert_ms'] as num?)?.toDouble();
  double? get engineMs => (meta['engine_ms'] as num?)?.toDouble();
  String? get tier => meta['tier'] as String?;
  bool get reprint => meta['reprint'] == true;
  bool get negativeCached => meta['negative_cached'] == true;
}

/// A native failure that carried the engine's own stage and message.
class EngineFailure implements Exception {
  EngineFailure(this.stage, this.message);

  final String stage;
  final String message;

  @override
  String toString() => '引擎失败 [$stage]: $message';
}

/// Owns one long-lived native engine + session on a worker isolate.
///
/// The engine is the expensive part to create (profiles + shader upload), and
/// a session caches its negative per tier. Keeping both alive is what turns a
/// slider from "restart everything" into "reprint the cached negative".
///
/// Dart FFI pointers cannot cross isolates, so the pointers never leave the
/// worker: commands go in as JSON, pixels come back as [TransferableTypedData].
class EngineWorker {
  EngineWorker._(this._isolate, this._commands, this._replies);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 1;
  bool _closed = false;

  static Future<EngineWorker> start() async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    EngineWorker? worker;
    // A ReceivePort is a single-subscription stream: listen once here and
    // route the handshake port through this listener. `replies.first` would
    // cancel its subscription and make the later `listen` throw.
    replies.listen((dynamic message) {
      if (worker == null) {
        if (message is SendPort) ready.complete(message);
        return;
      }
      worker._onReply(message);
    });

    final isolate = await Isolate.spawn(
      _engineMain,
      replies.sendPort,
      debugName: 'spektrafilm-engine',
    );

    final SendPort commands;
    try {
      commands = await ready.future.timeout(const Duration(seconds: 20));
    } catch (error) {
      isolate.kill(priority: Isolate.immediate);
      replies.close();
      rethrow;
    }
    worker = EngineWorker._(isolate, commands, replies);
    return worker;
  }

  void _onReply(dynamic message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (message['ok'] == true) {
      completer.complete(message['result']);
    } else {
      completer.completeError(EngineFailure(
        message['stage'] as String? ?? 'engine',
        message['error'] as String? ?? 'unknown native failure',
      ));
    }
  }

  Future<Object?> _call(String op, [Map<String, Object?> args = const {}]) {
    if (_closed) throw StateError('engine worker is closed');
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send({'id': id, 'op': op, 'args': args});
    return completer.future;
  }

  /// Creates the engine if needed and opens a RAW on it. Returns the `open`
  /// reply: input size, decode timings, resolved params.
  Future<Map<String, dynamic>> openRaw({
    required String resourcesDir,
    required String rawPath,
    Map<String, Object?> params = const {},
  }) async {
    final result = await _call('open', {
      'resourcesDir': resourcesDir,
      'rawPath': rawPath,
      'params': params,
    });
    return (result as Map).cast<String, dynamic>();
  }

  /// Opens a session on pixels the app decoded itself (a gallery JPEG).
  ///
  /// Skips LibRaw entirely: [pixels] must already be linear ProPhoto RGB
  /// float32, which `photo_import.dart` produces from sRGB.
  Future<Map<String, dynamic>> openImage({
    required String resourcesDir,
    required Float32List pixels,
    required int width,
    required int height,
    Map<String, Object?> params = const {},
  }) async {
    final result = await _call('openImage', {
      'resourcesDir': resourcesDir,
      'pixels': TransferableTypedData.fromList([pixels.buffer.asUint8List()]),
      'width': width,
      'height': height,
      'params': params,
    });
    return (result as Map).cast<String, dynamic>();
  }

  /// Applies a delta to the live session. The reply's `invalidated` says what
  /// the engine dropped; a live parameter keeps the negative, a shoot-layer
  /// change does not.
  Future<Map<String, dynamic>> setParams(Map<String, Object?> delta) async {
    final result = await _call('setParams', {'delta': delta});
    return (result as Map?)?.cast<String, dynamic>() ?? const {};
  }

  Future<Map<String, dynamic>> getParams() async {
    final result = await _call('getParams');
    return (result as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> solve({String target = 'both'}) async {
    final result = await _call('solve', {'target': target});
    return (result as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Reuses the cached negative when it can, runs the film side when it cannot.
  /// This is the call a slider should make.
  Future<RenderFrame> reprint({String tier = 'live'}) async {
    return _frame(await _call('reprint', {'tier': tier}));
  }

  /// Forces the film side to run. Kept for a deliberate "render from scratch".
  Future<RenderFrame> render({String tier = 'preview'}) async {
    return _frame(await _call('render', {'tier': tier}));
  }

  /// The source before the film, for a before/after comparison.
  Future<RenderFrame> exportSource({String tier = 'live'}) async {
    return _frame(await _call('exportSource', {'tier': tier}));
  }

  Future<String> buildInfo() async {
    return (await _call('buildInfo')) as String? ?? 'unknown';
  }

  /// The live engine's capabilities: device limits, tiers, backend.
  Future<Map<String, dynamic>> capabilities() async {
    final result = await _call('capabilities');
    return (result as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// The largest frame this device can bind, in pixels (12 B/px).
  ///
  /// The overscan canvas is a second allocation bigger than the frame, so the
  /// editor asks for this once and picks tier sizes that fit inside it.
  Future<int> maxPlanePixels() async {
    final result = await _call('maxPlanePixels');
    return (result as num?)?.toInt() ?? 0;
  }

  Future<void> close() async {
    if (_closed) return;
    try {
      await _call('close');
    } catch (_) {
      // Closing is best-effort; the isolate is killed below either way.
    }
    _closed = true;
    _replies.close();
    _isolate.kill(priority: Isolate.immediate);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('engine worker closed'));
      }
    }
    _pending.clear();
  }

  static RenderFrame _frame(Object? result) {
    final map = (result as Map).cast<String, dynamic>();
    final pixels = (map['pixels'] as TransferableTypedData).materialize().asUint8List();
    return RenderFrame(
      pixels: pixels,
      width: map['width'] as int,
      height: map['height'] as int,
      meta: (map['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }
}

// --- the worker isolate ---------------------------------------------------

void _engineMain(SendPort main) {
  final commands = ReceivePort();
  main.send(commands.sendPort);

  _NativeSession? native;
  try {
    native = _NativeSession();
  } catch (error) {
    // Still answer commands so `start()` can hand back a usable SendPort and
    // the first call reports the real failure instead of hanging.
    commands.listen((dynamic message) {
      if (message is! Map) return;
      main.send({
        'id': message['id'],
        'ok': false,
        'stage': 'load',
        'error': error.toString(),
      });
    });
    return;
  }

  final session = native;
  commands.listen((dynamic message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    try {
      final op = message['op'] as String? ?? '';
      final args = (message['args'] as Map?)?.cast<String, Object?>() ?? const {};
      final result = session.handle(op, args);
      main.send({'id': id, 'ok': true, 'result': result});
    } on EngineFailure catch (error) {
      main.send({
        'id': id,
        'ok': false,
        'stage': error.stage,
        'error': error.message,
      });
    } catch (error) {
      main.send({
        'id': id,
        'ok': false,
        'stage': 'internal',
        'error': error.toString(),
      });
    }
  });
}

class _NativeSession {
  _NativeSession() {
    final library = DynamicLibrary.open('libspektrafilm.so');
    final abi = library.lookupFunction<Int32 Function(), int Function()>(
      'spk_mobile_abi_version',
    )();
    if (abi != _expectedAbi) {
      throw EngineFailure('abi', 'native ABI $abi, expected $_expectedAbi');
    }

    _engineCreate = library.lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_engine_create',
    );
    _engineDestroy = library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('spk_mobile_engine_destroy');
    _capabilities = library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_engine_capabilities',
    );
    _maxPlanePixels = library.lookupFunction<Uint64 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('spk_mobile_max_plane_pixels');
    _openRaw = library.lookupFunction<
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_open_raw_on',
    );
    _openImage = library.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Float>, Uint32, Uint32,
            Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Float>, int, int,
            Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_open_image_on',
    );
    _sessionRelease = library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('spk_mobile_session_release');
    _setParams = library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_session_set_params',
    );
    _getParams = library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_session_get_params',
    );
    _solve = library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_session_solve',
    );
    _reprint = library.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_session_reprint',
    );
    _render = library.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_session_render',
    );
    _exportSource = library.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
      'spk_mobile_session_export_source',
    );
    _frameRgba8 = library.lookupFunction<Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)>('spk_mobile_frame_rgba8');
    _frameWidth = library.lookupFunction<Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('spk_mobile_frame_width');
    _frameHeight = library.lookupFunction<Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('spk_mobile_frame_height');
    _frameRelease = library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('spk_mobile_frame_release');
    _stringFree = library.lookupFunction<Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)>('spk_mobile_string_free');
    _buildInfo = library.lookupFunction<Pointer<Utf8> Function(),
        Pointer<Utf8> Function()>('spk_mobile_build_info');
  }

  static const int _expectedAbi = 4;

  late final Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)
      _engineCreate;
  late final void Function(Pointer<Void>) _engineDestroy;
  late final int Function(Pointer<Void>, Pointer<Pointer<Utf8>>) _capabilities;
  late final int Function(Pointer<Void>) _maxPlanePixels;
  late final Pointer<Void> Function(
      Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>) _openRaw;
  late final Pointer<Void> Function(Pointer<Void>, Pointer<Float>, int, int,
      Pointer<Utf8>, Pointer<Pointer<Utf8>>) _openImage;
  late final void Function(Pointer<Void>) _sessionRelease;
  late final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)
      _setParams;
  late final int Function(Pointer<Void>, Pointer<Pointer<Utf8>>) _getParams;
  late final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)
      _solve;
  late final Pointer<Void> Function(
      Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>) _reprint;
  late final Pointer<Void> Function(
      Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>) _render;
  late final Pointer<Void> Function(
      Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>) _exportSource;
  late final Pointer<Uint8> Function(Pointer<Void>) _frameRgba8;
  late final int Function(Pointer<Void>) _frameWidth;
  late final int Function(Pointer<Void>) _frameHeight;
  late final void Function(Pointer<Void>) _frameRelease;
  late final void Function(Pointer<Utf8>) _stringFree;
  late final Pointer<Utf8> Function() _buildInfo;

  Pointer<Void> _engine = nullptr;
  Pointer<Void> _session = nullptr;

  Object? handle(String op, Map<String, Object?> args) {
    switch (op) {
      case 'open':
        return _handleOpen(args);
      case 'openImage':
        return _handleOpenImage(args);
      case 'setParams':
        return _handleSetParams(args);
      case 'getParams':
        return _jsonCallNoArg(_getParams, _session, stage: 'params');
      case 'solve':
        return _handleSolve(args);
      case 'reprint':
        return _handleFrame(_reprint, args, fallbackTier: 'live', stage: 'reprint');
      case 'render':
        return _handleFrame(_render, args, fallbackTier: 'preview', stage: 'render');
      case 'exportSource':
        return _handleFrame(_exportSource, args,
            fallbackTier: 'live', stage: 'source');
      case 'buildInfo':
        return _buildInfo().toDartString();
      case 'capabilities':
        return _handleCapabilities();
      case 'maxPlanePixels':
        if (_engine == nullptr) return 0;
        return _maxPlanePixels(_engine);
      case 'status':
        return {
          'engine': _engine != nullptr,
          'session': _session != nullptr,
        };
      case 'close':
        _releaseSession();
        _destroyEngine();
        return {'ok': true};
      default:
        throw EngineFailure('command', 'unknown command "$op"');
    }
  }

  Map<String, dynamic> _handleOpen(Map<String, Object?> args) {
    final resourcesDir = args['resourcesDir'] as String? ?? '';
    final rawPath = args['rawPath'] as String? ?? '';
    final params = (args['params'] as Map?)?.cast<String, Object?>() ?? const {};

    if (resourcesDir.isEmpty) {
      throw EngineFailure('arguments', 'resourcesDir is empty');
    }
    if (rawPath.isEmpty) {
      throw EngineFailure('arguments', 'rawPath is empty');
    }

    _releaseSession();
    _ensureEngine(resourcesDir);

    final replySlot = malloc<Pointer<Utf8>>();
    final rawPtr = rawPath.toNativeUtf8();
    final paramsPtr = jsonEncode(params).toNativeUtf8();
    replySlot.value = nullptr;
    try {
      final session = _openRaw(_engine, rawPtr, paramsPtr, replySlot);
      final reply = _takeReply(replySlot);
      if (session == nullptr) {
        throw _failureFrom(reply, 'open');
      }
      _session = session;
      return _decodeMap(reply);
    } finally {
      malloc.free(rawPtr);
      malloc.free(paramsPtr);
      malloc.free(replySlot);
    }
  }

  Map<String, dynamic> _handleOpenImage(Map<String, Object?> args) {
    final resourcesDir = args['resourcesDir'] as String? ?? '';
    final width = (args['width'] as num?)?.toInt() ?? 0;
    final height = (args['height'] as num?)?.toInt() ?? 0;
    final params = (args['params'] as Map?)?.cast<String, Object?>() ?? const {};
    final pixelsArg = args['pixels'];

    if (resourcesDir.isEmpty) {
      throw EngineFailure('arguments', 'resourcesDir is empty');
    }
    if (width <= 0 || height <= 0 || pixelsArg is! TransferableTypedData) {
      throw EngineFailure('arguments', 'image buffer is missing or empty');
    }

    final bytes = pixelsArg.materialize().asUint8List();
    final count = width * height * 3;
    if (bytes.lengthInBytes < count * 4) {
      throw EngineFailure(
        'arguments',
        'image buffer has ${bytes.lengthInBytes} bytes, expected ${count * 4}',
      );
    }

    _releaseSession();
    _ensureEngine(resourcesDir);

    final native = malloc<Float>(count);
    final replySlot = malloc<Pointer<Utf8>>();
    final paramsPtr = jsonEncode(params).toNativeUtf8();
    replySlot.value = nullptr;
    try {
      native.asTypedList(count).setAll(
            0,
            bytes.buffer.asFloat32List(bytes.offsetInBytes, count),
          );
      final session = _openImage(_engine, native, width, height, paramsPtr, replySlot);
      final reply = _takeReply(replySlot);
      if (session == nullptr) {
        throw _failureFrom(reply, 'openImage');
      }
      _session = session;
      return _decodeMap(reply);
    } finally {
      malloc.free(native);
      malloc.free(paramsPtr);
      malloc.free(replySlot);
    }
  }

  Map<String, dynamic> _handleSetParams(Map<String, Object?> args) {
    final delta = (args['delta'] as Map?)?.cast<String, Object?>() ?? const {};
    return _jsonCall(_setParams, _session, stage: 'params', argument: jsonEncode(delta));
  }

  Map<String, dynamic> _handleSolve(Map<String, Object?> args) {
    final target = args['target'] as String? ?? 'both';
    return _jsonCall(_solve, _session, stage: 'solve', argument: target);
  }

  Map<String, dynamic> _handleCapabilities() {
    if (_engine == nullptr) {
      throw EngineFailure('arguments', 'engine is not created');
    }
    final replySlot = malloc<Pointer<Utf8>>();
    replySlot.value = nullptr;
    try {
      final status = _capabilities(_engine, replySlot);
      final reply = _takeReply(replySlot);
      if (status != 0) {
        throw _failureFrom(reply, 'capabilities');
      }
      return _decodeMap(reply);
    } finally {
      malloc.free(replySlot);
    }
  }

  Map<String, Object?> _handleFrame(
    Pointer<Void> Function(
            Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)
        call,
    Map<String, Object?> args, {
    required String fallbackTier,
    required String stage,
  }) {
    if (_session == nullptr) {
      throw EngineFailure('arguments', 'no RAW is open');
    }
    final tier = (args['tier'] as String?)?.trim();
    final tierPtr = (tier == null || tier.isEmpty ? fallbackTier : tier).toNativeUtf8();
    final replySlot = malloc<Pointer<Utf8>>();
    replySlot.value = nullptr;
    Pointer<Void> frame = nullptr;
    try {
      frame = call(_session, tierPtr, replySlot);
      final reply = _takeReply(replySlot);
      if (frame == nullptr) {
        throw _failureFrom(reply, stage);
      }
      return _frameMap(frame, reply);
    } finally {
      if (frame != nullptr) _frameRelease(frame);
      malloc.free(tierPtr);
      malloc.free(replySlot);
    }
  }

  Map<String, dynamic> _jsonCall(
    int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>) call,
    Pointer<Void> session, {
    required String stage,
    String? argument,
  }) {    if (session == nullptr) {
      throw EngineFailure('arguments', 'no RAW is open');
    }
    final argumentPtr = argument?.toNativeUtf8();
    final replySlot = malloc<Pointer<Utf8>>();
    replySlot.value = nullptr;
    try {
      final status = call(session, argumentPtr ?? nullptr, replySlot);
      final reply = _takeReply(replySlot);
      if (status != 0) {
        throw _failureFrom(reply, stage);
      }
      return _decodeMap(reply);
    } finally {
      if (argumentPtr != null) malloc.free(argumentPtr);
      malloc.free(replySlot);
    }
  }

  Map<String, dynamic> _jsonCallNoArg(
    int Function(Pointer<Void>, Pointer<Pointer<Utf8>>) call,
    Pointer<Void> session, {
    required String stage,
  }) {
    if (session == nullptr) {
      throw EngineFailure('arguments', 'no RAW is open');
    }
    final replySlot = malloc<Pointer<Utf8>>();
    replySlot.value = nullptr;
    try {
      final status = call(session, replySlot);
      final reply = _takeReply(replySlot);
      if (status != 0) {
        throw _failureFrom(reply, stage);
      }
      return _decodeMap(reply);
    } finally {
      malloc.free(replySlot);
    }
  }

  Map<String, Object?> _frameMap(Pointer<Void> frame, String? reply) {
    final width = _frameWidth(frame);
    final height = _frameHeight(frame);
    final pixels = _frameRgba8(frame);
    if (pixels == nullptr || width == 0 || height == 0) {
      throw EngineFailure('render', 'engine returned an empty frame');
    }
    final bytes = Uint8List.fromList(pixels.asTypedList(width * height * 4));
    return {
      'width': width,
      'height': height,
      'meta': _decodeMap(reply),
      'pixels': TransferableTypedData.fromList([bytes]),
    };
  }

  void _ensureEngine(String resourcesDir) {
    if (_engine != nullptr) return;
    final dirPtr = resourcesDir.toNativeUtf8();
    final replySlot = malloc<Pointer<Utf8>>();
    replySlot.value = nullptr;
    try {
      final engine = _engineCreate(dirPtr, replySlot);
      final reply = _takeReply(replySlot);
      if (engine == nullptr) {
        throw _failureFrom(reply, 'engine');
      }
      _engine = engine;
    } finally {
      malloc.free(dirPtr);
      malloc.free(replySlot);
    }
  }

  void _releaseSession() {
    if (_session != nullptr) {
      _sessionRelease(_session);
      _session = nullptr;
    }
  }

  void _destroyEngine() {
    if (_engine != nullptr) {
      _engineDestroy(_engine);
      _engine = nullptr;
    }
  }

  String? _takeReply(Pointer<Pointer<Utf8>> slot) {
    final pointer = slot.value;
    if (pointer == nullptr) return null;
    try {
      final text = pointer.toDartString();
      return text.isEmpty ? null : text;
    } finally {
      _stringFree(pointer);
      slot.value = nullptr;
    }
  }

  static Map<String, dynamic> _decodeMap(String? text) {
    if (text == null || text.isEmpty) return const {};
    try {
      final value = jsonDecode(text);
      return value is Map ? value.cast<String, dynamic>() : const {};
    } on FormatException {
      return {'ok': false, 'error': text};
    }
  }

  static EngineFailure _failureFrom(String? reply, String fallbackStage) {
    final map = _decodeMap(reply);
    return EngineFailure(
      map['stage'] as String? ?? fallbackStage,
      map['error'] as String? ?? 'native call returned no result',
    );
  }
}
