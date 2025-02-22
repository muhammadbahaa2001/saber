import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:saber/components/canvas/_canvas_background_painter.dart';
import 'package:saber/components/canvas/_editor_image.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:worker_manager/worker_manager.dart';

class EditorCoreInfo {
  /// The version of the file format.
  /// Increment this if earlier versions of the app can't satisfiably read the file.
  static const int sbnVersion = 11;
  bool readOnly = false;
  bool readOnlyBecauseOfVersion = false;

  String filePath;

  int nextImageId;
  Color? backgroundColor;
  CanvasBackgroundPattern backgroundPattern;
  int lineHeight;
  List<EditorPage> pages;

  /// Stores the current page index so that it can be restored when the file is reloaded.
  int? initialPageIndex;

  static final empty = EditorCoreInfo._(
    filePath: '',
    readOnly: true,
    readOnlyBecauseOfVersion: false,
    nextImageId: 0,
    backgroundColor: null,
    backgroundPattern: CanvasBackgroundPattern.none,
    lineHeight: Prefs.lastLineHeight.value,
    pages: [],
    initialPageIndex: null,
  )
    .._migrateOldStrokesAndImages(
      strokesJson: null,
      imagesJson: null,
      assets: const [],
      onlyFirstPage: true,
    );

  bool get isEmpty => pages.every((EditorPage page) => page.isEmpty);
  bool get isNotEmpty => !isEmpty;

  EditorCoreInfo({
    required this.filePath,
    this.readOnly = true, // default to read-only, until it's loaded with [loadFromFilePath]
  }):
        nextImageId = 0,
        backgroundPattern = Prefs.lastBackgroundPattern.value,
        lineHeight = Prefs.lastLineHeight.value,
        pages = [];

  EditorCoreInfo._({
    required this.filePath,
    required this.readOnly,
    required this.readOnlyBecauseOfVersion,
    required this.nextImageId,
    this.backgroundColor,
    required this.backgroundPattern,
    required this.lineHeight,
    required this.pages,
    required this.initialPageIndex,
  }) {
    _handleEmptyImageIds();
  }

  factory EditorCoreInfo.fromJson(Map<String, dynamic> json, {
    required String filePath,
    required bool readOnly,
    required bool onlyFirstPage,
  }) {
    bool readOnlyBecauseOfVersion = (json['v'] as int? ?? 0) > sbnVersion;
    readOnly = readOnly || readOnlyBecauseOfVersion;

    List<Uint8List>? assets = (json['a'] as List<dynamic>?)
        ?.map((base64) => base64Decode(base64 as String))
        .toList();

    return EditorCoreInfo._(
      filePath: filePath,
      readOnly: readOnly,
      readOnlyBecauseOfVersion: readOnlyBecauseOfVersion,
      nextImageId: json['ni'] as int? ?? 0,
      backgroundColor: json['b'] != null ? Color(json['b'] as int) : null,
      backgroundPattern: (){
        final String? pattern = json['p'] as String?;
        for (CanvasBackgroundPattern p in CanvasBackgroundPattern.values) {
          if (p.name == pattern) return p;
        }
        return CanvasBackgroundPattern.none;
      }(),
      lineHeight: json['l'] as int? ?? Prefs.lastLineHeight.value,
      pages: _parsePagesJson(
        json['z'] as List?,
        assets: assets,
        readOnly: readOnly,
        onlyFirstPage: onlyFirstPage,
      ),
      initialPageIndex: json['c'] as int?,
    )
      .._migrateOldStrokesAndImages(
        strokesJson: json['s'] as List?,
        imagesJson: json['i'] as List?,
        assets: assets,
        fallbackPageWidth: json['w'] as double?,
        fallbackPageHeight: json['h'] as double?,
        onlyFirstPage: onlyFirstPage,
      )
      .._sortStrokes();
  }
  /// Old json format is just a list of strokes
  EditorCoreInfo.fromOldJson(List<dynamic> json, {
    required this.filePath,
    this.readOnly = false,
    required bool onlyFirstPage,
  }): nextImageId = 0,
      backgroundPattern = CanvasBackgroundPattern.none,
      lineHeight = Prefs.lastLineHeight.value,
      pages = [] {
    _migrateOldStrokesAndImages(
      strokesJson: json,
      imagesJson: null,
      assets: null,
      onlyFirstPage: onlyFirstPage,
    );
    _sortStrokes();
  }

  static List<EditorPage> _parsePagesJson(List<dynamic>? pages, {
    required List<Uint8List>? assets,
    required bool readOnly,
    required bool onlyFirstPage,
  }) {
    if (pages == null || pages.isEmpty) return [];
    if (pages[0] is List) { // old format (list of [width, height])
      return pages
        .take(onlyFirstPage ? 1 : pages.length)
        .map((dynamic page) => EditorPage(
          width: page[0] as double?,
          height: page[1] as double?,
        ))
        .toList();
    } else {
      return pages
        .take(onlyFirstPage ? 1 : pages.length)
        .map((dynamic page) => EditorPage.fromJson(
          page as Map<String, dynamic>,
          assets: assets ?? const [],
          readOnly: readOnly,
        ))
        .toList();
    }
  }

  void _handleEmptyImageIds() {
    for (EditorPage page in pages) {
      for (EditorImage image in page.images) {
        if (image.id == -1) image.id = nextImageId++;
      }
    }
  }

