import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'engine_bridge.dart';
import 'engine_worker.dart';
import 'exporter.dart';
import 'frame_format.dart';
import 'histogram.dart';
import 'layer2.dart';
import 'photo_import.dart';
import 'stock_catalog.dart';

// Darkroom palette: warm black, paper white, safelight amber.
const Color _kBackground = Color(0xFF0A0908);
const Color _kSurface = Color(0xFF14120F);
const Color _kSurfaceHigh = Color(0xFF1C1916);
const Color _kLine = Color(0xFF221F1B);
const Color _kLineStrong = Color(0xFF3A342C);
const Color _kAccent = Color(0xFFE3A35C);
const Color _kText = Color(0xFFEDE6DA);
const Color _kTextDim = Color(0xFF8C857A);

/// 预览档位。注意：这里的 “live / 实时” 是引擎的**低延迟预览**，与 Live Photo
/// （实况照片）无关。本项目只处理静态 RAW，不涉及任何实况照片能力。
///
/// 引擎侧 tier 字符串仍是 `'live'`（C++ 契约 `spk_reprint` 的入参），不要改。
enum PreviewQuality { fast, fine }

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  static const int _previewEdge = 1600;

  EngineWorker? _worker;
  String? _resourcesDir;
  List<Stock> _stocks = const [];
  List<CachedRaw> _cached = const [];

  bool _booting = true;
  bool _busy = false;
  bool _liveBusy = false;
  bool _liveDirty = false;
  Timer? _debounce;

  String? _error;
  String? _busyLabel;
  String? _path;
  bool _sessionOpen = false;
  Map<String, dynamic> _openInfo = const {};

  ui.Image? _image;
  ui.Image? _sourceImage;
  bool _showingSource = false;
  int _imageWidth = 0;
  int _imageHeight = 0;
  int _liveFrames = 0;
  int _lastLiveMs = 0;
  bool _lastReprint = false;
  PreviewQuality _quality = PreviewQuality.fast;

  String _film = 'kodak_portra_400';
  String _paper = 'kodak_portra_endura';

  double _exposureEv = 0;
  double _magenta = 0;
  double _yellow = 0;
  double _shiftScale = 1;
  double _preflash = 0;

  /// 0..1, where 1 is the full film render and 0 is the untouched source.
  /// Implemented as a composite, not an engine parameter: the engine has no
  /// notion of "half a film".
  double _strength = 1;

  double _grain = 1;
  double _halation = 1;
  double _glare = 0;

  /// Undo stack of edit states. Snapshots are pushed at the start of a gesture,
  /// not per frame, so one slider drag is one undo step.
  static const int _maxUndo = 20;
  final List<_EditSnapshot> _history = [];

  bool _exporting = false;

  /// Layer 2: the digital colour layer. Applied on the GPU by the preview and
  /// replayed in Dart on export, so no engine round-trip is involved.
  Layer2Params _layer2 = Layer2Params.neutral;
  Uint8List? _framePixels;
  Histogram? _histogram;
  bool _showHistogram = true;
  _PanelLayer _panelLayer = _PanelLayer.print;

  /// Frame geometry. Everything here is SHOOT layer in the engine: changing it
  /// re-develops the negative, so these are "commit on release" controls.
  FilmFormat? _format;
  bool _overscanOn = false;
  /// `strip` lays out the whole film width, `filed` a sliver of rebate.
  final String _overscanMode = 'strip';
  String _holes = 'white';
  String _carrier = 'none';
  double _edgeFog = 1;
  double _leaks = 0;

  bool _dateOn = false;
  String _dateText = '';
  String _dateStyle = 'lcd';
  String _datePlacement = 'frame';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _image?.dispose();
    _sourceImage?.dispose();
    _worker?.close();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final worker = await EngineWorker.start();
      final resourcesDir = await EngineBridge.resourcesDir();
      final stocks = await loadStocks(resourcesDir);
      final cached = await EngineBridge.cachedRaws();
      if (!mounted) {
        await worker.close();
        return;
      }
      final films = stocks.where((stock) => stock.isFilm).toList();
      final papers = stocks.where((stock) => stock.isPrintStock).toList();
      setState(() {
        _worker = worker;
        _resourcesDir = resourcesDir;
        _stocks = stocks;
        _cached = cached;
        if (films.isNotEmpty && !films.any((stock) => stock.id == _film)) {
          _film = films.first.id;
        }
        if (papers.isNotEmpty && !papers.any((stock) => stock.id == _paper)) {
          _paper = papers.first.id;
        }
        _booting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _booting = false;
      });
    }
  }


  String _stockName(String id) {
    for (final stock in _stocks) {
      if (stock.id == id) return stock.name;
    }
    return id;
  }

  bool get _hasSession =>
      _sessionOpen && _worker != null && _resourcesDir != null;

  Map<String, Object?> _liveDelta() => {
        // The engine's `print_exposure` is an enlarger *exposure multiplier*:
        // it scales the light the print gets, so a larger value means a denser
        // (darker) print. The slider is a brightness control, hence 2^-EV:
        // `print_exposure = 2^-stops` is the engine's own convention (see
        // di_live_offsets in digital_intermediate.cpp).
        'print_exposure': math.pow(2, -_exposureEv).toDouble(),
        'm_filter_shift': _magenta,
        'y_filter_shift': _yellow,
        'filter_shift_scale': _shiftScale,
        'preflash_exposure': _preflash,
      };

  Map<String, Object?> _slowDelta() => {
        'grain_amount': _grain,
        'halation_amount': _halation,
        'glare_amount': _glare,
      };

  /// The toolbar's "+" asks which of the two entries to use.
  Future<void> _import() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _kSurface,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: _kAccent),
              title: const Text('从相册选择'),
              subtitle: const Text('JPEG / PNG / WebP，本机解码后进引擎'),
              onTap: () => Navigator.of(context).pop('photo'),
            ),
            ListTile(
              leading: const Icon(Icons.raw_on_outlined, color: _kAccent),
              title: const Text('RAW 文件'),
              subtitle: const Text('ARW / DNG / CR2 / CR3 / NEF / RAF…，LibRaw 解码'),
              onTap: () => Navigator.of(context).pop('raw'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'photo') {
      await _importPhoto();
    } else if (choice == 'raw') {
      await _importRaw();
    }
  }

  Future<void> _importRaw() async {
    try {
      final path = await EngineBridge.pickRaw();
      if (path != null) await _openPath(path);
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _importPhoto() async {
    try {
      final path = await EngineBridge.pickImage();
      if (path != null) await _openPhoto(path);
    } catch (error) {
      _setError(error);
    }
  }

  int get _sourceWidth =>
      ((_openInfo['input'] as Map?)?['source_width'] as num?)?.toInt() ?? _imageWidth;

  int get _sourceHeight =>
      ((_openInfo['input'] as Map?)?['source_height'] as num?)?.toInt() ?? _imageHeight;

  /// The crop that makes this frame the selected gate's shape. Null format
  /// means "leave the frame alone".
  CropBox get _cropBox {
    final format = _format;
    if (format == null) return CropBox.full;
    return centreCropForRatio(format.ratio, _sourceWidth, _sourceHeight);
  }

  Map<String, Object?> _frameDelta() {
    final crop = _cropBox;
    return {
      'geometry_crop_x': crop.x,
      'geometry_crop_y': crop.y,
      'geometry_crop_w': crop.width,
      'geometry_crop_h': crop.height,
      'overscan_active': _format != null && _overscanOn,
      if (_format != null) 'overscan_format': _format!.id,
      'overscan_mode': _overscanMode,
      'overscan_holes': _holes,
      'overscan_carrier': _carrier,
      'overscan_fog': _edgeFog,
      'overscan_leaks': _leaks,
      'date_imprint_active': _dateOn,
      if (_dateOn) 'date_imprint_text': _dateText.isEmpty ? defaultDateText() : _dateText,
      if (_dateOn) 'date_imprint_style': _dateStyle,
      // The rebate only exists when the rebate is drawn.
      if (_dateOn)
        'date_imprint_placement':
            (_format != null && _overscanOn) ? _datePlacement : 'frame',
    };
  }

  /// `'26 11 5` — the shape the engine's LCD face expects.
  static String defaultDateText([DateTime? now]) {
    final t = now ?? DateTime.now();
    final yy = (t.year % 100).toString().padLeft(2, '0');
    return "'$yy ${t.month} ${t.day}";
  }

  /// Frame changes are SHOOT layer: the negative is re-developed, so this is
  /// always a deliberate, slow commit rather than a live drag.
  Future<void> _applyFrame({String? label}) async {
    if (!_hasSession || _busy) return;
    // No undo entry: these are single taps with a visible result, and undoing
    // them would have to re-develop the negative all over again.
    setState(() {
      _busy = true;
      _busyLabel = label ?? '重算底片…';
    });
    try {
      await _worker!.setParams({
        ..._liveDelta(),
        ..._slowDelta(),
        ..._frameDelta(),
        'film_stock': _film,
        'print_stock': _paper,
      });
      final frame = await _worker!.reprint(tier: 'live');
      await _showFrame(frame, fast: true, wallMs: null);
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
        // The frame's shape changed, so the cached "before" no longer lines up
        // with it; the strength composite needs a fresh one.
        final stale = _sourceImage;
        if (stale != null) {
          setState(() => _sourceImage = null);
          WidgetsBinding.instance.addPostFrameCallback((_) => stale.dispose());
        }
        unawaited(_ensureSource());
      }
    }
  }

  /// Back to the picker without restarting: the engine keeps its resources,
  /// only the session's picture goes away.
  void _closeImage() {
    final image = _image;
    final source = _sourceImage;
    setState(() {
      _image = null;
      _sourceImage = null;
      _showingSource = false;
      _sessionOpen = false;
      _path = null;
      _openInfo = const {};
      _histogram = null;
      _framePixels = null;
      _imageWidth = 0;
      _imageHeight = 0;
      _history.clear();
      _format = null;
      _overscanOn = false;
      _dateOn = false;
    });
    image?.dispose();
    source?.dispose();
    unawaited(EngineBridge.cachedRaws().then((cached) {
      if (mounted) setState(() => _cached = cached);
    }));
  }

  Future<void> _pickFormat(FilmFormat? format) async {
    if (format?.id == _format?.id) return;
    setState(() {
      _format = format;
      if (format == null) {
        _overscanOn = false;
        _datePlacement = 'frame';
      }
    });
    await _applyFrame(label: format == null ? '恢复原比例…' : '按 ${format.label} 重算…');
  }

  Future<void> _editDateText() async {
    final controller = TextEditingController(text: _dateText);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _kSurface,
        title: const Text('日期后背'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            hintText: "'26 11 5",
            helperText: '按后背的字面写，不自动格式化',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    setState(() => _dateText = value);
    await _applyFrame(label: '重打日期…');
  }

  Future<void> _deleteCached(CachedRaw entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _kSurface,
        title: const Text('删除导入缓存'),
        content: Text('${entry.name}\n${entry.sizeLabel}\n\n只删应用内的缓存副本，DCIM 或相册里的原文件不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC25B5B)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final deleted = await EngineBridge.deleteCached(entry.path);
    if (!mounted) return;
    if (!deleted) {
      _setError('删除失败：${entry.name}');
      return;
    }
    final cached = await EngineBridge.cachedRaws();
    if (!mounted) return;
    setState(() {
      _cached = cached;
      if (_path == entry.path) _path = null;
    });
  }

  void _openCached(CachedRaw entry) {
    if (entry.isPhoto) {
      _openPhoto(entry.path);
    } else {
      _openPath(entry.path);
    }
  }

  /// The gallery path. Two decodes happen: Dart turns the JPEG into linear
  /// ProPhoto, then the engine treats those pixels as if LibRaw had produced
  /// them — same film model, same sliders, no RAW required.
  Future<void> _openPhoto(String path) async {
    if (_worker == null || _resourcesDir == null) return;
    _debounce?.cancel();
    setState(() {
      _busy = true;
      _busyLabel = '解码图片…';
      _error = null;
      _sessionOpen = false;
      _liveFrames = 0;
      _showingSource = false;
    });
    try {
      LinearPhoto? photo = await decodeToLinearProPhoto(path);
      if (!mounted) return;
      setState(() => _busyLabel = '送进渲染引擎…');
      final reply = await _worker!.openImage(
        resourcesDir: _resourcesDir!,
        pixels: photo.pixels,
        width: photo.width,
        height: photo.height,
        params: {
          'preview_long_edge': _previewEdge,
          'film_stock': _film,
          'print_stock': _paper,
          ..._liveDelta(),
          ..._slowDelta(),
        },
      );
      // ~144 MB of float32 at 12 MP; the engine has its own copy now.
      photo = null;
      if (!mounted) return;
      setState(() {
        _openInfo = reply;
        _path = path;
        _sessionOpen = true;
        _busyLabel = '渲染中…';
      });
      final frame = await _worker!.reprint(tier: 'live');
      await _showFrame(frame, fast: true, wallMs: null);
      unawaited(_ensureSource());
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _openPath(String path) async {
    if (_worker == null || _resourcesDir == null) return;
    _debounce?.cancel();
    setState(() {
      _busy = true;
      _busyLabel = '解码 RAW…';
      _error = null;
      _sessionOpen = false;
      _liveFrames = 0;
      _showingSource = false;
    });
    try {
      final reply = await _worker!.openRaw(
        resourcesDir: _resourcesDir!,
        rawPath: path,
        params: {
          'preview_long_edge': _previewEdge,
          'film_stock': _film,
          'print_stock': _paper,
          ..._liveDelta(),
          ..._slowDelta(),
        },
      );
      if (!mounted) return;
      setState(() {
        _openInfo = reply;
        _path = path;
        _sessionOpen = true;
      });
      final frame = await _worker!.reprint(tier: 'live');
      await _showFrame(frame, fast: true, wallMs: null);
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  /// Loads the "before" frame once, at preview size. The before/after toggle
  /// uses it, and so does the strength composite — which is why it is fetched
  /// as soon as an image opens rather than on first demand.
  Future<void> _ensureSource() async {
    if (_sourceImage != null || !_hasSession || _busy) return;
    try {
      final frame = await _worker!.exportSource(tier: 'live');
      final image = await _imageFromFrame(frame);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _sourceImage = image);
    } catch (error) {
      _setError(error);
    }
  }

  void _setError(Object error) {
    if (!mounted) return;
    setState(() => _error = error.toString());
  }

  _EditSnapshot _snapshot() => _EditSnapshot(
        film: _film,
        paper: _paper,
        exposureEv: _exposureEv,
        magenta: _magenta,
        yellow: _yellow,
        shiftScale: _shiftScale,
        preflash: _preflash,
        grain: _grain,
        halation: _halation,
        glare: _glare,
        strength: _strength,
        layer2: _layer2,
      );

  void _restore(_EditSnapshot snapshot) {
    _film = snapshot.film;
    _paper = snapshot.paper;
    _exposureEv = snapshot.exposureEv;
    _magenta = snapshot.magenta;
    _yellow = snapshot.yellow;
    _shiftScale = snapshot.shiftScale;
    _preflash = snapshot.preflash;
    _grain = snapshot.grain;
    _halation = snapshot.halation;
    _glare = snapshot.glare;
    _strength = snapshot.strength;
    _layer2 = snapshot.layer2;
  }

  /// Call once at the start of a gesture, before the first `setState`.
  void _pushUndo() {
    _history.add(_snapshot());
    if (_history.length > _maxUndo) _history.removeAt(0);
    setState(() {});
  }

  Future<void> _undo() async {
    if (_history.isEmpty || _busy || !_hasSession) return;
    final snapshot = _history.removeLast();
    setState(() {
      _restore(snapshot);
      _busy = true;
      _quality = PreviewQuality.fast;
    });
    try {
      await _worker!.setParams({
        ..._liveDelta(),
        ..._slowDelta(),
        'film_stock': _film,
        'print_stock': _paper,
      });
      final frame = await _worker!.reprint(tier: 'live');
      await _showFrame(frame, fast: true, wallMs: null);
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _requestLive() {
    if (!_hasSession) return;
    if (_quality == PreviewQuality.fine) return;
    _liveDirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 90), _pumpLive);
  }

  Future<void> _pumpLive() async {
    if (_liveBusy || !_hasSession || _busy) return;
    _liveBusy = true;
    try {
      while (_liveDirty && mounted) {
        _liveDirty = false;
        final stopwatch = Stopwatch()..start();
        await _worker!.setParams(_liveDelta());
        final frame = await _worker!.reprint(tier: 'live');
        stopwatch.stop();
        if (!mounted) return;
        await _showFrame(frame, fast: true, wallMs: stopwatch.elapsedMilliseconds);
      }
    } catch (error) {
      _setError(error);
    } finally {
      _liveBusy = false;
    }
  }

  /// The "fine" mode's only trigger: release. A preview-tier reprint is far
  /// too slow to run while a thumb is moving.
  Future<void> _renderFine() async {
    if (!_hasSession || _busy) return;
    setState(() => _busy = true);
    try {
      await _worker!.setParams({..._liveDelta(), ..._slowDelta()});
      final stopwatch = Stopwatch()..start();
      final frame = await _worker!.reprint(tier: 'preview');
      stopwatch.stop();
      await _showFrame(frame, fast: false, wallMs: stopwatch.elapsedMilliseconds);
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applySlow() async {
    if (!_hasSession || _busy) return;
    setState(() => _busy = true);
    try {
      await _worker!.setParams({..._liveDelta(), ..._slowDelta()});
      final stopwatch = Stopwatch()..start();
      final frame = await _worker!.reprint(tier: 'live');
      stopwatch.stop();
      await _showFrame(frame, fast: true, wallMs: stopwatch.elapsedMilliseconds);
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeStock(String key, String id) async {
    if (_busy) return;
    final hadSession = _hasSession;
    if (hadSession) _pushUndo();
    setState(() {
      if (key == 'film_stock') {
        _film = id;
      } else {
        _paper = id;
      }
      // Before a RAW is open there is nothing to re-render: the choice is
      // remembered and sent with the `open` call instead.
      if (hadSession) _busy = true;
    });
    if (!hadSession) return;
    try {
      await _worker!.setParams({
        ..._liveDelta(),
        ..._slowDelta(),
        'film_stock': _film,
        'print_stock': _paper,
      });
      final stopwatch = Stopwatch()..start();
      final frame = await _worker!.reprint(tier: 'live');
      stopwatch.stop();
      await _showFrame(frame, fast: true, wallMs: stopwatch.elapsedMilliseconds);
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleSource() async {
    if (!_hasSession || _busy) return;
    if (_showingSource) {
      setState(() => _showingSource = false);
      return;
    }
    if (_sourceImage != null) {
      setState(() => _showingSource = true);
      return;
    }
    setState(() => _busy = true);
    try {
      final frame = await _worker!.exportSource(tier: 'live');
      final image = await _imageFromFrame(frame);
      if (!mounted) {
        image.dispose();
        return;
      }
      final old = _sourceImage;
      setState(() {
        _sourceImage = image;
        _showingSource = true;
      });
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Above this, a full-resolution frame (RGBA8 in memory, then decoded again
  /// by the JPEG encoder) risks an OOM kill on 8 GB phones. The sheet steers
  /// the user to a long-edge cap instead of guessing.
  static const double _maxFullExportMp = 32;

  Future<void> _export() async {
    if (!_hasSession || _busy || _exporting) return;
    final options = await showModalBottomSheet<_ExportOptions>(
      context: context,
      backgroundColor: _kSurface,
      showDragHandle: true,
      builder: (_) => _ExportSheet(
        film: _stockName(_film),
        paper: _stockName(_paper),
      ),
    );
    if (options == null || !mounted) return;

    final stage = ValueNotifier<String>('准备渲染');
    var dialogOpen = true;
    setState(() {
      _busy = true;
      _exporting = true;
    });
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportProgressDialog(stage: stage),
    ).then((_) => dialogOpen = false));

    try {
      await _worker!.setParams({
        ..._liveDelta(),
        ..._slowDelta(),
        'film_stock': _film,
        'print_stock': _paper,
      });
      stage.value = '渲染全尺寸…';
      final frame = await _worker!.render(tier: 'full');
      final megapixels = frame.width * frame.height / 1000000;
      // Blending needs the source frame as well, so the ceiling halves.
      final ceiling = _strength < 0.999 ? _maxFullExportMp / 2 : _maxFullExportMp;
      if (options.longEdge == null && megapixels > ceiling) {
        throw ExportFailure(
          '这张 ${megapixels.toStringAsFixed(0)} MP，全尺寸导出内存吃紧'
          '${_strength < 0.999 ? '（模拟强度未满 100%，需要同时持有原图）' : ''}。'
          '把长边设成 4000 或 2048 再导。',
        );
      }
      RenderFrame? sourceFrame;
      if (_strength < 0.999) {
        stage.value = '取原图用于混合…';
        sourceFrame = await _worker!.exportSource(tier: 'full');
      }
      stage.value = '编码 JPEG…';
      final input = (_openInfo['input'] as Map?)?.cast<String, dynamic>() ?? const {};
      final photo = await encodeAndSave(
        pixels: frame.pixels,
        width: frame.width,
        height: frame.height,
        fileName: exportFileName(_film),
        longEdge: options.longEdge,
        quality: options.quality,
        matrix: _layer2.isNeutral ? null : _layer2.matrix,
        sourcePath: _path,
        make: input['make'] as String?,
        model: input['model'] as String?,
        strength: _strength,
        sourcePixels: sourceFrame?.pixels,
        sourceWidth: sourceFrame?.width,
        sourceHeight: sourceFrame?.height,
      );
      if (!mounted) return;
      if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
      await _showExportResult(photo);
    } catch (error) {
      if (!mounted) return;
      if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
      _setError(error);
    } finally {
      stage.dispose();
      if (mounted) {
        setState(() {
          _busy = false;
          _exporting = false;
        });
      }
    }
  }

  Future<void> _showExportResult(ExportedPhoto photo) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _kSurface,
        title: const Text('已导出'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${photo.width} × ${photo.height} · JPEG · ${photo.sizeLabel}'),
            const SizedBox(height: 4),
            Text(
              photo.exifTags > 0
                  ? '已写入 ${photo.exifTags} 项拍摄参数'
                  : '源文件没有可读取的拍摄参数',
              style: const TextStyle(fontSize: 12, color: _kTextDim),
            ),
            const SizedBox(height: 10),
            Text(
              photo.inGallery ? '已存入相册 Spektrafilm' : '相册写入失败，文件保存在应用目录',
              style: const TextStyle(fontSize: 12, color: _kTextDim),
            ),
            const SizedBox(height: 4),
            SelectableText(
              photo.path,
              style: const TextStyle(fontSize: 11, color: _kTextDim),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  Future<void> _showFrame(
    RenderFrame frame, {
    required bool fast,
    required int? wallMs,
  }) async {
    final image = await _imageFromFrame(frame);
    if (!mounted) {
      image.dispose();
      return;
    }
    final old = _image;
    setState(() {
      _image = image;
      _imageWidth = frame.width;
      _imageHeight = frame.height;
      _showingSource = false;
      _framePixels = frame.pixels;
      _histogram = Histogram.fromRgba8(frame.pixels, matrix: _layer2.matrix);
      if (fast) {
        _liveFrames++;
        _lastLiveMs = wallMs ?? frame.renderMs?.round() ?? 0;
        _lastReprint = frame.reprint;
      } else {
        _lastLiveMs = wallMs ?? frame.renderMs?.round() ?? 0;
        _lastReprint = frame.reprint;
      }
    });
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  static Future<ui.Image> _imageFromFrame(RenderFrame frame) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(frame.pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        final next = await codec.getNextFrame();
        return next.image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  }

  Future<void> _showDiagnostics() async {
    try {
      final worker = _worker;
      Map<String, dynamic> capabilities = const {};
      String? capabilitiesError;
      if (worker != null) {
        try {
          capabilities = await worker.capabilities();
        } catch (error) {
          capabilitiesError = error.toString();
        }
      }
      final build = await worker?.buildInfo() ?? '—';
      final report = const JsonEncoder.withIndent('  ').convert({
        'build': build,
        'resources': _resourcesDir,
        'session': {
          'path': _path,
          'open': _sessionOpen,
          'frames': _liveFrames,
          'last_ms': _lastLiveMs,
          'reprint': _lastReprint,
          'open_reply': _openInfo,
        },
        'capabilities': capabilities,
        'capabilities_error': ?capabilitiesError,
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('引擎诊断'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                report,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.45),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      _setError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(theme),
            Expanded(child: _buildPreview(theme)),
            if (_error != null) _buildErrorBar(theme),
            _buildPanel(theme),
          ],
        ),
      ),
    );
  }

  /// Brand lockup, then the three things you actually do to a picture.
  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 8),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'HALFSTOP',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 8,
                  letterSpacing: 3.4,
                  color: _kAccent.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: 1),
              Text('半档', style: theme.textTheme.titleLarge),
            ],
          ),
          const Spacer(),
          _headerAction(
            icon: Icons.undo_rounded,
            tooltip: '撤销',
            enabled: _history.isNotEmpty && !_busy && _hasSession,
            onTap: _undo,
          ),
          _headerAction(
            icon: Icons.add_photo_alternate_outlined,
            tooltip: '导入',
            enabled: !_busy,
            onTap: _import,
          ),
          _headerAction(
            icon: Icons.download_rounded,
            tooltip: '导出',
            enabled: _hasSession && !_busy,
            onTap: _export,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            color: _kSurfaceHigh,
            icon: const Icon(Icons.more_vert_rounded, size: 20, color: _kTextDim),
            onSelected: (value) {
              if (value == 'diagnostics') _showDiagnostics();
              if (value == 'close') _closeImage();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'diagnostics',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.memory_outlined, size: 20),
                  title: Text('引擎诊断'),
                ),
              ),
              PopupMenuItem(
                value: 'close',
                enabled: _image != null && !_busy,
                child: const ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.close_rounded, size: 20),
                  title: Text('关闭照片'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _headerAction({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: enabled ? onTap : null,
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? _kText : _kTextDim.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    final image = _showingSource ? _sourceImage : _image;
    return Container(
      width: double.infinity,
      color: _kBackground,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF050403),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _kLine),
                ),
                clipBehavior: Clip.antiAlias,
                child: CustomPaint(
                  painter: _PreviewPainter(
                    image: image,
                    colorFilter: _layer2.colorFilter,
                    sourceImage: _sourceImage,
                    strength: _strength,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            )
          else
            _buildEmptyState(theme),
          if (_image != null)
            Positioned(
              left: 26,
              bottom: 24,
              child: _badge(
                theme,
                '${_stockName(_film)} · $_imageWidth×$_imageHeight · $_lastLiveMs ms',
              ),
            ),
          if (_image != null && _strength < 0.999)
            Positioned(
              left: 26,
              bottom: 62,
              child: _badge(theme, '强度 ${(_strength * 100).round()}%'),
            ),
          if (_image != null && _showHistogram)
            Positioned(
              right: 26,
              bottom: 24,
              child: HistogramView(data: _histogram),
            ),
          if (_image != null)
            Positioned(
              right: 26,
              top: 12,
              child: _iconPill(
                icon: Icons.compare_arrows_rounded,
                label: _showingSource ? '看成片' : '看原图',
                onTap: _busy ? null : _toggleSource,
              ),
            ),
          if (_busy || _booting)
            Container(
              color: const Color(0xFF0A0908).withValues(alpha: 0.72),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: _kAccent,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _booting
                          ? '加载引擎与资源…'
                          : (_busyLabel ??
                              (_quality == PreviewQuality.fine ? '精细渲染中…' : '渲染中…')),
                      style: theme.textTheme.labelMedium,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 86,
              height: 58,
              child: CustomPaint(painter: _FrameMarkPainter()),
            ),
            const SizedBox(height: 18),
            Text(
              '半档',
              style: theme.textTheme.titleLarge?.copyWith(fontSize: 34, letterSpacing: 8),
            ),
            const SizedBox(height: 12),
            Container(width: 26, height: 1, color: _kLineStrong),
            const SizedBox(height: 14),
            Text(
              '物理胶片模拟 · 光谱计算全在本机',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: _entryCard(
                    theme,
                    icon: Icons.photo_library_outlined,
                    title: '从相册选择',
                    caption: 'JPEG / PNG / WebP',
                    enabled: !_busy && !_booting,
                    onTap: _importPhoto,
                    filled: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _entryCard(
                    theme,
                    icon: Icons.raw_on_outlined,
                    title: 'RAW 文件',
                    caption: 'ARW / NEF / DNG…',
                    enabled: !_busy && !_booting,
                    onTap: _importRaw,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '两条路都走同一套胶片模型：相册图片由本机转成线性 ProPhoto，RAW 交给 LibRaw。',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10,
                height: 1.5,
                color: _kTextDim.withValues(alpha: 0.8),
              ),
            ),
            if (_cached.isNotEmpty) ...[
              const SizedBox(height: 26),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(width: 14, height: 1, color: _kLineStrong),
                  const SizedBox(width: 10),
                  Text(
                    '最近导入',
                    style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.6),
                  ),
                  const SizedBox(width: 10),
                  Container(width: 14, height: 1, color: _kLineStrong),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final raw in _cached.take(6))
                    GestureDetector(
                      onLongPress: _busy ? null : () => _deleteCached(raw),
                      child: ActionChip(
                        avatar: Icon(
                          raw.isPhoto ? Icons.image_outlined : Icons.raw_on_outlined,
                          size: 15,
                          color: _kTextDim,
                        ),
                        label: Text(
                          '${raw.name} · ${raw.sizeLabel}',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        backgroundColor: _kSurfaceHigh,
                        side: const BorderSide(color: _kLineStrong),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                        onPressed: _busy || _booting ? null : () => _openCached(raw),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '长按可删除缓存副本',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 9.5,
                  color: _kTextDim.withValues(alpha: 0.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _entryCard(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String caption,
    required bool enabled,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        decoration: BoxDecoration(
          color: filled ? _kAccent.withValues(alpha: 0.12) : _kSurfaceHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: filled ? _kAccent.withValues(alpha: 0.45) : _kLineStrong,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 22,
              color: enabled ? (filled ? _kAccent : _kText) : _kTextDim,
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(fontSize: 12.5),
            ),
            const SizedBox(height: 3),
            Text(
              caption,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 9,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBar(ThemeData theme) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3A1618),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: Color(0xFFE9A0A0)),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFFE9A0A0),
                height: 1.4,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _error = null),
            icon: const Icon(Icons.close, size: 18, color: Color(0xFFE9A0A0)),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(ThemeData theme) {
    final canPick = !_busy;
    final canRender = _hasSession && !_busy;
    return Container(
      decoration: const BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: _kLine)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 360,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 9, bottom: 3),
                child: Container(
                  width: 34,
                  height: 3,
                  decoration: BoxDecoration(
                    color: _kLineStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                child: Row(
                  children: [
                    Expanded(child: _buildStockField(theme, film: true, enabled: canPick)),
                    const SizedBox(width: 8),
                    Expanded(child: _buildStockField(theme, film: false, enabled: canPick)),
                  ],
                ),
              ),
              _buildTabs(theme, canRender),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                  children: switch (_panelLayer) {
                    _PanelLayer.print => _printSliders(theme, canRender),
                    _PanelLayer.color => _colorSliders(theme, canRender),
                    _PanelLayer.frame => _frameControls(theme, canRender),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Three tabs, a histogram toggle and one reset that always means "reset
  /// what you are looking at".
  Widget _buildTabs(ThemeData theme, bool canRender) {
    Widget tab(_PanelLayer layer, String label) {
      final selected = _panelLayer == layer;
      return GestureDetector(
        onTap: () => setState(() => _panelLayer = layer),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? _kAccent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? _kAccent.withValues(alpha: 0.55) : _kLineStrong,
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected ? _kAccent : _kTextDim,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: 1,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 4),
      child: Row(
        children: [
          tab(_PanelLayer.print, '印片'),
          tab(_PanelLayer.color, '调色'),
          tab(_PanelLayer.frame, '画幅'),
          const Spacer(),
          IconButton(
            tooltip: _showHistogram ? '隐藏直方图' : '显示直方图',
            onPressed: () => setState(() => _showHistogram = !_showHistogram),
            icon: Icon(
              _showHistogram ? Icons.bar_chart_rounded : Icons.bar_chart_outlined,
              size: 18,
            ),
            visualDensity: VisualDensity.compact,
            color: _kTextDim,
          ),
          TextButton(
            onPressed: canRender
                ? () {
                    switch (_panelLayer) {
                      case _PanelLayer.print:
                        _resetLive();
                      case _PanelLayer.color:
                        _resetColor();
                      case _PanelLayer.frame:
                        _resetFrame();
                    }
                  }
                : null,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: _kTextDim,
              minimumSize: const Size(44, 32),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              textStyle: theme.textTheme.labelMedium,
            ),
            child: const Text('重置'),
          ),
        ],
      ),
    );
  }

  /// The frame page: gate, rebate, date back. Every control here re-develops
  /// the negative, which is why they commit on change instead of on drag.
  List<Widget> _frameControls(ThemeData theme, bool canRender) {
    final enabled = _hasSession && !_busy;
    final format = _format;
    final crop = _cropBox;

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
        child: Text(
          '画幅决定片门尺寸，也决定颗粒相对于画面的粗细；选画幅会按片门比例居中裁剪。',
          style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim, height: 1.4),
        ),
      ),
      SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          children: [
            _formatChip(theme, null, '原图', enabled),
            for (final option in kFilmFormats)
              _formatChip(theme, option, option.label, enabled),
          ],
        ),
      ),
      if (format != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Text(
            '${format.note} · '
            '裁剪保留 ${(crop.width * 100).round()}% × ${(crop.height * 100).round()}%',
            style: theme.textTheme.labelSmall?.copyWith(color: _kTextDim),
          ),
        ),
      const SizedBox(height: 6),
      _switchRow(
        theme,
        '片边与齿孔',
        subtitle: format == null ? '先选画幅' : '在画面外铺出胶片边缘',
        value: _overscanOn,
        enabled: enabled && format != null,
        onChanged: (value) {
          setState(() => _overscanOn = value);
          _applyFrame(label: value ? '铺片边…' : '收片边…');
        },
      ),
      if (format != null && _overscanOn) ...[
        _choiceRow(
          theme,
          '齿孔',
          const ['white', 'black'],
          const ['白（扫描）', '黑（暗房）'],
          _holes,
          enabled,
          (value) {
            setState(() => _holes = value);
            _applyFrame(label: '换齿孔…');
          },
        ),
        _choiceRow(
          theme,
          '片基外',
          const ['none', 'black', 'open'],
          const ['无', '黑场', '透光'],
          _carrier,
          enabled,
          (value) {
            setState(() => _carrier = value);
            _applyFrame(label: '换片基…');
          },
        ),
        _sliderRow(
          theme,
          label: '边雾',
          valueLabel: _edgeFog.toStringAsFixed(1),
          value: _edgeFog,
          min: 0,
          max: 4,
          enabled: enabled,
          onChanged: (value) => setState(() => _edgeFog = value),
          onChangeEnd: (_) => _applyFrame(label: '改边雾…'),
        ),
        _sliderRow(
          theme,
          label: '漏光',
          valueLabel: _leaks.toStringAsFixed(1),
          value: _leaks,
          min: 0,
          max: 4,
          enabled: enabled,
          onChanged: (value) => setState(() => _leaks = value),
          onChangeEnd: (_) => _applyFrame(label: '加漏光…'),
        ),
      ],
      const Divider(height: 26, color: Color(0xFF23262E)),
      _switchRow(
        theme,
        '日期后背',
        subtitle: '把日期烧进画面',
        value: _dateOn,
        enabled: enabled,
        onChanged: (value) {
          setState(() => _dateOn = value);
          _applyFrame(label: value ? '打日期…' : '去掉日期…');
        },
      ),
      if (_dateOn) ...[
        _tapRow(
          theme,
          '日期',
          _dateText.isEmpty ? defaultDateText() : _dateText,
          enabled,
          _editDateText,
        ),
        _choiceRow(
          theme,
          '字体',
          const ['lcd', 'dots', 'data'],
          const ['液晶', '点阵', '数据'],
          _dateStyle,
          enabled,
          (value) {
            setState(() => _dateStyle = value);
            _applyFrame(label: '换字体…');
          },
        ),
        _choiceRow(
          theme,
          '位置',
          const ['frame', 'rebate'],
          const ['画面内', '片边上'],
          _datePlacement,
          enabled && format != null && _overscanOn,
          (value) {
            setState(() => _datePlacement = value);
            _applyFrame(label: '挪日期…');
          },
        ),
      ],
    ];
  }

  Widget _formatChip(ThemeData theme, FilmFormat? format, String label, bool enabled) {
    final selected = _format?.id == format?.id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? () => _pickFormat(format) : null,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: selected ? _kAccent.withValues(alpha: 0.18) : _kSurfaceHigh,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? _kAccent : const Color(0xFF2A2E37),
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: selected ? _kAccent : theme.colorScheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _switchRow(
    ThemeData theme,
    String label, {
    required String subtitle,
    required bool value,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(color: _kTextDim),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            // Explicit colours in both states: the default off-state thumb
            // takes the seed colour and reads as "on" at a glance.
            thumbColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? const Color(0xFF20160A)
                  : const Color(0xFF8A909B),
            ),
            trackColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? _kAccent
                  : const Color(0xFF2A2E37),
            ),
            trackOutlineColor: WidgetStatePropertyAll(
              value ? Colors.transparent : const Color(0xFF3A3F49),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choiceRow(
    ThemeData theme,
    String label,
    List<String> values,
    List<String> labels,
    String selected,
    bool enabled,
    ValueChanged<String> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              children: [
                for (var i = 0; i < values.length; i++)
                  ChoiceChip(
                    label: Text(labels[i], style: const TextStyle(fontSize: 11)),
                    selected: selected == values[i],
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    selectedColor: _kAccent.withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                      color: selected == values[i] ? _kAccent : theme.colorScheme.onSurface,
                    ),
                    onSelected: enabled ? (_) => onChanged(values[i]) : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tapRow(
    ThemeData theme,
    String label,
    String value,
    bool enabled,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: [
            SizedBox(
              width: 58,
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim),
              ),
            ),
            Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
            const Icon(Icons.edit_outlined, size: 16, color: _kTextDim),
          ],
        ),
      ),
    );
  }

  void _resetFrame() {
    setState(() {
      _format = null;
      _overscanOn = false;
      _dateOn = false;
      _datePlacement = 'frame';
    });
    _applyFrame(label: '恢复原比例…');
  }

  /// Layer 1 controls: every one of these ends in an engine reprint.
  Widget _qualityPill(ThemeData theme, PreviewQuality quality, String label) {
    final selected = _quality == quality;
    return GestureDetector(
      onTap: _busy
          ? null
          : () {
              if (selected) return;
              setState(() => _quality = quality);
              if (quality == PreviewQuality.fine) {
                _renderFine();
              } else if (_hasSession) {
                _requestLive();
              }
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _kAccent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? _kAccent.withValues(alpha: 0.55) : _kLineStrong,
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 10.5,
            letterSpacing: 0.4,
            color: selected ? _kAccent : _kTextDim,
          ),
        ),
      ),
    );
  }

  List<Widget> _printSliders(ThemeData theme, bool canRender) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
        child: Row(
          children: [
            _qualityPill(theme, PreviewQuality.fast, '实时 · 1600'),
            const SizedBox(width: 6),
            _qualityPill(theme, PreviewQuality.fine, '精细 · 3400'),
            const Spacer(),
          ],
        ),
      ),
      _sliderRow(
        theme,
        label: '模拟强度',
        valueLabel: '${(_strength * 100).round()}%',
        value: _strength,
        min: 0,
        max: 1,
        enabled: canRender,
        onChangeStart: (_) {
          _pushUndo();
          unawaited(_ensureSource());
        },
        // Pure composite: no engine call, so this drag is free.
        onChanged: (value) => setState(() => _strength = value),
      ),
      _sliderRow(
        theme,
        label: '曝光',
        valueLabel: '${_exposureEv >= 0 ? '+' : ''}${_exposureEv.toStringAsFixed(2)} EV',
        value: _exposureEv,
        min: -4,
        max: 4,
        enabled: canRender,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) {
          setState(() => _exposureEv = value);
          _requestLive();
        },
        onChangeEnd: (_) {
          if (_quality == PreviewQuality.fine) _renderFine();
        },
      ),
      _sliderRow(
        theme,
        label: '品红 M',
        valueLabel: _magenta.toStringAsFixed(2),
        value: _magenta,
        min: -1,
        max: 1,
        enabled: canRender,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) {
          setState(() => _magenta = value);
          _requestLive();
        },
        onChangeEnd: (_) {
          if (_quality == PreviewQuality.fine) _renderFine();
        },
      ),
      _sliderRow(
        theme,
        label: '黄 Y',
        valueLabel: _yellow.toStringAsFixed(2),
        value: _yellow,
        min: -1,
        max: 1,
        enabled: canRender,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) {
          setState(() => _yellow = value);
          _requestLive();
        },
        onChangeEnd: (_) {
          if (_quality == PreviewQuality.fine) _renderFine();
        },
      ),
      _sliderRow(
        theme,
        label: '色偏强度',
        valueLabel: '×${_shiftScale.toStringAsFixed(0)}',
        value: _shiftScale,
        min: 1,
        max: 60,
        enabled: canRender,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) {
          setState(() => _shiftScale = value);
          _requestLive();
        },
        onChangeEnd: (_) {
          if (_quality == PreviewQuality.fine) _renderFine();
        },
      ),
      // Pre-flash is intentionally not a slider. The engine's
      // `preflash_exposure` is a fraction of the film base density applied as
      // extra light: 1.0 crushes the print to black, and the only visible
      // effect in a usable range is a slight overall darkening — which the
      // exposure slider already does better. It stays wired (default 0) for a
      // future expert mode; see docs/adr or AGENTS.md.
      const Divider(height: 20, color: Color(0xFF23262E)),
      _sliderRow(
        theme,
        label: '颗粒',
        valueLabel: _grain.toStringAsFixed(2),
        value: _grain,
        min: 0,
        max: 2,
        enabled: canRender,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) => setState(() => _grain = value),
        onChangeEnd: (_) => _applySlow(),
      ),
      _sliderRow(
        theme,
        label: '光晕',
        valueLabel: _halation.toStringAsFixed(2),
        value: _halation,
        min: 0,
        max: 4,
        enabled: canRender,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) => setState(() => _halation = value),
        onChangeEnd: (_) => _applySlow(),
      ),
      _sliderRow(
        theme,
        label: '眩光',
        valueLabel: _glare.toStringAsFixed(1),
        value: _glare,
        min: 0,
        max: 30,
        enabled: canRender,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) => setState(() => _glare = value),
        onChangeEnd: (_) => _applySlow(),
      ),
    ];
  }

  /// Layer 2 controls: a GPU colour matrix. No engine call, no `_busy`, so the
  /// preview keeps up with the thumb.
  List<Widget> _colorSliders(ThemeData theme, bool canRender) {
    final enabled = _hasSession && !_busy;
    return [
      _sliderRow(
        theme,
        label: '亮度',
        valueLabel: '${_layer2.brightness >= 0 ? '+' : ''}${_layer2.brightness.toStringAsFixed(2)} EV',
        value: _layer2.brightness,
        min: -2,
        max: 2,
        enabled: enabled,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) => _setLayer2(_layer2.copyWith(brightness: value)),
      ),
      _sliderRow(
        theme,
        label: '对比',
        valueLabel: _layer2.contrast.toStringAsFixed(2),
        value: _layer2.contrast,
        min: -1,
        max: 1,
        enabled: enabled,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) => _setLayer2(_layer2.copyWith(contrast: value)),
      ),
      _sliderRow(
        theme,
        label: '饱和',
        valueLabel: _layer2.saturation.toStringAsFixed(2),
        value: _layer2.saturation,
        min: -1,
        max: 1,
        enabled: enabled,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) => _setLayer2(_layer2.copyWith(saturation: value)),
      ),
      _sliderRow(
        theme,
        label: '色温',
        valueLabel: _layer2.temperature.toStringAsFixed(2),
        value: _layer2.temperature,
        min: -1,
        max: 1,
        enabled: enabled,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) => _setLayer2(_layer2.copyWith(temperature: value)),
      ),
      _sliderRow(
        theme,
        label: '色调',
        valueLabel: _layer2.tint.toStringAsFixed(2),
        value: _layer2.tint,
        min: -1,
        max: 1,
        enabled: enabled,
        onChangeStart: (_) => _pushUndo(),
        onChanged: (value) => _setLayer2(_layer2.copyWith(tint: value)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        child: Text(
          '调色层作用在渲染结果上，拖动不触发引擎重算，导出时按同一套算式烘进 JPEG。',
          style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim, height: 1.4),
        ),
      ),
    ];
  }

  Widget _buildStockField(ThemeData theme, {required bool film, required bool enabled}) {
    final value = film ? _film : _paper;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: enabled && _stocks.isNotEmpty ? () => _showStockSheet(film: film) : null,
      child: Container(
        height: 50,
        padding: const EdgeInsets.fromLTRB(12, 5, 8, 5),
        decoration: BoxDecoration(
          color: _kSurfaceHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kLineStrong),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    film ? '胶片' : '相纸',
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 9.5),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _stocks.isEmpty ? '未找到 profile' : _stockName(value),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _kText,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.unfold_more_rounded, size: 15, color: _kTextDim),
          ],
        ),
      ),
    );
  }

  /// One sheet for both fields, grouped by what the stock actually is. The
  /// categories come from the profiles' own `stage`/`support`, so a bundle
  /// update reorders this list without a code change.
  Future<void> _showStockSheet({required bool film}) async {
    final grouped = groupStocks(
      _stocks.where((stock) => film ? stock.isFilm : stock.isPrintStock),
    );
    final current = film ? _film : _paper;

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _kSurface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.92,
        builder: (context, controller) {
          final theme = Theme.of(context);
          return ListView(
            controller: controller,
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  film ? '选择胶片' : '选择相纸 / 印片胶片',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              for (final entry in grouped.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        entry.key.label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: _kAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.key.hint,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: _kTextDim,
                            fontSize: 10,
                          ),
                        ),
                      ),
                      Text(
                        '${entry.value.length}',
                        style: theme.textTheme.labelSmall?.copyWith(color: _kTextDim),
                      ),
                    ],
                  ),
                ),
                for (final stock in entry.value)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    title: Text(stock.name, style: theme.textTheme.bodyMedium),
                    trailing: stock.id == current
                        ? const Icon(Icons.check_rounded, size: 18, color: _kAccent)
                        : null,
                    onTap: () => Navigator.of(context).pop(stock.id),
                  ),
              ],
            ],
          );
        },
      ),
    );

    if (picked != null && picked != current) {
      await _changeStock(film ? 'film_stock' : 'print_stock', picked);
    }
  }

  Widget _sliderRow(
    ThemeData theme, {
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required bool enabled,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeStart,
    ValueChanged<double>? onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 14, 2),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: enabled ? _kTextDim : _kTextDim.withValues(alpha: 0.4),
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                activeTrackColor: _kAccent,
                inactiveTrackColor: _kLineStrong,
                disabledActiveTrackColor: _kLine,
                disabledInactiveTrackColor: _kLine,
                thumbColor: _kAccent,
                disabledThumbColor: _kLineStrong,
                overlayColor: _kAccent.withValues(alpha: 0.14),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: enabled ? onChanged : null,
                onChangeStart: enabled ? onChangeStart : null,
                onChangeEnd: enabled ? onChangeEnd : null,
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              valueLabel,
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFeatures: const [ui.FontFeature.tabularFigures()],
                letterSpacing: 0,
                fontSize: 11,
                color: enabled ? _kText : _kTextDim.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Layer 2 never touches the engine: the preview repaints from the frame we
  /// already hold with a new colour matrix, and the histogram is re-binned from
  /// the same bytes. This is why these sliders have no `_requestLive`.
  void _setLayer2(Layer2Params next) {
    final pixels = _framePixels;
    setState(() {
      _layer2 = next;
      if (pixels != null) {
        _histogram = Histogram.fromRgba8(pixels, matrix: next.matrix);
      }
    });
  }

  void _resetColor() {
    _pushUndo();
    _setLayer2(Layer2Params.neutral);
  }

  void _resetLive() {
    _pushUndo();
    setState(() {
      _strength = 1;
      _exposureEv = 0;
      _magenta = 0;
      _yellow = 0;
      _shiftScale = 1;
      _preflash = 0;
    });
    _requestLive();
  }

  Widget _badge(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF050403).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10,
          letterSpacing: 0.2,
          color: const Color(0xFFCFC7BA),
          fontFeatures: const [ui.FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _iconPill({required IconData icon, required String label, VoidCallback? onTap}) {
    return Material(
      color: const Color(0xFF050403).withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: const Color(0xFFCFC7BA)),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(fontSize: 10.5, color: Color(0xFFCFC7BA)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which group of sliders the panel is showing.
///
/// `print` is the enlarger/film side and costs an engine reprint; `color` is
/// Layer 2 and costs nothing but a repaint.
enum _PanelLayer { print, color, frame }

/// A 135 frame, drawn by hand: perforations and a gate. Used as the mark on
/// the landing screen so the wordmark is not repeated from the header.
class _FrameMarkPainter extends CustomPainter {
  const _FrameMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const amber = Color(0xFFE3A35C);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = amber.withValues(alpha: 0.55);
    final hole = Paint()..color = amber.withValues(alpha: 0.3);

    final gate = Rect.fromLTWH(0, 13, size.width, size.height - 26);
    canvas.drawRRect(
      RRect.fromRectAndRadius(gate, const Radius.circular(3)),
      line,
    );

    const holeW = 5.0;
    const holeH = 4.0;
    const gap = 3.6;
    for (final y in const [4.5, 49.5]) {
      var x = 7.0;
      while (x + holeW <= size.width - 6) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, holeW, holeH),
            const Radius.circular(1),
          ),
          hole,
        );
        x += holeW + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Draws the frame with the Layer 2 colour matrix, keeping the fit the old
/// `RawImage` had. `colorFilter` is a GPU operation, so dragging a Layer 2
/// slider never waits for the engine.
class _PreviewPainter extends CustomPainter {
  _PreviewPainter({
    required this.image,
    required this.colorFilter,
    this.sourceImage,
    this.strength = 1,
  });

  final ui.Image image;
  final ui.ColorFilter colorFilter;

  /// The rendered frame is composited over this at [strength] opacity.
  final ui.Image? sourceImage;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final source = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, source, size);
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );

    final before = sourceImage;
    if (before != null && strength < 0.999) {
      // Source first, unfiltered and opaque; then the film on top at `strength`.
      // That is a straight linear crossfade in display space, which is what a
      // "how much film" control should feel like.
      final beforeSize = Size(before.width.toDouble(), before.height.toDouble());
      final beforeFitted = applyBoxFit(BoxFit.contain, beforeSize, size);
      canvas.drawImageRect(
        before,
        Offset.zero & beforeSize,
        Alignment.center.inscribe(beforeFitted.destination, Offset.zero & size),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }

    canvas.drawImageRect(
      image,
      Offset.zero & source,
      destination,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = colorFilter
        ..color = Color.fromRGBO(255, 255, 255, before == null ? 1 : strength),
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.colorFilter != colorFilter ||
      oldDelegate.sourceImage != sourceImage ||
      oldDelegate.strength != strength;
}

/// One undo step: every user-editable value at the moment a gesture started.
class _EditSnapshot {
  const _EditSnapshot({
    required this.film,
    required this.paper,
    required this.exposureEv,
    required this.magenta,
    required this.yellow,
    required this.shiftScale,
    required this.preflash,
    required this.grain,
    required this.halation,
    required this.glare,
    required this.strength,
    required this.layer2,
  });

  final String film;
  final String paper;
  final double exposureEv;
  final double magenta;
  final double yellow;
  final double shiftScale;
  final double preflash;
  final double grain;
  final double halation;
  final double glare;
  final double strength;
  final Layer2Params layer2;
}

class _ExportOptions {
  const _ExportOptions({required this.longEdge, required this.quality});

  /// null means "whatever the RAW decodes to".
  final int? longEdge;
  final int quality;
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.film, required this.paper});

  final String film;
  final String paper;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  int? _longEdge = 4000;
  double _quality = 92;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('导出 JPEG', style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              '${widget.film} · ${widget.paper}',
              style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim),
            ),
            const SizedBox(height: 16),
            Text('尺寸', style: theme.textTheme.labelMedium?.copyWith(color: _kTextDim)),
            const SizedBox(height: 8),
            SegmentedButton<int?>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 2048, label: Text('长边 2048')),
                ButtonSegment(value: 4000, label: Text('长边 4000')),
                ButtonSegment(value: null, label: Text('原尺寸')),
              ],
              selected: {_longEdge},
              onSelectionChanged: (selection) =>
                  setState(() => _longEdge = selection.first),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('质量', style: theme.textTheme.labelMedium?.copyWith(color: _kTextDim)),
                Expanded(
                  child: Slider(
                    value: _quality,
                    min: 60,
                    max: 100,
                    divisions: 8,
                    label: _quality.round().toString(),
                    activeColor: _kAccent,
                    onChanged: (value) => setState(() => _quality = value),
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Text(
                    _quality.round().toString(),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            Text(
              _longEdge == null
                  ? '原尺寸按 RAW 解出的全分辨率导出，24 MP 以上很吃内存。'
                  : '长边 $_longEdge，按比例缩放后编码。',
              style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(
                  _ExportOptions(longEdge: _longEdge, quality: _quality.round()),
                ),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('导出'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportProgressDialog extends StatelessWidget {
  const _ExportProgressDialog({required this.stage});

  final ValueNotifier<String> stage;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kSurface,
      content: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: stage,
              builder: (context, value, _) => Text(value),
            ),
          ),
        ],
      ),
    );
  }
}
