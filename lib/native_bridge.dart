import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NativeStringFn = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _DartStringFn = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _NativePickFn = ffi.Pointer<Utf8> Function();
typedef _DartPickFn = ffi.Pointer<Utf8> Function();
typedef _NativeFreeFn = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _DartFreeFn = void Function(ffi.Pointer<Utf8>);

class PicsssCore {
  PicsssCore._() {
    final library = _loadLibrary();
    _openPath = library.lookupFunction<_NativeStringFn, _DartStringFn>(
      'picsss_open_path',
    );
    _materializeItem = library.lookupFunction<_NativeStringFn, _DartStringFn>(
      'picsss_materialize_item',
    );
    _pickPath = library.lookupFunction<_NativePickFn, _DartPickFn>(
      'picsss_pick_path',
    );
    _freeString = library.lookupFunction<_NativeFreeFn, _DartFreeFn>(
      'picsss_free_string',
    );
  }

  static final PicsssCore instance = PicsssCore._();

  late final _DartStringFn _openPath;
  late final _DartStringFn _materializeItem;
  late final _DartPickFn _pickPath;
  late final _DartFreeFn _freeString;

  ImageLibrary openPath(String path) {
    final data = _callWithString(_openPath, path);
    return ImageLibrary.fromJson(data);
  }

  MaterializedImage materialize(ImageEntry entry) {
    final data = _callWithString(_materializeItem, jsonEncode(entry.raw));
    return MaterializedImage.fromJson(data);
  }

  String? pickPath() {
    final data = _callNoArgs(_pickPath, allowCancel: true);
    return data == null ? null : data['path'] as String?;
  }

  Map<String, dynamic> _callWithString(_DartStringFn function, String input) {
    stderr.writeln('[picSSS] ffi call input: $input');
    final nativeInput = input.toNativeUtf8();
    try {
      final output = function(nativeInput);
      return _decodeAndFree(output);
    } finally {
      calloc.free(nativeInput);
    }
  }

  Map<String, dynamic>? _callNoArgs(
    _DartPickFn function, {
    bool allowCancel = false,
  }) {
    stderr.writeln('[picSSS] ffi call no args');
    final output = function();
    try {
      return _decodeAndFree(output);
    } on PicsssException catch (error) {
      if (allowCancel && error.message == '没有选择文件') {
        return null;
      }
      rethrow;
    }
  }

  Map<String, dynamic> _decodeAndFree(ffi.Pointer<Utf8> output) {
    if (output == ffi.nullptr) {
      throw PicsssException('Rust 核心没有返回内容');
    }
    try {
      final text = output.toDartString();
      stderr.writeln('[picSSS] ffi response: $text');
      final response = jsonDecode(text) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw PicsssException((response['error'] as String?) ?? '未知错误');
      }
      return Map<String, dynamic>.from(response['data'] as Map);
    } finally {
      _freeString(output);
    }
  }

  static ffi.DynamicLibrary _loadLibrary() {
    final cached = _cachedLibrary;
    if (cached != null) {
      return cached;
    }

    final name = _libraryName();
    final envPath =
        Platform.environment['PICSSS_CORE_DLL'] ??
        Platform.environment['PICSSS_CORE_PATH'];
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final current = Directory.current.path;
    final candidates = <String>[
      if (envPath != null && envPath.isNotEmpty) envPath,
      _join([executableDir, name]),
      _join([current, 'rust', 'target', 'debug', name]),
      _join([current, 'rust', 'target', 'release', name]),
      _join([current, '..', '..', '..', 'rust', 'target', 'debug', name]),
      _join([current, '..', '..', '..', 'rust', 'target', 'release', name]),
    ];

    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        _cachedLibrary = ffi.DynamicLibrary.open(file.absolute.path);
        return _cachedLibrary!;
      }
    }

    throw PicsssException('找不到 Rust 核心库，请先构建 rust/target/debug/$name');
  }

  static ffi.DynamicLibrary? _cachedLibrary;

  static String _libraryName() {
    if (Platform.isWindows) {
      return 'picsss_core.dll';
    }
    if (Platform.isMacOS) {
      return 'libpicsss_core.dylib';
    }
    return 'libpicsss_core.so';
  }

  static String _join(List<String> parts) {
    return parts.where((part) => part.isNotEmpty).join(Platform.pathSeparator);
  }
}

class PicsssException implements Exception {
  PicsssException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ImageLibrary {
  ImageLibrary({
    required this.root,
    required this.title,
    required this.kind,
    required this.selectedIndex,
    required this.items,
    required this.notes,
  });

  factory ImageLibrary.fromJson(Map<String, dynamic> json) {
    return ImageLibrary(
      root: json['root'] as String? ?? '',
      title: json['title'] as String? ?? 'picSSS',
      kind: json['kind'] as String? ?? 'folder',
      selectedIndex: json['selectedIndex'] as int? ?? 0,
      items: (json['items'] as List? ?? const [])
          .map(
            (item) =>
                ImageEntry.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(),
      notes: (json['notes'] as List? ?? const [])
          .map((note) => '$note')
          .toList(),
    );
  }

  final String root;
  final String title;
  final String kind;
  final int selectedIndex;
  final List<ImageEntry> items;
  final List<String> notes;
}

class ImageEntry {
  ImageEntry({
    required this.raw,
    required this.id,
    required this.title,
    required this.kind,
    required this.format,
    required this.path,
    required this.previewPath,
    required this.width,
    required this.height,
    required this.sssp,
  });

  factory ImageEntry.fromJson(Map<String, dynamic> json) {
    return ImageEntry(
      raw: json,
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'image',
      kind: json['kind'] as String? ?? 'file',
      format: json['format'] as String? ?? '',
      path: json['path'] as String?,
      previewPath: json['previewPath'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      sssp: json['sssp'] == null
          ? null
          : SsspInfo.fromJson(Map<String, dynamic>.from(json['sssp'] as Map)),
    );
  }

  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final String kind;
  final String format;
  final String? path;
  final String? previewPath;
  final int? width;
  final int? height;
  final SsspInfo? sssp;

  bool get isArchive => kind == 'archive';
}

class SsspInfo {
  SsspInfo({
    required this.layerCount,
    required this.visibleLayerCount,
    required this.adjustmentLayerCount,
    required this.unsupportedEffectCount,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  factory SsspInfo.fromJson(Map<String, dynamic> json) {
    return SsspInfo(
      layerCount: json['layerCount'] as int? ?? 0,
      visibleLayerCount: json['visibleLayerCount'] as int? ?? 0,
      adjustmentLayerCount: json['adjustmentLayerCount'] as int? ?? 0,
      unsupportedEffectCount: json['unsupportedEffectCount'] as int? ?? 0,
      canvasWidth: json['canvasWidth'] as int?,
      canvasHeight: json['canvasHeight'] as int?,
    );
  }

  final int layerCount;
  final int visibleLayerCount;
  final int adjustmentLayerCount;
  final int unsupportedEffectCount;
  final int? canvasWidth;
  final int? canvasHeight;
}

class MaterializedImage {
  MaterializedImage({
    required this.path,
    required this.previewPath,
    required this.width,
    required this.height,
    required this.notes,
  });

  factory MaterializedImage.fromJson(Map<String, dynamic> json) {
    return MaterializedImage(
      path: json['path'] as String? ?? '',
      previewPath: json['previewPath'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      notes: (json['notes'] as List? ?? const [])
          .map((note) => '$note')
          .toList(),
    );
  }

  final String path;
  final String? previewPath;
  final int? width;
  final int? height;
  final List<String> notes;
}
