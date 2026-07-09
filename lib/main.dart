import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_bridge.dart';

const _windowChannel = MethodChannel('picsss/window');
const _nativeImageChannel = MethodChannel('picsss/native_image');

Future<void> main(List<String> args) async {
  _log('main start args=$args executable=${Platform.resolvedExecutable}');
  WidgetsFlutterBinding.ensureInitialized();
  _log('widgets binding ready');
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _log('FlutterError: ${details.exceptionAsString()}\n${details.stack}');
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    _log('PlatformDispatcher error: $error\n$stack');
    return false;
  };
  runZonedGuarded(
    () {
      _log('runApp start');
      runApp(PicsssApp(initialPath: args.isEmpty ? null : args.first));
    },
    (error, stack) => _log('Zone error: $error\n$stack'),
  );
}

void _log(String message) {
  stderr.writeln('[picSSS] $message');
  try {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return;
    }
    final file = File('$home/Library/Logs/picSSS.log');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} [picSSS] $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } on Object {
    // Logging must never affect image loading.
  }
}

class PicsssApp extends StatelessWidget {
  const PicsssApp({super.key, required this.initialPath});

  final String? initialPath;

  @override
  Widget build(BuildContext context) {
    _log('PicsssApp build');
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'picSSS',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff00a889),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Segoe UI',
      ),
      home: ViewerPage(initialPath: initialPath),
    );
  }
}

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.initialPath});

  final String? initialPath;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final _focusNode = FocusNode();
  final _thumbnailController = ScrollController();
  final _materialized = <String, Future<MaterializedImage>>{};

  PicsssCore? _core;
  ImageLibrary? _library;
  int _index = 0;
  String? _error;
  bool _busy = true;
  bool _showControls = false;
  bool _showThumbnails = false;
  bool _fillMode = false;
  double _scale = 1;
  double _rotation = 0;
  Offset _pan = Offset.zero;
  DateTime? _lastEsc;
  Timer? _thumbnailHideTimer;

  @override
  void initState() {
    super.initState();
    _log('ViewerPage initState');
    try {
      _core = PicsssCore.instance;
      _log('Rust core ready');
    } on Object catch (error, stack) {
      _log('Rust core init error: $error\n$stack');
      _busy = false;
      _error = '$error';
      return;
    }
    unawaited(_boot());
  }

  @override
  void dispose() {
    if (Platform.isMacOS) {
      unawaited(_clearNativeImage());
    }
    _thumbnailHideTimer?.cancel();
    _thumbnailController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    _log('boot start initialPath=${widget.initialPath ?? "<none>"} cwd=${Directory.current.path}');
    final path = widget.initialPath ?? _samplePath();
    if (path == null) {
      _log('boot no startup path');
      setState(() => _busy = false);
      return;
    }
    _log('boot opening startup path=$path');
    await _openPath(path);
  }

  String? _samplePath() {
    final sampleDir = Directory(_join(Directory.current.path, '文件测试'));
    if (sampleDir.existsSync()) {
      return sampleDir.path;
    }
    return null;
  }

  Future<void> _pickAndOpen() async {
    final core = _core;
    if (core == null) {
      setState(() => _error = 'Rust 核心未初始化');
      return;
    }
    try {
      _log('pick start');
      final path = core.pickPath();
      _log('pick result: ${path ?? "<cancel>"}');
      if (path != null) {
        await _openPath(path);
      }
    } on Object catch (error) {
      _log('pick error: $error');
      setState(() => _error = '$error');
    }
  }

  Future<void> _openPath(String path) async {
    final core = _core;
    if (core == null) {
      setState(() => _error = 'Rust 核心未初始化');
      return;
    }
    _log('openPath start: $path');
    setState(() {
      _busy = true;
      _error = null;
      _materialized.clear();
    });
    try {
      final library = await Future(() => core.openPath(path));
      _log('openPath ok: kind=${library.kind}, items=${library.items.length}, selected=${library.selectedIndex}');
      if (!mounted) {
        return;
      }
      setState(() {
        _library = library;
        _index = library.selectedIndex
            .clamp(0, library.items.length - 1)
            .toInt();
        _busy = false;
        _resetView(keepFillMode: true);
      });
      _warmAround(_index);
    } on Object catch (error) {
      _log('openPath error: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  void _resetView({bool keepFillMode = false}) {
    _scale = 1;
    _rotation = 0;
    _pan = Offset.zero;
    if (!keepFillMode) {
      _fillMode = false;
    }
  }

  Future<MaterializedImage> _materialize(int index) {
    final core = _core;
    if (core == null) {
      return Future.error('Rust 核心未初始化');
    }
    final library = _library;
    if (library == null || index < 0 || index >= library.items.length) {
      return Future.error('没有可显示的图片');
    }
    final entry = library.items[index];
    return _materialized.putIfAbsent(
      entry.id,
      () => Future(() {
        _log('materialize start: index=$index id=${entry.id} title=${entry.title}');
        final image = core.materialize(entry);
        _log('materialize ok: index=$index path=${image.path} preview=${image.previewPath ?? "<none>"}');
        return image;
      }),
    );
  }

  void _warmAround(int center) {
    if (Platform.isMacOS) {
      return;
    }
    final library = _library;
    if (library == null) {
      return;
    }
    for (var offset = -4; offset <= 4; offset++) {
      final index = center + offset;
      if (index >= 0 && index < library.items.length) {
        unawaited(
          _materialize(index)
              .then((image) {
                if (!mounted) {
                  return;
                }
                final ImageProvider provider;
                if (offset == 0) {
                  provider = FileImage(File(image.path));
                } else {
                  provider = ResizeImage(
                    FileImage(File(image.path)),
                    width: 260,
                  );
                }
                precacheImage(provider, context);
              })
              .catchError((_) {}),
        );
      }
    }
  }

  Future<void> _showNativeImage(MaterializedImage image) async {
    if (!Platform.isMacOS) {
      return;
    }
    try {
      await _nativeImageChannel.invokeMethod<void>('show', {
        'path': image.path,
        'fill': _fillMode,
        'scale': _scale,
        'rotation': _rotation,
        'panX': _pan.dx,
        'panY': _pan.dy,
      });
      _log('native image show: ${image.path}');
    } on Object catch (error, stack) {
      _log('native image show error: $error\n$stack');
    }
  }

  Future<void> _clearNativeImage() async {
    try {
      await _nativeImageChannel.invokeMethod<void>('clear');
      _log('native image clear');
    } on Object catch (error, stack) {
      _log('native image clear error: $error\n$stack');
    }
  }

  void _switchTo(int index) {
    final library = _library;
    if (library == null || index < 0 || index >= library.items.length) {
      return;
    }
    setState(() {
      _index = index;
      _resetView(keepFillMode: true);
    });
    _warmAround(index);
  }

  void _next(int delta) {
    final library = _library;
    if (library == null || library.items.isEmpty) {
      return;
    }
    _switchTo((_index + delta).clamp(0, library.items.length - 1).toInt());
  }

  void _handleHover(PointerHoverEvent event, Size size) {
    final isMac = Platform.isMacOS;
    final topZone = event.localPosition.dy <= 72;
    final controlZone = isMac
        ? event.localPosition.dx <= 180
        : event.localPosition.dx >= size.width - 180;
    final thumbnailTriggerZone =
        event.localPosition.dy >= size.height - 190 &&
        event.localPosition.dx >= size.width * .18 &&
        event.localPosition.dx <= size.width * .82;
    final visibleRailZone =
        _showThumbnails &&
        event.localPosition.dy >= size.height - 154 &&
        event.localPosition.dx >= 24 &&
        event.localPosition.dx <= size.width - 24;

    final showControls = topZone && controlZone;
    if (showControls != _showControls) {
      setState(() {
        _showControls = showControls;
      });
    }
    if (thumbnailTriggerZone || visibleRailZone) {
      _showThumbnailRail();
    } else {
      _scheduleThumbnailHide();
    }
  }

  void _showThumbnailRail() {
    _thumbnailHideTimer?.cancel();
    if (!_showThumbnails && mounted) {
      setState(() => _showThumbnails = true);
    }
  }

  void _scheduleThumbnailHide() {
    _thumbnailHideTimer?.cancel();
    _thumbnailHideTimer = Timer(const Duration(milliseconds: 520), () {
      if (mounted) {
        setState(() => _showThumbnails = false);
      }
    });
  }

  void _handleScroll(PointerScrollEvent event) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (shift) {
        if (event.scrollDelta.dx.abs() >= event.scrollDelta.dy.abs()) {
          _rotation += event.scrollDelta.dx * 0.01;
        } else {
          final delta = -event.scrollDelta.dy * 0.0018;
          _scale = (_scale * math.exp(delta)).clamp(0.2, 8.0);
        }
      } else {
        final delta = -event.scrollDelta.dy * 0.0018;
        _scale = (_scale * math.exp(delta)).clamp(0.2, 8.0);
      }
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (shift) {
        if (details.delta.dx.abs() >= details.delta.dy.abs()) {
          _rotation += details.delta.dx * 0.012;
        } else {
          _scale = (_scale * math.exp(-details.delta.dy * 0.009)).clamp(
            0.2,
            8.0,
          );
        }
      } else {
        _pan += details.delta;
      }
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _handleEsc();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.pageDown:
        _next(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.pageUp:
        _next(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyO:
        unawaited(_pickAndOpen());
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleEsc() {
    final now = DateTime.now();
    final secondPress =
        _lastEsc != null &&
        now.difference(_lastEsc!) < const Duration(milliseconds: 520);
    setState(() {
      _rotation = 0;
      if (secondPress) {
        _fillMode = !_fillMode;
        _pan = Offset.zero;
        _scale = 1;
        _lastEsc = null;
      } else {
        _lastEsc = now;
      }
    });
  }

  Future<void> _window(String method) async {
    try {
      await _windowChannel.invokeMethod<void>(method);
    } on MissingPluginException {
      if (method == 'close') {
        exit(0);
      }
    }
  }

  Future<void> _windowResize(String direction) async {
    try {
      await _windowChannel.invokeMethod<void>('resize', direction);
    } on MissingPluginException {
      // Non-Windows builds do not need the native resize bridge.
    }
  }

  @override
  Widget build(BuildContext context) {
    _log('ViewerPage build busy=$_busy hasLibrary=${_library != null} error=${_error ?? "<none>"}');
    return Focus(
      autofocus: true,
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _handleScroll(event);
              }
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              onHover: (event) => _handleHover(event, size),
              onExit: (_) {
                if (_library != null) {
                  setState(() => _showControls = false);
                }
                _scheduleThumbnailHide();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: _handlePanUpdate,
                onDoubleTap: () => setState(() => _fillMode = !_fillMode),
                child: Scaffold(
                  backgroundColor: Platform.isMacOS && _library != null
                      ? Colors.transparent
                      : const Color(0xff080a0d),
                  body: Stack(
                    children: [
                      Positioned.fill(child: _buildImageStage()),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _buildDragBand(),
                      ),
                      _buildResizeHandles(),
                      _buildWindowControls(),
                      _buildThumbnailRail(),
                      if (_busy)
                        const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      if (_library == null && !_busy) _buildEmptyState(),
                      if (_error != null) _buildError(),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildImageStage() {
    final library = _library;
    if (library == null || library.items.isEmpty) {
      return const SizedBox.shrink();
    }

    return FutureBuilder<MaterializedImage>(
      future: _materialize(_index),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _log('stage FutureBuilder error: ${snapshot.error}\n${snapshot.stackTrace}');
          return Center(child: _GlassText(text: '${snapshot.error}'));
        }
        final image = snapshot.data;
        if (image == null) {
          return const SizedBox.shrink();
        }

        if (Platform.isMacOS) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(_showNativeImage(image));
          });
          return const SizedBox.expand();
        }
        final entry = library.items[_index];
        return Transform.translate(
          offset: _pan,
          child: Transform.rotate(
            angle: _rotation,
            child: Transform.scale(
              scale: _scale,
              child: Image.file(
                File(image.path),
                key: ValueKey('${entry.id}:${image.path}'),
                width: double.infinity,
                height: double.infinity,
                fit: _fillMode ? BoxFit.cover : BoxFit.contain,
                filterQuality: FilterQuality.high,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) {
                  _log('stage Image.file error: path=${image.path} error=$error\n$stackTrace');
                  return ColoredBox(
                    color: const Color(0xff101318),
                    child: Center(child: _GlassText(text: '图片解码失败：$error')),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDragBand() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => unawaited(_window('drag')),
      child: const SizedBox(height: 60),
    );
  }

  Widget _buildResizeHandles() {
    if (!Platform.isWindows) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        _ResizeHandle(
          direction: 'left',
          cursor: SystemMouseCursors.resizeLeftRight,
          alignment: Alignment.centerLeft,
          width: 8,
          onResize: _windowResize,
        ),
        _ResizeHandle(
          direction: 'right',
          cursor: SystemMouseCursors.resizeLeftRight,
          alignment: Alignment.centerRight,
          width: 8,
          onResize: _windowResize,
        ),
        _ResizeHandle(
          direction: 'topLeft',
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
          alignment: Alignment.topLeft,
          width: 40,
          height: 40,
          onResize: _windowResize,
        ),
        _ResizeHandle(
          direction: 'topRight',
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
          alignment: Alignment.topRight,
          width: 40,
          height: 40,
          onResize: _windowResize,
        ),
        _ResizeHandle(
          direction: 'bottom',
          cursor: SystemMouseCursors.resizeUpDown,
          alignment: Alignment.bottomCenter,
          height: 8,
          onResize: _windowResize,
        ),
        _ResizeHandle(
          direction: 'bottomLeft',
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
          alignment: Alignment.bottomLeft,
          width: 16,
          height: 16,
          onResize: _windowResize,
        ),
        _ResizeHandle(
          direction: 'bottomRight',
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
          alignment: Alignment.bottomRight,
          width: 16,
          height: 16,
          onResize: _windowResize,
        ),
      ],
    );
  }

  Widget _buildWindowControls() {
    final isMac = Platform.isMacOS;
    final controlsVisible = _showControls || _library == null;
    final child = AnimatedOpacity(
      opacity: controlsVisible ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: IgnorePointer(
        ignoring: !controlsVisible,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xcc151a20),
            borderRadius: BorderRadius.circular(19),
            border: Border.all(color: Colors.white.withValues(alpha: .08)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: isMac
                ? [
                    _WindowIcon(
                      icon: Icons.folder_open,
                      onTap: () => unawaited(_pickAndOpen()),
                    ),
                    _WindowDot(
                      color: const Color(0xffff5f57),
                      onTap: () => _window('close'),
                    ),
                    _WindowDot(
                      color: const Color(0xffffbd2e),
                      onTap: () => _window('minimize'),
                    ),
                    _WindowDot(
                      color: const Color(0xff28c840),
                      onTap: () => _window('maximize'),
                    ),
                  ]
                : [
                    _WindowIcon(
                      icon: Icons.folder_open,
                      onTap: () => unawaited(_pickAndOpen()),
                    ),
                    _WindowIcon(
                      icon: Icons.remove,
                      onTap: () => _window('minimize'),
                    ),
                    _WindowIcon(
                      icon: Icons.crop_square,
                      onTap: () => _window('maximize'),
                    ),
                    _WindowIcon(
                      icon: Icons.close,
                      onTap: () => _window('close'),
                      danger: true,
                    ),
                  ],
          ),
        ),
      ),
    );

    return Positioned(
      top: 12,
      left: isMac ? 14 : null,
      right: isMac ? null : 14,
      child: child,
    );
  }

  Widget _buildThumbnailRail() {
    final library = _library;
    if (library == null || library.items.length <= 1) {
      return const SizedBox.shrink();
    }

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: 42,
      right: 42,
      bottom: _showThumbnails ? 22 : -132,
      height: 116,
      child: MouseRegion(
        onEnter: (_) => _showThumbnailRail(),
        onHover: (_) => _showThumbnailRail(),
        onExit: (_) => _scheduleThumbnailHide(),
        child: AnimatedOpacity(
          opacity: _showThumbnails ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xd611151a),
              borderRadius: BorderRadius.circular(22),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x8a000000),
                  blurRadius: 32,
                  offset: Offset(0, 18),
                ),
              ],
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _showThumbnailRail(),
              onHorizontalDragUpdate: (details) {
                if (!_thumbnailController.hasClients) return;
                _showThumbnailRail();
                final nextOffset =
                    (_thumbnailController.offset - details.delta.dx).clamp(
                      0.0,
                      _thumbnailController.position.maxScrollExtent,
                    );
                _thumbnailController.jumpTo(nextOffset);
              },
              onHorizontalDragEnd: (_) => _scheduleThumbnailHide(),
              onHorizontalDragCancel: _scheduleThumbnailHide,
              child: ScrollConfiguration(
                behavior: const _ThumbnailScrollBehavior(),
                child: ListView.builder(
                  controller: _thumbnailController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: library.items.length,
                  itemBuilder: (context, index) {
                    return _ThumbTile(
                      title: library.items[index].title,
                      selected: index == _index,
                      future: _materialize(index),
                      onTap: () => _switchTo(index),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: GestureDetector(
        onTap: _pickAndOpen,
        child: const _GlassText(text: '按 O 或点击这里打开图片、sssp、zip/cbr'),
      ),
    );
  }

  Widget _buildError() {
    return Positioned(
      left: 24,
      right: 24,
      bottom: 24,
      child: _GlassText(text: _error!),
    );
  }

  static String _join(String first, String second) {
    return '$first${Platform.pathSeparator}$second';
  }
}

class _ThumbnailScrollBehavior extends MaterialScrollBehavior {
  const _ThumbnailScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

class _ThumbTile extends StatelessWidget {
  const _ThumbTile({
    required this.title,
    required this.selected,
    required this.future,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final Future<MaterializedImage> future;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Tooltip(
        message: title,
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 92,
            height: 92,
            padding: EdgeInsets.all(selected ? 3 : 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: selected
                    ? const Color(0xff24d2b0)
                    : Colors.white.withValues(alpha: .10),
                width: selected ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: FutureBuilder<MaterializedImage>(
                future: future,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    _log('thumb FutureBuilder error: title=$title error=${snapshot.error}\n${snapshot.stackTrace}');
                  }
                  final image = snapshot.data;
                  if (image == null) {
                    return const ColoredBox(
                      color: Color(0xff20262d),
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  if (Platform.isMacOS) {
                    return const ColoredBox(color: Color(0x3310151b));
                  }
                  return Image.file(
                    File(image.previewPath ?? image.path),
                    fit: BoxFit.cover,
                    cacheWidth: 220,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (context, error, stackTrace) {
                      _log('thumb Image.file error: title=$title path=${image.previewPath ?? image.path} error=$error\n$stackTrace');
                      return const ColoredBox(color: Color(0xff20262d));
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.direction,
    required this.cursor,
    required this.alignment,
    required this.onResize,
    this.width,
    this.height,
  });

  final String direction;
  final MouseCursor cursor;
  final Alignment alignment;
  final double? width;
  final double? height;
  final Future<void> Function(String direction) onResize;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => unawaited(onResize(direction)),
            child: SizedBox(
              width: width ?? double.infinity,
              height: height ?? double.infinity,
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowIcon extends StatelessWidget {
  const _WindowIcon({
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: '',
        splashRadius: 18,
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        color: danger
            ? const Color(0xffff6b6b)
            : Colors.white.withValues(alpha: .88),
      ),
    );
  }
}

class _WindowDot extends StatelessWidget {
  const _WindowDot({required this.color, required this.onTap});

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 22,
        height: 24,
        alignment: Alignment.center,
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const SizedBox(width: 12, height: 12),
        ),
      ),
    );
  }
}

class _GlassText extends StatelessWidget {
  const _GlassText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xd914181d),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, height: 1.35),
        ),
      ),
    );
  }
}
