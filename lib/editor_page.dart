import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'engine_bridge.dart';
import 'engine_worker.dart';
import 'exporter.dart';
import 'histogram.dart';
import 'layer2.dart';
import 'photo_import.dart';
import 'stock_catalog.dart';

const Color _kBackground = Color(0xFF0B0C0F);
const Color _kSurface = Color(0xFF14161B);
const Color _kSurfaceHigh = Color(0xFF1B1E25);
const Color _kAccent = Color(0xFFE0A458);
const Color _kTextDim = Color(0xFF9AA0AA);

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
      final papers = stocks.where((stock) => stock.isPaper).toList();
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

  List<Stock> get _films => _stocks.where((stock) => stock.isFilm).toList();

  List<Stock> get _papers => _stocks.where((stock) => stock.isPaper).toList();

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
      if (options.longEdge == null && megapixels > _maxFullExportMp) {
        throw ExportFailure(
          '这张 ${megapixels.toStringAsFixed(0)} MP，全尺寸导出内存吃紧。'
          '把长边设成 4000 或 2048 再导。',
        );
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
      appBar: AppBar(
        backgroundColor: _kBackground,
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Spektrafilm',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            Text(
              _booting
                  ? '正在启动引擎…'
                  : _path == null
                      ? '物理胶片模拟 · 相册图片或 RAW'
                      : '${_films.length} 胶片 · ${_papers.length} 相纸 · 实时 ${_previewEdge}px',
              style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '撤销',
            onPressed:
                _history.isEmpty || _busy || !_hasSession ? null : _undo,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: '导入 RAW',
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.add_photo_alternate_outlined),
          ),
          IconButton(
            tooltip: '导出 JPEG',
            onPressed: _hasSession && !_busy ? _export : null,
            icon: const Icon(Icons.download_rounded),
          ),
          IconButton(
            tooltip: '引擎诊断',
            onPressed: _booting ? null : _showDiagnostics,
            icon: const Icon(Icons.memory_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildPreview(theme)),
          if (_error != null) _buildErrorBar(theme),
          _buildPanel(theme),
        ],
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    final image = _showingSource ? _sourceImage : _image;
    return Container(
      width: double.infinity,
      color: const Color(0xFF050608),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: CustomPaint(
                painter: _PreviewPainter(
                  image: image,
                  colorFilter: _layer2.colorFilter,
                ),
                child: const SizedBox.expand(),
              ),
            )
          else
            _buildEmptyState(theme),
          if (_image != null)
            Positioned(
              left: 14,
              top: 12,
              child: _badge(
                theme,
                _showingSource
                    ? '原图 · $_imageWidth×$_imageHeight'
                    : '$_imageWidth×$_imageHeight · ${_quality == PreviewQuality.fast ? '实时' : '精细'} · '
                        '$_lastLiveMs ms${_lastReprint ? ' · reprint' : ''} · #$_liveFrames',
              ),
            ),
          if (_image != null && _showHistogram)
            Positioned(
              right: 14,
              bottom: 12,
              child: HistogramView(data: _histogram),
            ),
          if (_image != null)
            Positioned(
              right: 14,
              top: 12,
              child: _iconPill(
                icon: Icons.compare_arrows_rounded,
                label: _showingSource ? '看成片' : '看原图',
                onTap: _busy ? null : _toggleSource,
              ),
            ),
          if (_busy || _booting)
            Container(
              color: Colors.black.withValues(alpha: 0.45),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(strokeWidth: 2.4),
                    const SizedBox(height: 14),
                    Text(
                      _booting
                          ? '加载引擎与资源…'
                          : (_busyLabel ??
                              (_quality == PreviewQuality.fine ? '精细渲染中…' : '渲染中…')),
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
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
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _kAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.camera_roll_outlined, color: _kAccent, size: 30),
            ),
            const SizedBox(height: 18),
            Text(
              '选一张照片开始',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '相册图片由本机解码后直接进引擎，RAW 交给 LibRaw。\n'
              '两者走同一套胶片模型，都在本机 Vulkan 上算。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim, height: 1.6),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _kSurfaceHigh,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF2A2E37)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '胶片：${_stockName(_film)}',
                    style: theme.textTheme.labelSmall?.copyWith(color: _kTextDim),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '相纸：${_stockName(_paper)}',
                    style: theme.textTheme.labelSmall?.copyWith(color: _kTextDim),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '可在下方切换，选好后导入即可',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: _kAccent.withValues(alpha: 0.8),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: _busy || _booting ? null : _importPhoto,
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('从相册选择'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _busy || _booting ? null : _importRaw,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('RAW 文件'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '相册支持 JPEG / PNG / WebP；RAW 支持 ARW / DNG / CR2 / CR3 / NEF / RAF / ORF 等',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: _kTextDim,
                fontSize: 10,
                height: 1.5,
              ),
            ),
            if (_cached.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('最近导入', style: theme.textTheme.labelMedium?.copyWith(color: _kTextDim)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final raw in _cached.take(6))
                    ActionChip(
                      avatar: Icon(
                        raw.isPhoto ? Icons.image_outlined : Icons.raw_on_outlined,
                        size: 16,
                      ),
                      label: Text(
                        '${raw.name} · ${raw.sizeLabel}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: _busy || _booting ? null : () => _openCached(raw),
                    ),
                ],
              ),
            ],
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
    final canRender = _hasSession && !_busy;
    final canPick = !_busy;
    final isPrint = _panelLayer == _PanelLayer.print;
    return Container(
      decoration: const BoxDecoration(
        color: _kSurface,
        border: Border(top: BorderSide(color: Color(0xFF23262E))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 320,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Expanded(child: _buildStockPicker(theme, film: true, enabled: canPick)),
                    const SizedBox(width: 10),
                    Expanded(child: _buildStockPicker(theme, film: false, enabled: canPick)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(
                  children: [
                    SegmentedButton<_PanelLayer>(
                      showSelectedIcon: false,
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: WidgetStatePropertyAll(theme.textTheme.labelSmall),
                      ),
                      segments: const [
                        ButtonSegment(value: _PanelLayer.print, label: Text('印片')),
                        ButtonSegment(value: _PanelLayer.color, label: Text('调色')),
                      ],
                      selected: {_panelLayer},
                      onSelectionChanged: (selection) =>
                          setState(() => _panelLayer = selection.first),
                    ),
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
                    TextButton.icon(
                      onPressed: canRender ? (isPrint ? _resetLive : _resetColor) : null,
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('重置'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: _kTextDim,
                      ),
                    ),
                  ],
                ),
              ),
              if (isPrint)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(
                    children: [
                      SegmentedButton<PreviewQuality>(
                        showSelectedIcon: false,
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: WidgetStatePropertyAll(theme.textTheme.labelSmall),
                        ),
                        segments: const [
                          ButtonSegment(value: PreviewQuality.fast, label: Text('实时 1600')),
                          ButtonSegment(value: PreviewQuality.fine, label: Text('精细 3400')),
                        ],
                        selected: {_quality},
                        onSelectionChanged: _busy
                            ? null
                            : (selection) {
                                final quality = selection.first;
                                setState(() => _quality = quality);
                                if (quality == PreviewQuality.fine) {
                                  _renderFine();
                                } else if (_hasSession) {
                                  // Back to live: one cheap frame so the pixels
                                  // match the mode the badge now claims.
                                  _requestLive();
                                }
                              },
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 12),
                  children: isPrint
                      ? _printSliders(theme, canRender)
                      : _colorSliders(theme, canRender),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Layer 1 controls: every one of these ends in an engine reprint.
  List<Widget> _printSliders(ThemeData theme, bool canRender) {
    return [
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
        label: '偏移强度',
        valueLabel: _shiftScale.toStringAsFixed(0),
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

  Widget _buildStockPicker(ThemeData theme, {required bool film, required bool enabled}) {
    final options = film ? _films : _papers;
    final value = film ? _film : _paper;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _kSurfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2A2E37)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: options.any((stock) => stock.id == value) ? value : null,
          hint: Text(
            options.isEmpty ? '未找到 profile' : (film ? '胶片' : '相纸'),
            style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim),
          ),
          icon: const Icon(Icons.expand_more, size: 18, color: _kTextDim),
          dropdownColor: _kSurfaceHigh,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
          onChanged: enabled
              ? (id) {
                  if (id != null) _changeStock(film ? 'film_stock' : 'print_stock', id);
                }
              : null,
          items: [
            for (final stock in options)
              DropdownMenuItem(
                value: stock.id,
                child: Text(stock.name, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );
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
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
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
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: _kAccent,
                inactiveTrackColor: const Color(0xFF333842),
                thumbColor: _kAccent,
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
            width: 70,
            child: Text(
              valueLabel,
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFeatures: const [ui.FontFeature.tabularFigures()],
                color: enabled ? theme.colorScheme.onSurface : _kTextDim,
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: Colors.white70,
          fontFeatures: const [ui.FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _iconPill({required IconData icon, required String label, VoidCallback? onTap}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.white70),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
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
enum _PanelLayer { print, color }

/// Draws the frame with the Layer 2 colour matrix, keeping the fit the old
/// `RawImage` had. `colorFilter` is a GPU operation, so dragging a Layer 2
/// slider never waits for the engine.
class _PreviewPainter extends CustomPainter {
  _PreviewPainter({required this.image, required this.colorFilter});

  final ui.Image image;
  final ui.ColorFilter colorFilter;

  @override
  void paint(Canvas canvas, Size size) {
    final source = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, source, size);
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(
      image,
      Offset.zero & source,
      destination,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = colorFilter,
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.colorFilter != colorFilter;
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