  /// Migrates from fileVersion 7 to 8.
  /// In version 8, strokes and images are stored in their respective pages.
  ///
  /// Also creates a page if there are no pages.
  void _migrateOldStrokesAndImages({
    required List<dynamic>? strokesJson,
    required List<dynamic>? imagesJson,
    required List<Uint8List>? assets,
    double? fallbackPageWidth,
    double? fallbackPageHeight,
    required bool onlyFirstPage,
  }) {
    if (strokesJson != null) {
      final strokes = EditorPage.parseStrokesJson(
        strokesJson,
        onlyFirstPage: onlyFirstPage,
      );
      for (Stroke stroke in strokes) {
        if (onlyFirstPage) assert(stroke.pageIndex == 0);
        while (stroke.pageIndex >= pages.length) {
          pages.add(EditorPage(width: fallbackPageWidth, height: fallbackPageHeight));
        }
        pages[stroke.pageIndex].insertStroke(stroke);
      }
    }

    if (imagesJson != null) {
      final images = EditorPage.parseImagesJson(
        imagesJson,
        assets: assets ?? const [],
        isThumbnail: readOnly,
        onlyFirstPage: onlyFirstPage,
      );
      for (EditorImage image in images) {
        if (onlyFirstPage) assert(image.pageIndex == 0);
        while (image.pageIndex >= pages.length) {
          pages.add(EditorPage(width: fallbackPageWidth, height: fallbackPageHeight));
        }
        pages[image.pageIndex].images.add(image);
      }
    }

    // add a page if there are no pages,
    // or if the last page is not empty
    if (pages.isEmpty || pages.last.isNotEmpty && !onlyFirstPage) {
      pages.add(EditorPage(width: fallbackPageWidth, height: fallbackPageHeight));
    }
  }

  void _sortStrokes() {
    for (EditorPage page in pages) {
      page.sortStrokes();
    }
  }

  static Future<EditorCoreInfo> loadFromFilePath(String path, {
    bool readOnly = false,
    bool onlyFirstPage = false,
  }) async {
    String? jsonString = await FileManager.readFile(path + Editor.extension);
    if (jsonString == null) return EditorCoreInfo(filePath: path, readOnly: readOnly);

    return loadFromFileContents(
      jsonString,
      path: path,
      readOnly: readOnly,
      onlyFirstPage: onlyFirstPage,
    );
  }

  @visibleForTesting
  static Future<EditorCoreInfo> loadFromFileContents(String jsonString, {
    required String path,
    required bool readOnly,
    required bool onlyFirstPage,
    bool alwaysUseIsolate = false,
  }) async {
    EditorCoreInfo coreInfo;
    try {
      if (jsonString.length < 2 * 1024 * 1024 && !alwaysUseIsolate) { // 2 MB
        // if the file is small, just use the main isolate
        coreInfo = _loadFromFileIsolate(
          jsonString,
          path,
          readOnly,
          onlyFirstPage,
        );
      } else {
        coreInfo = await workerManager.execute(
          () => _loadFromFileIsolate(jsonString, path, readOnly, onlyFirstPage),
          priority: WorkPriority.veryHigh, // less important than [WorkPriority.immediately]
        );
      }
    } catch (e) {
      if (kDebugMode) {
        rethrow;
      } else {
        coreInfo = EditorCoreInfo(filePath: path, readOnly: readOnly);
      }
    }

    // now that we're back on the main thread,
    // we can parse the images
    for (final page in coreInfo.pages) {
      for (final image in page.images) {
        await image.getImage(pageSize: page.size);
      }
      page.backgroundImage?.getImage(pageSize: page.size);
    }

    return coreInfo;
  }

  static EditorCoreInfo _loadFromFileIsolate(
      String jsonString,
      String path,
      bool readOnly,
      bool onlyFirstPage,
  ) {
    final dynamic json;
    try {
      json = jsonDecode(jsonString);
    } catch (e) {
      if (kDebugMode) print('Failed to parse json from $path: $e');
      rethrow;
    }

    if (json == null) {
      throw Exception('Failed to parse json from $path');
    } else if (json is List) { // old format
      return EditorCoreInfo.fromOldJson(
        json,
        filePath: path,
        readOnly: readOnly,
        onlyFirstPage: onlyFirstPage,
      );
    } else {
      return EditorCoreInfo.fromJson(
        json as Map<String, dynamic>,
        filePath: path,
        readOnly: readOnly,
        onlyFirstPage: onlyFirstPage,
      );
    }
  }

  Map<String, dynamic> toJson() {
    /// This will be populated in various [toJson] methods.
    final List<Uint8List> assets = [];

    final json = {
      'v': sbnVersion,
      'ni': nextImageId,
      'b': backgroundColor?.value,
      'p': backgroundPattern.name,
      'l': lineHeight,
      'z': pages.map((EditorPage page) => page.toJson(assets)).toList(),
      'c': initialPageIndex,
    };

    json['a'] = assets.map((Uint8List asset) => base64Encode(asset)).toList();

    return json;
  }

  EditorCoreInfo copyWith({
    String? filePath,
    bool? readOnly,
    bool? readOnlyBecauseOfVersion,
    int? nextImageId,
    Color? backgroundColor,
    CanvasBackgroundPattern? backgroundPattern,
    int? lineHeight,
    QuillController? quillController,
    List<EditorPage>? pages,
  }) {
    return EditorCoreInfo._(
      filePath: filePath ?? this.filePath,
      readOnly: readOnly ?? this.readOnly,
      readOnlyBecauseOfVersion: readOnlyBecauseOfVersion ?? this.readOnlyBecauseOfVersion,
      nextImageId: nextImageId ?? this.nextImageId,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundPattern: backgroundPattern ?? this.backgroundPattern,
      lineHeight: lineHeight ?? this.lineHeight,
      pages: pages ?? this.pages,
      initialPageIndex: initialPageIndex,
    );
  }
}
