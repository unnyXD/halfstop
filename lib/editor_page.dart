import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// `show` keeps dart:typed_data the explicit source of Uint8List.
import 'package:flutter/services.dart' show HapticFeedback;

import 'engine_bridge.dart';
import 'engine_worker.dart';
import 'exporter.dart';
import 'frame_format.dart';
import 'render_budget.dart';
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

// Panel geometry: a bar you can see past, and a full sheet. The action bar
// under it appears only while the sheet is open, so a collapsed panel leaves
// the picture as much room as possible.
const double _kPanelExpanded = 380;
const double _kPanelCollapsed = 72;
const double _kActionBar = 52;

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
  static const int _fineEdge = 3400;

  /// The device's plane budget in pixels (12 B/px), 0 until the engine says.
  /// The rebate canvas is a second allocation bigger than the frame, so this is
  /// what decides how large a frame with 片边 on can be rendered.
  int _maxPlanePixels = 0;

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

  /// States that were undone, newest last. Cleared by any new edit.
  final List<_EditSnapshot> _redoHistory = [];

  bool _exporting = false;

  /// Layer 2: the digital colour layer. Applied on the GPU by the preview and
  /// replayed in Dart on export, so no engine round-trip is involved.
  Layer2Params _layer2 = Layer2Params.neutral;
  Uint8List? _framePixels;
  Histogram? _histogram;

  /// Meter reading for the frame on screen. Recomputed with the histogram, so
  /// it follows a film change or a strength change without any extra pass.
  Metering _metering = Metering.empty;
  bool _showHistogram = true;
  _PanelLayer _panelLayer = _PanelLayer.exposure;

  /// The panel is a bar until there is something to edit. It animates its own
  /// height, so the preview grows and shrinks with it instead of jumping.
  bool _panelExpanded = false;

  /// Accumulated drag distance while the grip is held, used to decide the
  /// direction on release. Reset every gesture.
  double _panelDrag = 0;

  /// Frame geometry. Everything here is SHOOT layer in the engine: changing it
  /// re-develops the negative, so these are "commit on release" controls.
  FilmFormat? _format;

  /// Where the gate sits inside the frame. Null means "centred", which is what
  /// picking a format gives you; dragging the crop window writes here.
  CropBox? _crop;

  /// Crop mode: the preview shows the whole frame and a movable gate.
  bool _cropping = false;
  CropBox _cropDraft = CropBox.full;
  ui.Image? _cropCanvas;

  /// The pinch progress so far, so updates apply the delta since last frame.
  double _cropGestureScale = 1;
  bool _overscanOn = false;
  /// `strip` lays out the whole film width, `filed` a sliver of rebate.
  String _overscanMode = 'strip';
  String _holes = 'white';
  String _carrier = 'none';
  double _edgeFog = 1;
  double _leaks = 0;

  /// The gate's shape. `auto` draws whatever the real cameras for the format
  /// used; the rest pick one family outright.
  String _gate = 'auto';

  /// What the manufacturer's edge print says. Empty keeps the stock's own,
  /// which is what a real strip has; anything else overrides it.
  String _edgeText = '';

  /// The frame number on the edge print; -1 means "the frame's own draw".
  int _frameNumber = -1;

  /// The aperture printed beside the frame, in stops. 0 = not recorded, and
  /// the engine falls back to f/5.6.
  double _fNumber = 0;

  /// Two half-frames on one strip (135_half only).
  bool _pair = false;

  bool _dateOn = false;
  String _dateText = '';
  String _dateStyle = 'lcd';
  String _datePlacement = 'frame';
  String _dateCorner = 'br';
  double _dateSize = 1;

  /// The shooting data printed beside the date (1.3.1): ISO, shutter, aperture.
  String _dataText = '';

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
      unawaited(_ensureThumbnails());
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

  /// What the rebate says when the user has not written anything.
  ///
  /// The engine prints no stock name of its own: `overscan_edge_text` *is* the
  /// name on the edge ("the host's text", `overscan.cpp`), so an empty field
  /// leaves a blank rebate rather than the film's own print. The app fills in
  /// the film's name, which is what a real strip carries.
  String get _defaultEdgeText => _stockName(_film).toUpperCase();

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
    return _crop ??
        centreCropForRatio(format.ratio, _sourceWidth, _sourceHeight);
  }

  /// The largest gate long edge that still fits the device's buffer once the
  /// rebate is laid around it. [desired] comes back untouched when it fits,
  /// which is the common case on formats that are not 120 panoramas.
  int _overscanEdge(int desired) {
    final format = _format;
    if (!_overscanOn || format == null || _maxPlanePixels <= 0) return desired;
    return clampOverscanLongEdge(
      desiredEdge: desired,
      frameAspect: format.ratio,
      format: format,
      mode: _overscanMode,
      carrier: _carrier,
      pair: _pair && format.id == '135_half',
      budgetPixels: (_maxPlanePixels * kOverscanHeadroom).round(),
    );
  }

  /// One call after the session opens: the budget is a device property, not a
  /// session one.
  Future<void> _syncBudget() async {
    final worker = _worker;
    if (worker == null) return;
    final budget = await worker.maxPlanePixels();
    if (!mounted || budget == _maxPlanePixels) return;
    setState(() => _maxPlanePixels = budget);
  }

  Map<String, Object?> _frameDelta() {
    final crop = _cropBox;
    return {
      'geometry_crop_x': crop.x,
      'geometry_crop_y': crop.y,
      'geometry_crop_w': crop.width,
      'geometry_crop_h': crop.height,
      'preview_long_edge': _overscanEdge(_previewEdge),
      'overscan_active': _format != null && _overscanOn,
      if (_format != null) 'overscan_format': _format!.id,
      'overscan_mode': _overscanMode,
      'overscan_holes': _holes,
      'overscan_carrier': _carrier,
      'overscan_gate': _gate,
      'overscan_fog': _edgeFog,
      'overscan_leaks': _leaks,
      // Always sent, empty included: the engine keeps whatever it was last
      // told, so omitting the field on "clear" leaves the old text printed.
      // An empty edge text is what makes it draw the stock's own rebate.
      'overscan_edge_text': _edgeText.isEmpty ? _defaultEdgeText : _edgeText,
      // 0 is the engine's "no frame number, draw one": -1 is the UI's.
      'overscan_frame_number': _frameNumber < 0 ? 0 : _frameNumber,
      'overscan_f_number': _fNumber,
      'overscan_pair': _pair && _format?.id == '135_half',
      'date_imprint_active': _dateOn,
      if (_dateOn) 'date_imprint_text': _dateText.isEmpty ? defaultDateText() : _dateText,
      if (_dateOn) 'date_imprint_style': _dateStyle,
      if (_dateOn) 'date_imprint_corner': _dateCorner,
      if (_dateOn) 'date_imprint_size': _dateSize,
      if (_dateOn) 'date_imprint_data_text': _dataText,
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
      _metering = Metering.empty;
      _framePixels = null;
      _imageWidth = 0;
      _imageHeight = 0;
      _history.clear();
      _redoHistory.clear();
      _format = null;
      _crop = null;
      _cropping = false;
      _overscanOn = false;
      _dateOn = false;
      _panelExpanded = false;
    });
    final staleCrop = _cropCanvas;
    _cropCanvas = null;
    staleCrop?.dispose();
    image?.dispose();
    source?.dispose();
    unawaited(EngineBridge.cachedRaws().then((cached) {
      if (!mounted) return;
      setState(() => _cached = cached);
      unawaited(_ensureThumbnails());
    }));
  }

  Future<void> _pickFormat(FilmFormat? format) async {
    if (format?.id == _format?.id) return;
    setState(() {
      _format = format;
      // A new gate starts centred; the old placement belonged to the old shape.
      _crop = null;
      if (format == null) {
        _overscanOn = false;
        _datePlacement = 'frame';
      }
    });
    await _applyFrame(label: format == null ? '恢复原比例…' : '按 ${format.label} 重算…');
  }

  /// Enter crop mode.
  ///
  /// The preview on screen is already cropped, so the pixels outside the gate
  /// are gone. Rather than fake it, ask the engine for the whole frame once —
  /// that costs a live render — and let the user drag the gate over the real
  /// image. Confirming renders again with the new placement.
  Future<void> _beginCrop() async {
    if (_format == null || !_hasSession || _busy) return;
    setState(() {
      _busy = true;
      _busyLabel = '准备整幅画面…';
    });
    try {
      await _worker!.setParams({
        ..._liveDelta(),
        ..._slowDelta(),
        'geometry_crop_x': 0.0,
        'geometry_crop_y': 0.0,
        'geometry_crop_w': 1.0,
        'geometry_crop_h': 1.0,
        'film_stock': _film,
        'print_stock': _paper,
      });
      final frame = await _worker!.reprint(tier: 'live');
      final image = await _imageFromFrame(frame);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _cropCanvas?.dispose();
        _cropCanvas = image;
        _cropDraft = _cropBox;
        _cropping = true;
      });
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

  Future<void> _endCrop({required bool apply}) async {
    if (!_cropping) return;
    final canvas = _cropCanvas;
    setState(() {
      _cropping = false;
      _cropCanvas = null;
      if (apply) _crop = _cropDraft;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => canvas?.dispose());
    // Either way the engine has the full frame right now and needs telling
    // which gate to use.
    await _applyFrame(label: apply ? '应用裁切…' : '恢复裁切…');
  }

  void _resetCrop() {
    setState(() => _crop = null);
    unawaited(_applyFrame(label: '裁切居中…'));
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

  /// Shared prompt for the free-text edge print, the frame number and the
  /// data line. `null` means the user backed out.
  Future<String?> _promptText({
    required String title,
    required String helper,
    required String initial,
    int maxLength = 32,
    TextInputType keyboard = TextInputType.text,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _kSurface,
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: maxLength,
          keyboardType: keyboard,
          decoration: InputDecoration(hintText: helper, helperText: helper),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(''), child: const Text('清空')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _editEdgeText() async {
    final value = await _promptText(
      title: '边字',
      helper: '留空用胶卷名（$_defaultEdgeText）',
      initial: _edgeText,
      maxLength: 28,
    );
    if (value == null || !mounted) return;
    setState(() => _edgeText = value);
    await _applyFrame(label: '换边字…');
  }

  Future<void> _editFrameNumber() async {
    final value = await _promptText(
      title: '帧号',
      helper: '1–99，留空由相机随机',
      initial: _frameNumber < 0 ? '' : _frameNumber.toString(),
      maxLength: 2,
      keyboard: TextInputType.number,
    );
    if (value == null || !mounted) return;
    final parsed = int.tryParse(value);
    setState(() => _frameNumber = parsed == null ? -1 : parsed.clamp(0, 99));
    await _applyFrame(label: '改帧号…');
  }

  Future<void> _editDataText() async {
    final value = await _promptText(
      title: '数据行',
      helper: 'ISO 400 1/125 f5.6 · 留空不打印',
      initial: _dataText,
      maxLength: 28,
    );
    if (value == null || !mounted) return;
    setState(() => _dataText = value);
    await _applyFrame(label: '改数据行…');
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
    unawaited(_ensureThumbnails());
  }

  /// Writes any missing preview for the home grid.
  ///
  /// A RAW already carries a JPEG its camera made; LibRaw hands it over without
  /// decoding (tens of milliseconds each), which is why the grid can be
  /// populated the first time the app opens rather than after a render.
  Future<void> _ensureThumbnails() async {
    final missing = _cached
        .where((entry) =>
            !entry.isPhoto && (entry.thumb == null || entry.thumb!.isEmpty))
        .toList();
    if (missing.isEmpty) return;
    var wrote = false;
    for (final entry in missing) {
      final slash = entry.path.lastIndexOf('/');
      if (slash <= 0) continue;
      final directory = Directory('${entry.path.substring(0, slash)}/.thumbs');
      try {
        if (!directory.existsSync()) directory.createSync(recursive: true);
      } on FileSystemException {
        continue;
      }
      final out = '${directory.path}/${entry.name}.jpg';
      try {
        final written = await EngineBridge.writeThumbnail(entry.path, out);
        wrote = wrote || written != null;
      } catch (_) {
        // A file without a preview is normal; the tile keeps its placeholder.
      }
    }
    if (!wrote || !mounted) return;
    final cached = await EngineBridge.cachedRaws();
    if (mounted) setState(() => _cached = cached);
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
        // There is something to edit now, so open the sheet for it.
        _panelExpanded = true;
        _busyLabel = '渲染中…';
      });
      await _syncBudget();
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
        // There is something to edit now, so open the sheet for it.
        _panelExpanded = true;
      });
      await _syncBudget();
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
    _redoHistory.clear();
    setState(() {});
  }

  Future<void> _undo() async {
    if (_history.isEmpty || _busy || !_hasSession) return;
    final snapshot = _history.removeLast();
    _redoHistory.add(_snapshot());
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

  Future<void> _redo() async {
    if (_redoHistory.isEmpty || _busy || !_hasSession) return;
    final snapshot = _redoHistory.removeLast();
    _history.add(_snapshot());
    if (_history.length > _maxUndo) _history.removeAt(0);
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
      // The `preview` tier is a fixed 3400 px long edge, which a rebate canvas
      // on a 120 format does not fit. The `live` tier takes its size from
      // `preview_long_edge`, so a capped fine frame asks for fewer pixels
      // through that tier instead of failing at 3400.
      final edge = _overscanEdge(_fineEdge);
      final tier = edge < _fineEdge ? 'live' : 'preview';
      await _worker!.setParams({
        ..._liveDelta(),
        ..._slowDelta(),
        'preview_long_edge': edge,
      });
      final stopwatch = Stopwatch()..start();
      final frame = await _worker!.reprint(tier: tier);
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
        // The rebate carries the stock's name, so it has to change with it.
        if (_overscanOn) 'overscan_edge_text': _edgeText.isEmpty ? _defaultEdgeText : _edgeText,
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
      // A rebate is drawn on a canvas larger than the frame, and the `full`
      // tier is the frame's own resolution with no way to ask for less — so on
      // a big source the canvas blows the device's buffer. Render through the
      // `live` tier at the largest edge that fits instead; it is the same
      // pixels, just budgeted.
      final fullEdge = math.min(math.max(_sourceWidth, _sourceHeight), 8192);
      final cappedEdge = _overscanEdge(fullEdge);
      final rebateCapped = _overscanOn && cappedEdge < fullEdge;
      await _worker!.setParams({
        ..._liveDelta(),
        ..._slowDelta(),
        if (rebateCapped) 'preview_long_edge': cappedEdge,
        'film_stock': _film,
        'print_stock': _paper,
      });
      stage.value = rebateCapped ? '渲染片边（${cappedEdge}px）…' : '渲染全尺寸…';
      final frame = rebateCapped
          ? await _worker!.reprint(tier: 'live')
          : await _worker!.render(tier: 'full');
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
      _metering = Metering.fromHistogram(_histogram!);
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
    final inset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(theme),
            Expanded(
              child: _cropping
                  ? _buildCropPreview(theme)
                  : _buildPreview(theme),
            ),
            if (_error != null) _buildErrorBar(theme),
            if (_cropping)
              _buildCropBar(theme)
            else ...[
              if (_image != null) _buildPanel(theme),
              // The action bar belongs to the open sheet. Collapsed, it goes
              // away and the picture gets the room instead.
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _image != null && _panelExpanded
                    ? _buildActionBar(theme)
                    : const SizedBox(width: double.infinity, height: 0),
              ),
            ],
            SizedBox(height: inset),
          ],
        ),
      ),
    );
  }

  /// Back, the original/preview switch, and export — the design's top row.
  /// With no picture open there is nothing to switch or export, so the row
  /// falls back to the wordmark instead of showing dead controls.
  Widget _buildHeader(ThemeData theme) {
    final hasImage = _image != null;
    if (!hasImage) {
      // A two-line lockup: the name, then the latin one tracked out under it.
      // One line of 20sp letter-spaced type read as a placeholder, not a brand.
      return Padding(
        padding: const EdgeInsets.fromLTRB(26, 20, 26, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '半档',
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 24,
                height: 1.1,
                letterSpacing: 7,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Container(width: 16, height: 1, color: _kLineStrong),
                const SizedBox(width: 8),
                Text(
                  'HALFSTOP',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 8.5,
                    letterSpacing: 3.4,
                    color: _kTextDim,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 6),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
              tooltip: '关闭照片',
              onPressed: _busy ? null : _closeImage,
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
              color: _kText,
              disabledColor: _kTextDim.withValues(alpha: 0.28),
              padding: EdgeInsets.zero,
            ),
          ),
          const Spacer(),
          _viewToggle(theme),
          const Spacer(),
          TextButton.icon(
            onPressed: _hasSession && !_busy ? _export : null,
            icon: const Icon(Icons.north_east_rounded, size: 13),
            label: const Text('导出'),
            style: TextButton.styleFrom(
              foregroundColor: _kAccent,
              disabledForegroundColor: _kTextDim.withValues(alpha: 0.32),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: theme.textTheme.labelLarge?.copyWith(
                fontSize: 12.5,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 原图 / 预览 as one pill with two halves, the way the design has it.
  Widget _viewToggle(ThemeData theme) {
    Widget half(String label, bool selected, VoidCallback? onTap) {
      return GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF35322E) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontSize: 12.5,
              color: selected ? _kText : _kTextDim,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      );
    }

    final enabled = _image != null;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _kSurfaceHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          half('原图', _showingSource, enabled ? _peekSource : null),
          half('预览', !_showingSource, enabled ? _endPeek : null),
        ],
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    final image = _showingSource ? _sourceImage : _image;
    final preview = Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B0A09), Color(0xFF15120F), _kBackground],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image == null)
            _buildEmptyState(theme)
          else ...[
            // A soft neutral wash behind the picture. It used to be a blurred
            // copy of the photo, which showed up as a coloured band above the
            // frame — this has no picture in it, so nothing can bleed.
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
              child: LayoutBuilder(
                builder: (context, box) {
                  const caption = 26.0;
                  final ratio = image.width / image.height;
                  var width = box.maxWidth;
                  var height = width / ratio;
                  final maxHeight = box.maxHeight - caption;
                  if (height > maxHeight) {
                    height = maxHeight;
                    width = height * ratio;
                  }
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          // Nothing is drawn on the picture: holding it is how
                          // you see the original, exactly like the design.
                          onLongPressStart: (_) => _peekSource(),
                          onLongPressEnd: (_) => _endPeek(),
                          onLongPressCancel: _endPeek,
                          child: SizedBox(
                            width: width,
                            height: height,
                            child: _photoFrame(image),
                          ),
                        ),
                        SizedBox(
                          width: width,
                          height: caption,
                          child: _photoCaption(theme, width < 320),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
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

    // Only a loaded photo gets the pull gesture. The empty state has a
    // scrollable list, and stealing its drags would make it feel broken.
    if (_image == null) return preview;
    return GestureDetector(
      onVerticalDragStart: (_) => _panelDrag = 0,
      onVerticalDragUpdate: (details) => _panelDrag += details.delta.dy,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -220 || _panelDrag < -40) {
          _setPanelExpanded(true);
        } else if (velocity > 220 || _panelDrag > 40) {
          _setPanelExpanded(false);
        }
        _panelDrag = 0;
      },
      child: preview,
    );
  }

  /// Crop mode: the gate is fixed — it *is* the film format — and the picture
  /// moves and scales under it. Pinch zooms around the fingers, one finger
  /// drags the picture.
  ///
  /// A smaller gate over the same source renders as a zoom, which is why no
  /// separate "scale" parameter exists: zoom is just how much of the picture
  /// the gate covers.
  Widget _buildCropPreview(ThemeData theme) {
    final canvas = _cropCanvas;
    if (canvas == null) return const SizedBox.expand();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B0A09), Color(0xFF15120F), _kBackground],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final crop = _cropDraft;
                final source = Size(
                  canvas.width.toDouble(),
                  canvas.height.toDouble(),
                );
                // The window keeps the gate's shape and sits at 92% of the
                // viewport, so the picture stays visible on every side.
                final available =
                    Size(box.maxWidth * 0.92, box.maxHeight * 0.92);
                final windowSize = Size(
                  source.width * crop.width,
                  source.height * crop.height,
                );
                final target = _containRect(available, windowSize).shift(
                  Offset(
                    (box.maxWidth - available.width) / 2,
                    (box.maxHeight - available.height) / 2,
                  ),
                );
                final scale = target.width / (source.width * crop.width);
                final origin = Offset(
                  target.center.dx - crop.centerX * source.width * scale,
                  target.center.dy - crop.centerY * source.height * scale,
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: (_) => _cropGestureScale = 1,
                  onScaleUpdate: (details) => _cropGestureUpdate(
                    details,
                    source,
                    scale,
                    origin,
                  ),
                  child: CustomPaint(
                    painter: _CropPainter(
                      image: canvas,
                      crop: crop,
                      scale: scale,
                      origin: origin,
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              '双指缩放 · 拖动移动 · ×${_cropZoom.toStringAsFixed(2)}',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                color: _kTextDim,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// How far in the gate currently is, relative to the largest fit.
  double get _cropZoom {
    final format = _format;
    if (format == null) return 1;
    final base =
        centreCropForRatio(format.ratio, _sourceWidth, _sourceHeight);
    return base.width <= 0 ? 1 : base.width / _cropBox.width;
  }

  void _cropGestureUpdate(
    ScaleUpdateDetails details,
    Size source,
    double scale,
    Offset origin,
  ) {
    if (details.pointerCount >= 2) {
      // Pinch: zoom the gate about the point between the fingers.
      final factor = _cropGestureScale <= 0
          ? 1.0
          : details.scale / _cropGestureScale;
      _cropGestureScale = details.scale;
      if ((factor - 1).abs() < 0.001) return;
      final focal = Offset(
        ((details.localFocalPoint.dx - origin.dx) / (source.width * scale))
            .clamp(0.0, 1.0),
        ((details.localFocalPoint.dy - origin.dy) / (source.height * scale))
            .clamp(0.0, 1.0),
      );
      setState(() => _cropDraft = zoomGate(_cropDraft, factor, focal));
      return;
    }
    // One finger drags the picture; the gate moves the other way.
    final delta = details.focalPointDelta;
    if (delta == Offset.zero) return;
    final crop = _cropDraft;
    setState(() {
      _cropDraft = _cropDraft.shifted(
        -delta.dx / (source.width * scale * crop.width),
        -delta.dy / (source.height * scale * crop.height),
      );
    });
  }

  /// Fit [source] inside [box], centred.
  Rect _containRect(Size box, Size source) {
    if (source.width <= 0 || source.height <= 0) return Offset.zero & box;
    final scale = math.min(box.width / source.width, box.height / source.height);
    final width = source.width * scale;
    final height = source.height * scale;
    return Rect.fromLTWH(
      (box.width - width) / 2,
      (box.height - height) / 2,
      width,
      height,
    );
  }

  Widget _buildCropBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        color: _kSurface,
        border: Border(top: BorderSide(color: _kLine)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _endCrop(apply: false),
              style: OutlinedButton.styleFrom(
                foregroundColor: _kTextDim,
                side: const BorderSide(color: _kLineStrong),
                minimumSize: const Size(0, 42),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: () => _endCrop(apply: true),
              style: FilledButton.styleFrom(
                backgroundColor: _kAccent,
                foregroundColor: const Color(0xFF20160A),
                minimumSize: const Size(0, 42),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
    );
  }

  /// The picture, and nothing else. Every control lives outside the frame.
  Widget _photoFrame(ui.Image image) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF050403),
        borderRadius: BorderRadius.circular(12),
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
    );
  }

  /// `DSCF_0428 · 24 MP` on the left, the hold hint on the right.
  Widget _photoCaption(ThemeData theme, bool narrow) {
    // The camera's pixel count, not the preview's: the sheet downsamples to
    // 1600 px and "1.7 MP" would be a lie about the file.
    final pixels = _sourceWidth * _sourceHeight;
    final mp = pixels >= 10000000
        ? (pixels / 1000000).round().toString()
        : (pixels / 1000000).toStringAsFixed(1);
    final label = narrow ? '$mp MP' : '${_fileLabel()} · $mp MP';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                letterSpacing: 0.4,
                color: _kTextDim,
              ),
            ),
          ),
          if (_strength < 0.999) ...[
            Text(
              '强度 ${(_strength * 100).round()}%',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                color: _kAccent,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Icon(Icons.touch_app_outlined, size: 12, color: _kTextDim.withValues(alpha: 0.8)),
          const SizedBox(width: 4),
          Text(
            '长按对比',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: _kTextDim.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  String _fileLabel() {
    final path = _path;
    if (path == null || path.isEmpty) return '未命名';
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Show the untouched frame while the finger is down, or while 原图 is
  /// selected in the header.
  Future<void> _peekSource() async {
    if (_image == null || _busy || _showingSource) return;
    if (_sourceImage == null) {
      await _ensureSource();
      if (!mounted) return;
    }
    if (_sourceImage == null) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _showingSource = true);
  }

  void _endPeek() {
    if (_showingSource && mounted) setState(() => _showingSource = false);
  }

  Widget _buildEmptyState(ThemeData theme) {
    // Top-aligned, not centred: the brand block belongs under the wordmark, and
    // a centred column on a tall phone opened a hole between the two.
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 10, 28, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The same card the launcher icon is cut from, sitting on the
            // table like a print: a hair off square, with a soft shadow.
            Transform.rotate(
              angle: -0.012,
              child: Container(
                width: 168,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 26,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    'assets/brand/halfstop-card.png',
                    width: 168,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '不是滤镜，是冲印',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim),
            ),
            const SizedBox(height: 26),
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
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 7,
                  crossAxisSpacing: 7,
                  childAspectRatio: 1,
                ),
                itemCount: _cached.take(9).length,
                itemBuilder: (context, index) {
                  final entry = _cached[index];
                  return _recentTile(theme, entry);
                },
              ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: _booting ? null : _showDiagnostics,
                icon: const Icon(Icons.memory_outlined, size: 13),
                label: const Text('引擎诊断'),
                style: TextButton.styleFrom(
                  foregroundColor: _kTextDim,
                  textStyle: theme.textTheme.labelSmall?.copyWith(fontSize: 10.5),
                  visualDensity: VisualDensity.compact,
                ),
              ),
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      height: _panelExpanded ? _kPanelExpanded : _kPanelCollapsed,
      decoration: const BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: _kLine)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        // The body is always laid out at full height and merely clipped, so
        // collapsing costs no relayout of the sliders underneath.
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: _kPanelExpanded,
          maxHeight: _kPanelExpanded,
          child: _buildPanelBody(theme),
        ),
      ),
    );
  }

  Widget _buildPanelBody(ThemeData theme) {
    final canRender = _hasSession && !_busy;
    return Column(
      children: [
        _buildGrip(),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _panelExpanded
              ? Column(
                  key: const ValueKey('open'),
                  children: [
                    _buildFilmRow(theme),
                    _buildTabs(theme),
                  ],
                )
              : _buildCollapsedBar(theme),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 2, bottom: 10),
            children: switch (_panelLayer) {
              _PanelLayer.exposure => _exposureSliders(theme, canRender),
              _PanelLayer.grain => _grainSliders(theme, canRender),
              _PanelLayer.color => _colorSliders(theme, canRender),
              _PanelLayer.frame => _frameControls(theme, canRender),
            },
          ),
        ),
      ],
    );
  }

  /// The film in use, as one row: mark, name, paper, format. Tap picks a film,
  /// long-press picks a paper.
  Widget _buildFilmRow(ThemeData theme) {
    final enabled = !_busy && _stocks.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: enabled ? () => _showStockSheet(film: true) : null,
        onLongPress: enabled ? () => _showStockSheet(film: false) : null,
        child: Container(
          height: 54,
          padding: const EdgeInsets.fromLTRB(9, 0, 8, 0),
          decoration: BoxDecoration(
            color: _kSurfaceHigh,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: _kLine),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F0E0C),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kLineStrong),
                ),
                child: const CustomPaint(painter: _FrameMarkPainter()),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _stocks.isEmpty ? '未找到 profile' : _stockName(_film),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _kText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '相纸 · ${_stockName(_paper)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: _kTextDim,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _format?.label ?? '原比例',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10.5,
                  color: _kTextDim,
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 17, color: _kTextDim),
            ],
          ),
        ),
      ),
    );
  }

  /// Undo, redo, compare, close. Only while the sheet is open.
  Widget _buildActionBar(ThemeData theme) {
    final canEdit = _hasSession && !_busy && _image != null;
    return Container(
      height: _kActionBar,
      decoration: const BoxDecoration(
        color: _kSurface,
        border: Border(top: BorderSide(color: _kLine)),
      ),
      child: Row(
        children: [
          _barAction(
            theme,
            icon: Icons.undo_rounded,
            label: '撤销',
            enabled: canEdit && _history.isNotEmpty,
            onTap: _undo,
          ),
          _barDivider(),
          _barAction(
            theme,
            icon: Icons.redo_rounded,
            label: '重做',
            enabled: canEdit && _redoHistory.isNotEmpty,
            onTap: _redo,
          ),
          _barDivider(),
          _barAction(
            theme,
            icon: Icons.compare_arrows_rounded,
            label: '对比',
            enabled: _image != null && !_busy,
            active: _showingSource,
            onTap: () => _showingSource ? _endPeek() : unawaited(_peekSource()),
          ),
          _barDivider(),
          _barAction(
            theme,
            icon: Icons.add_photo_alternate_outlined,
            label: '导入',
            enabled: !_busy && !_booting,
            onTap: _import,
          ),
          _barDivider(),
          _barAction(
            theme,
            icon: Icons.close_rounded,
            label: '关闭',
            enabled: _image != null && !_busy,
            onTap: _closeImage,
          ),
        ],
      ),
    );
  }

  Widget _barAction(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
    bool active = false,
  }) {
    final color = !enabled
        ? _kTextDim.withValues(alpha: 0.3)
        : (active ? _kAccent : _kTextDim);
    return Expanded(
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 9.5,
                letterSpacing: 0.3,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barDivider() => Container(width: 1, height: 22, color: _kLine);

  /// The bar you grab. Tall enough to hit with a thumb, and it accepts a flick
  /// in either direction so the panel opens the way a sheet should.
  Widget _buildGrip() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setPanelExpanded(!_panelExpanded),
      onVerticalDragStart: (_) => _panelDrag = 0,
      onVerticalDragUpdate: (details) => _panelDrag += details.delta.dy,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -160 || _panelDrag < -18) {
          _setPanelExpanded(true);
        } else if (velocity > 160 || _panelDrag > 18) {
          _setPanelExpanded(false);
        }
        _panelDrag = 0;
      },
      child: SizedBox(
        height: 24,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: _panelExpanded ? 34 : 46,
            height: 3,
            decoration: BoxDecoration(
              color: _kLineStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  /// Collapsed: what is loaded, and nothing else. Tapping anywhere opens.
  Widget _buildCollapsedBar(ThemeData theme) {
    final has = _image != null;
    final label = has
        ? '${_stockName(_film)} · ${_stockName(_paper)}'
        : '展开调节面板';
    return InkWell(
      onTap: () => _setPanelExpanded(true),
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
          child: Row(
            children: [
              if (has) ...[
                Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    color: _kAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12.5,
                    color: has ? _kText : _kTextDim,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.keyboard_arrow_up_rounded, size: 20, color: _kTextDim),
            ],
          ),
        ),
      ),
    );
  }

  void _setPanelExpanded(bool value, {bool haptic = true}) {
    if (_panelExpanded == value) return;
    if (haptic) unawaited(HapticFeedback.selectionClick());
    setState(() => _panelExpanded = value);
  }

  /// Text tabs with an amber underline, exactly like the design. Only the
  /// groups this engine actually has are listed.
  Widget _buildTabs(ThemeData theme) {
    const labels = {
      _PanelLayer.exposure: '曝光',
      _PanelLayer.grain: '颗粒',
      _PanelLayer.color: '调色',
      _PanelLayer.frame: '画幅',
    };
    return SizedBox(
      height: 44,
      child: Stack(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            children: [
              for (final entry in labels.entries)
                _tab(theme, entry.key, entry.value),
            ],
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Divider(height: 1, thickness: 1, color: _kLine),
          ),
        ],
      ),
    );
  }

  Widget _tab(ThemeData theme, _PanelLayer layer, String label) {
    final selected = _panelLayer == layer;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _panelLayer = layer),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                fontSize: 12.5,
                letterSpacing: 0.4,
                color: selected ? _kText : _kTextDim,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 2,
              width: selected ? 22 : 0,
              decoration: BoxDecoration(
                color: _kAccent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The meter: how the frame currently sits, and a one-tap fix. It updates
  /// with every rendered frame, so changing the film or the strength moves the
  /// numbers while you watch.
  Widget _meterStrip(ThemeData theme, bool canRender) {
    final meter = _metering;
    final ready = canRender && !meter.isEmpty;
    String pct(double value) {
      final percent = value * 100;
      return percent >= 10
          ? '${percent.round()}%'
          : '${percent.toStringAsFixed(1)}%';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
      child: Row(
        children: [
          Icon(
            Icons.center_focus_weak_rounded,
            size: 14,
            color: ready ? _kAccent : _kTextDim.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 6),
          Text(
            '测光',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: _kTextDim,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ready
                  ? '平均 ${pct(meter.mean)} · 高光 ${pct(meter.highlights)} · 暗部 ${pct(meter.shadows)}'
                  : '等待画面…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                color: _kTextDim,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (ready && meter.needsExposure)
            GestureDetector(
              onTap: _autoExposure,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _kAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: _kAccent.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.auto_fix_high_rounded, size: 12, color: _kAccent),
                    const SizedBox(width: 5),
                    Text(
                      '自动 ${meter.suggestedEv >= 0 ? '+' : ''}'
                      '${meter.suggestedEv.toStringAsFixed(2)} EV',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: _kAccent,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (ready)
            Text(
              '已对齐',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10,
                color: _kTextDim.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
    );
  }

  /// Section label with its own reset, the way the design groups controls.
  Widget _sectionHeader(
    ThemeData theme,
    String label, {
    VoidCallback? onReset,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9.5,
              letterSpacing: 2.2,
              color: _kTextDim.withValues(alpha: 0.75),
            ),
          ),
          const Spacer(),
          if (onReset != null)
            TextButton(
              onPressed: onReset,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: _kTextDim,
                minimumSize: const Size(44, 28),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                textStyle: theme.textTheme.labelSmall?.copyWith(fontSize: 11),
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
      _sectionHeader(theme, '片门', onReset: enabled ? _resetFrame : null),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Text(
          '画幅决定片门尺寸，也决定颗粒相对于画面的粗细；选画幅会按片门比例裁剪，位置可以调。',
          style: theme.textTheme.bodySmall?.copyWith(color: _kTextDim, height: 1.4),
        ),
      ),
      SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            _formatChip(theme, null, '原图', enabled),
            for (final option in kFilmFormats)
              _formatChip(theme, option, option.label, enabled),
          ],
        ),
      ),
      if (format != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: enabled ? _beginCrop : null,
            // Long-press puts the gate back in the middle without opening the
            // crop screen.
            onLongPress: enabled ? _resetCrop : null,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: _kSurfaceHigh,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _kLine),
              ),
              child: Row(
                children: [
                  const Icon(Icons.crop_rounded, size: 16, color: _kTextDim),
                  const SizedBox(width: 10),
                  Text(
                    '调整裁切',
                    style: theme.textTheme.bodySmall?.copyWith(color: _kText),
                  ),
                  const Spacer(),
                  Text(
                    crop.placementLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.5,
                      color: crop.isCentred ? _kTextDim : _kAccent,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded, size: 16, color: _kTextDim),
                ],
              ),
            ),
          ),
        ),
      if (format != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The gate in millimetres, the film it sits on, and the shape —
              // "36 × 24" alone does not say which strip the frame came off.
              Text(
                '片门 ${_mm(format.longEdge)} × ${_mm(format.shortEdge)} mm'
                ' · ${format.isThirtyFive ? '135' : '120'} 片基 ${format.filmWidth.toStringAsFixed(0)} mm'
                ' · ${format.ratio.toStringAsFixed(2)} : 1',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10.5,
                  color: _kTextDim,
                  height: 1.5,
                ),
              ),
              Text(
                '${format.note} · 保留 ${(crop.width * 100).round()}% × ${(crop.height * 100).round()}%',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: _kTextDim.withValues(alpha: 0.75),
                  height: 1.5,
                ),
              ),
            ],
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
        if (_maxPlanePixels > 0 && _overscanEdge(_fineEdge) < _fineEdge)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Text(
              '片边受显存限制：本机缓冲上限 ${planeBudgetMegapixels(_maxPlanePixels).toStringAsFixed(1)} MP，'
              '预览与导出改用长边 ≤ ${_overscanEdge(_fineEdge)} px',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                color: _kTextDim,
              ),
            ),
          ),
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
          '排布',
          const ['strip', 'filed'],
          const ['条状', '单张'],
          _overscanMode,
          enabled,
          (value) {
            setState(() => _overscanMode = value);
            _applyFrame(label: '换排布…');
          },
        ),
        _choiceRow(
          theme,
          '片门形',
          const ['auto', 'square', 'rounded', 'eared', 'shouldered', 'kicked'],
          const ['自动', '方形', '圆角', '带耳', '带肩', '踢角'],
          _gate,
          enabled,
          (value) {
            setState(() => _gate = value);
            _applyFrame(label: '换片门…');
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
        _tapRow(
          theme,
          '边字',
          _edgeText.isEmpty ? '默认 · $_defaultEdgeText' : _edgeText,
          enabled,
          () => _editEdgeText(),
        ),
        _tapRow(
          theme,
          '帧号',
          _frameNumber < 0 ? '自动' : _frameNumber.toString(),
          enabled,
          () => _editFrameNumber(),
        ),
        _choiceRow(
          theme,
          '光圈',
          const ['0', '2.8', '4', '5.6', '8', '11', '16'],
          const ['未知', 'f2.8', 'f4', 'f5.6', 'f8', 'f11', 'f16'],
          _fNumber == 0 ? '0' : _fNumber.toString(),
          enabled,
          (value) {
            setState(() => _fNumber = double.parse(value));
            _applyFrame(label: '改光圈…');
          },
        ),
        if (format.id == '135_half')
          _switchRow(
            theme,
            '半格成对',
            subtitle: '一格放两张半格，中间留片边',
            value: _pair,
            enabled: enabled,
            onChanged: (value) {
              setState(() => _pair = value);
              _applyFrame(label: value ? '拼第二格…' : '收第二格…');
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
        if (_datePlacement == 'frame')
          _choiceRow(
            theme,
            '角落',
            const ['br', 'bl', 'tr', 'tl'],
            const ['右下', '左下', '右上', '左上'],
            _dateCorner,
            enabled,
            (value) {
              setState(() => _dateCorner = value);
              _applyFrame(label: '挪日期…');
            },
          ),
        _sliderRow(
          theme,
          label: '字号',
          valueLabel: _dateSize.toStringAsFixed(1),
          value: _dateSize,
          min: 0.4,
          max: 3,
          enabled: enabled,
          onChanged: (value) => setState(() => _dateSize = value),
          onChangeEnd: (_) => _applyFrame(label: '改字号…'),
        ),
        _tapRow(
          theme,
          '数据行',
          _dataText.isEmpty ? '不打印' : _dataText,
          enabled,
          () => _editDataText(),
        ),
      ],
    ];
  }

  /// One square in the 最近导入 grid: the picture, its name in the corner and
  /// a RAW tag. The thumbnail is the camera's own JPEG preview, so opening the
  /// sheet does not cost a decode.
  Widget _recentTile(ThemeData theme, CachedRaw entry) {
    final source = entry.isPhoto ? entry.path : (entry.thumb ?? '');
    final ready = source.isNotEmpty && File(source).existsSync();
    return GestureDetector(
      onTap: _busy || _booting ? null : () => _openCached(entry),
      onLongPress: _busy ? null : () => _deleteCached(entry),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready)
              Image.file(
                File(source),
                fit: BoxFit.cover,
                cacheWidth: 360,
                errorBuilder: (_, _, _) => _tilePlaceholder(entry),
              )
            else
              _tilePlaceholder(entry),
            // The name is small and dim on purpose: the pictures are the list.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 10, 6, 5),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xB3000000)],
                  ),
                ),
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: const Color(0xFFF1EAE0),
                  ),
                ),
              ),
            ),
            if (!entry.isPhoto)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0A0908),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'RAW',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 8,
                      letterSpacing: 0.6,
                      color: _kTextDim,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tilePlaceholder(CachedRaw entry) {
    return Container(
      color: _kSurfaceHigh,
      alignment: Alignment.center,
      child: Icon(
        entry.isPhoto ? Icons.image_outlined : Icons.raw_on_outlined,
        size: 20,
        color: _kTextDim.withValues(alpha: 0.7),
      ),
    );
  }

  /// Millimetres without trailing zeros: 36.25 stays precise, 24 does not
  /// become "24.0".
  static String _mm(double value) {
    final text = value.toStringAsFixed(2);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
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
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Row(
        children: [
          SizedBox(
            width: 54,
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
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(
          children: [
            SizedBox(
              width: 54,
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

  /// Exposure: what the enlarger does to the print. Every one of these ends in
  /// an engine reprint.
  List<Widget> _exposureSliders(ThemeData theme, bool canRender) {
    return [
      _sectionHeader(theme, '光线', onReset: canRender ? _resetLive : null),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            _qualityPill(theme, PreviewQuality.fast, '实时 · 1600'),
            const SizedBox(width: 6),
            _qualityPill(theme, PreviewQuality.fine, '精细 · ${_overscanEdge(_fineEdge)}'),
            const Spacer(),
          ],
        ),
      ),
      _meterStrip(theme, canRender),
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
      // Pre-flash is intentionally not exposed: `preflash_exposure` is a
      // fraction of the film base density, and 1.0 crushes the print to black.
      // The only visible effect in a usable range duplicates exposure.
    ];
  }

  /// Grain, halation and glare — the surface of the print. These are the slow
  /// ones: they re-develop the negative rather than just reprint it.
  List<Widget> _grainSliders(ThemeData theme, bool canRender) {
    return [
      _sectionHeader(theme, '质感', onReset: canRender ? _resetGrain : null),
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

  /// Apply the meter's suggestion to the exposure slider. One tap, one undo
  /// step, and the engine reprints as usual.
  void _autoExposure() {
    if (!_hasSession || _busy || _metering.isEmpty) return;
    final next = (_exposureEv + _metering.suggestedEv).clamp(-4.0, 4.0);
    if ((next - _exposureEv).abs() < 0.01) return;
    _pushUndo();
    setState(() => _exposureEv = next);
    unawaited(HapticFeedback.selectionClick());
    _requestLive();
    if (_quality == PreviewQuality.fine) _renderFine();
  }

  void _resetGrain() {
    _pushUndo();
    setState(() {
      _grain = 1;
      _halation = 1;
      _glare = 0;
    });
    _applySlow();
  }

  /// Layer 2 controls: a GPU colour matrix. No engine call, no `_busy`, so the
  /// preview keeps up with the thumb.
  List<Widget> _colorSliders(ThemeData theme, bool canRender) {
    final enabled = _hasSession && !_busy;
    return [
      _sectionHeader(theme, '色彩', onReset: enabled ? _resetColor : null),
      if (_showHistogram)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              HistogramView(data: _histogram, width: 132, height: 44),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _showHistogram = false),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    '隐藏',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.5,
                      color: _kTextDim,
                    ),
                  ),
                ),
              ),
            ],
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: GestureDetector(
            onTap: () => setState(() => _showHistogram = true),
            child: Text(
              '显示直方图',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                color: _kAccent.withValues(alpha: 0.85),
              ),
            ),
          ),
        ),
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

  /// One sheet for both fields, grouped by what the stock actually is. The
  /// categories come from the profiles' own `stage`/`support`, so a bundle
  /// update reorders this list without a code change.
  /// One sheet for both stocks. The row that opens it cannot carry two tap
  /// targets, so the switch lives here — 胶片 on one side, 相纸 / 印片 on the
  /// other. Long-pressing the row still jumps straight to the paper side.
  Future<void> _showStockSheet({bool film = true}) async {
    var showFilm = film;

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _kSurface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = Theme.of(context);
          final current = showFilm ? _film : _paper;
          final grouped = groupStocks(
            _stocks.where((stock) => showFilm ? stock.isFilm : stock.isPrintStock),
          );
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.72,
            maxChildSize: 0.92,
            builder: (context, controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Row(
                    children: [
                      _sheetSwitch(
                        theme,
                        '胶片',
                        showFilm,
                        () => setSheetState(() => showFilm = true),
                      ),
                      const SizedBox(width: 8),
                      _sheetSwitch(
                        theme,
                        '相纸 / 印片',
                        !showFilm,
                        () => setSheetState(() => showFilm = false),
                      ),
                    ],
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
            ),
          );
        },
      ),
    );

    if (picked == null) return;
    Stock? stock;
    for (final candidate in _stocks) {
      if (candidate.id == picked) {
        stock = candidate;
        break;
      }
    }
    if (stock == null) return;
    // Which slot it belongs in follows from the profile itself, not from which
    // tab happened to be open when it was tapped.
    if (stock.isFilm) {
      if (picked != _film) await _changeStock('film_stock', picked);
    } else if (picked != _paper) {
      await _changeStock('print_stock', picked);
    }
  }

  Widget _sheetSwitch(ThemeData theme, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? _kAccent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? _kAccent.withValues(alpha: 0.55) : _kLineStrong,
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: selected ? _kAccent : _kTextDim,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    color: enabled ? _kText : _kTextDim.withValues(alpha: 0.45),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(9, 5, 7, 5),
                decoration: BoxDecoration(
                  color: _kSurfaceHigh,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: _kLine),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      valueLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11.5,
                        letterSpacing: 0,
                        color: enabled ? _kText : _kTextDim.withValues(alpha: 0.45),
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(
            height: 36,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: _kAccent,
                inactiveTrackColor: _kLineStrong,
                disabledActiveTrackColor: _kLine,
                disabledInactiveTrackColor: _kLine,
                thumbColor: const Color(0xFFF1EAE0),
                disabledThumbColor: _kLineStrong,
                overlayColor: _kAccent.withValues(alpha: 0.12),
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
        ],
      ),
    );
  }

  void _setLayer2(Layer2Params next) {
    final pixels = _framePixels;
    setState(() {
      _layer2 = next;
      if (pixels != null) {
        _histogram = Histogram.fromRgba8(pixels, matrix: next.matrix);
        _metering = Metering.fromHistogram(_histogram!);
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

}

/// Which group of sliders the panel is showing.
///
/// `print` is the enlarger/film side and costs an engine reprint; `color` is
/// Layer 2 and costs nothing but a repaint.
/// The panel's groups. The print side is split in two so each tab holds a
/// handful of related controls instead of eight unrelated sliders.
enum _PanelLayer { exposure, grain, color, frame }

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

    // The same half disc as the launcher icon: one shape means the same thing
    // in both places.
    // Radius 7.5 against the 32-high gate keeps the same disc-to-gate ratio as
    // the launcher icon (47%), so the mark and the icon read as one design.
    final disc = Rect.fromCircle(
      center: Offset(size.width / 2, gate.center.dy),
      radius: 7.5,
    );
    final discLine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = amber.withValues(alpha: 0.75);
    final discFill = Paint()..color = amber.withValues(alpha: 0.55);
    canvas.drawArc(disc, -math.pi / 2, math.pi * 2, false, discLine);
    canvas.drawArc(disc, math.pi / 2, math.pi, true, discFill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The picture drawn at [origin] and [scale], with the part outside the gate
/// dimmed and the gate outlined with thirds. The gate is a fixed rect centred
/// in the viewport — it never moves; the picture does.
class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.image,
    required this.crop,
    required this.scale,
    required this.origin,
  });

  final ui.Image image;
  final CropBox crop;
  final double scale;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    final source = Size(image.width.toDouble(), image.height.toDouble());
    final destination = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      source.width * scale,
      source.height * scale,
    );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(
      image,
      Offset.zero & source,
      destination,
      Paint()..filterQuality = FilterQuality.medium,
    );

    final window = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: crop.width * source.width * scale,
      height: crop.height * source.height * scale,
    );

    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addRect(window)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = const Color(0xC40A0908));

    canvas.drawRect(
      window,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = const Color(0xCCF1EAE0),
    );

    // Thirds, faint: enough to compose with, not enough to fight the picture.
    final thirds = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0x38FFFFFF);
    for (var i = 1; i < 3; i++) {
      final dx = window.left + window.width * i / 3;
      final dy = window.top + window.height * i / 3;
      canvas.drawLine(Offset(dx, window.top), Offset(dx, window.bottom), thirds);
      canvas.drawLine(Offset(window.left, dy), Offset(window.right, dy), thirds);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.scale != scale ||
      oldDelegate.origin != origin ||
      oldDelegate.crop.x != crop.x ||
      oldDelegate.crop.y != crop.y ||
      oldDelegate.crop.width != crop.width ||
      oldDelegate.crop.height != crop.height;
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
