import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Tramo del video original que se elimina.
class CutRange {
  CutRange(this.start, this.end);
  double start;
  double end;
  double get length => math.max(0, end - start);

  Map<String, dynamic> toJson() => {'start': start, 'end': end};
  static CutRange fromJson(Map<String, dynamic> j) =>
      CutRange((j['start'] as num).toDouble(), (j['end'] as num).toDouble());
}

enum ClipKind { text, image, audio }

abstract class Clip {
  Clip({required this.id, required this.start, required this.end});
  final String id;

  /// Tiempos en la línea de tiempo del video original (segundos).
  double start;
  double end;
  double get duration => math.max(0.05, end - start);
  ClipKind get kind;
  String get label;
  Map<String, dynamic> toJson();
}

class TextClip extends Clip {
  TextClip({
    required super.id,
    required super.start,
    required super.end,
    this.text = 'Texto',
    this.x = 0.5,
    this.y = 0.85,
    this.size = 0.07,
    this.color = Colors.white,
    this.bgColor = const Color(0x99000000),
    this.bold = true,
    this.showBg = true,
    this.fade = true,
  });

  String text;
  double x; // centro, 0..1
  double y;
  double size; // fracción de la altura del video
  Color color;
  Color bgColor;
  bool bold;
  bool showBg;
  bool fade;

  @override
  ClipKind get kind => ClipKind.text;
  @override
  String get label => text.split('\n').first;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'text',
        'id': id,
        'start': start,
        'end': end,
        'text': text,
        'x': x,
        'y': y,
        'size': size,
        'color': color.toARGB32(),
        'bgColor': bgColor.toARGB32(),
        'bold': bold,
        'showBg': showBg,
        'fade': fade,
      };

  static TextClip fromJson(Map<String, dynamic> j) => TextClip(
        id: j['id'] as String,
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        text: j['text'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        size: (j['size'] as num).toDouble(),
        color: Color(j['color'] as int),
        bgColor: Color(j['bgColor'] as int),
        bold: j['bold'] as bool,
        showBg: j['showBg'] as bool,
        fade: j['fade'] as bool? ?? true,
      );
}

class ImageClip extends Clip {
  ImageClip({
    required super.id,
    required super.start,
    required super.end,
    required this.path,
    this.x = 0.88,
    this.y = 0.1,
    this.width = 0.18,
    this.opacity = 1.0,
  });

  String path;
  double x; // centro
  double y;
  double width; // fracción del ancho del video
  double opacity;

  @override
  ClipKind get kind => ClipKind.image;
  @override
  String get label => path.split(RegExp(r'[\\/]')).last;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'image',
        'id': id,
        'start': start,
        'end': end,
        'path': path,
        'x': x,
        'y': y,
        'width': width,
        'opacity': opacity,
      };

  static ImageClip fromJson(Map<String, dynamic> j) => ImageClip(
        id: j['id'] as String,
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        path: j['path'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        opacity: (j['opacity'] as num).toDouble(),
      );
}

enum AudioKind { narration, music }

class AudioClip extends Clip {
  AudioClip({
    required super.id,
    required super.start,
    required super.end,
    required this.path,
    required this.fileDuration,
    this.audioKind = AudioKind.music,
    this.offset = 0,
    this.volume = 1.0,
    this.fadeIn = 0,
    this.fadeOut = 0,
    String? name,
  }) : name = name ?? path.split(RegExp(r'[\\/]')).last;

  String path;
  String name;
  AudioKind audioKind;
  double fileDuration;
  double offset; // segundos dentro del archivo
  double volume;
  double fadeIn;
  double fadeOut;

  @override
  ClipKind get kind => ClipKind.audio;
  @override
  String get label => name;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'audio',
        'id': id,
        'start': start,
        'end': end,
        'path': path,
        'name': name,
        'audioKind': audioKind.name,
        'fileDuration': fileDuration,
        'offset': offset,
        'volume': volume,
        'fadeIn': fadeIn,
        'fadeOut': fadeOut,
      };

  static AudioClip fromJson(Map<String, dynamic> j) => AudioClip(
        id: j['id'] as String,
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        path: j['path'] as String,
        name: j['name'] as String?,
        audioKind: AudioKind.values.byName(j['audioKind'] as String),
        fileDuration: (j['fileDuration'] as num).toDouble(),
        offset: (j['offset'] as num).toDouble(),
        volume: (j['volume'] as num).toDouble(),
        fadeIn: (j['fadeIn'] as num).toDouble(),
        fadeOut: (j['fadeOut'] as num).toDouble(),
      );
}

/// Proyecto de edición: se guarda junto al video como `<video>.njbproj.json`.
class EditorProject {
  EditorProject({required this.source, required this.duration});

  final String source;
  double duration;
  final List<CutRange> cuts = [];
  final List<Clip> clips = [];
  double originalVolume = 1.0;
  bool muteOriginal = false;
  bool duckOriginal = true;
  bool fadeIn = false;
  bool fadeOut = false;

  Iterable<TextClip> get texts => clips.whereType<TextClip>();
  Iterable<ImageClip> get images => clips.whereType<ImageClip>();
  Iterable<AudioClip> get audios => clips.whereType<AudioClip>();

  bool get isEmpty =>
      cuts.isEmpty &&
      clips.isEmpty &&
      originalVolume == 1.0 &&
      !muteOriginal &&
      !fadeIn &&
      !fadeOut;

  /// Duración del resultado (sin los cortes).
  double get outputDuration =>
      math.max(0.1, duration - cuts.fold(0.0, (a, c) => a + c.length));

  /// Convierte un tiempo del original al tiempo de salida.
  double toOutput(double t) {
    var removed = 0.0;
    for (final c in cuts) {
      if (c.end <= t) {
        removed += c.length;
      } else if (c.start < t) {
        removed += t - c.start;
      }
    }
    return t - removed;
  }

  bool isCut(double t) => cuts.any((c) => t >= c.start && t < c.end);

  /// Si [t] cae en un corte devuelve el fin del corte, si no [t].
  double skipCut(double t) {
    for (final c in cuts) {
      if (t >= c.start && t < c.end) return c.end;
    }
    return t;
  }

  /// Agrega un corte y fusiona los solapados.
  void addCut(double start, double end) {
    start = start.clamp(0, duration);
    end = end.clamp(0, duration);
    if (end - start < 0.05) return;
    final merged = CutRange(start, end);
    cuts.removeWhere((c) {
      if (c.end < merged.start || c.start > merged.end) return false;
      merged.start = math.min(merged.start, c.start);
      merged.end = math.max(merged.end, c.end);
      return true;
    });
    cuts.add(merged);
    cuts.sort((a, b) => a.start.compareTo(b.start));
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'source': source,
        'duration': duration,
        'cuts': cuts.map((c) => c.toJson()).toList(),
        'clips': clips.map((c) => c.toJson()).toList(),
        'originalVolume': originalVolume,
        'muteOriginal': muteOriginal,
        'duckOriginal': duckOriginal,
        'fadeIn': fadeIn,
        'fadeOut': fadeOut,
      };

  static EditorProject fromJson(Map<String, dynamic> j) {
    final p = EditorProject(
      source: j['source'] as String,
      duration: (j['duration'] as num).toDouble(),
    );
    for (final c in (j['cuts'] as List)) {
      p.cuts.add(CutRange.fromJson(c as Map<String, dynamic>));
    }
    for (final c in (j['clips'] as List)) {
      final m = c as Map<String, dynamic>;
      switch (m['kind']) {
        case 'text':
          p.clips.add(TextClip.fromJson(m));
        case 'image':
          p.clips.add(ImageClip.fromJson(m));
        case 'audio':
          p.clips.add(AudioClip.fromJson(m));
      }
    }
    p.originalVolume = (j['originalVolume'] as num).toDouble();
    p.muteOriginal = j['muteOriginal'] as bool;
    p.duckOriginal = j['duckOriginal'] as bool;
    p.fadeIn = j['fadeIn'] as bool;
    p.fadeOut = j['fadeOut'] as bool;
    return p;
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static EditorProject decode(String text) =>
      fromJson(jsonDecode(text) as Map<String, dynamic>);

  /// Copia profunda (para deshacer/rehacer).
  EditorProject clone() => decode(encode());

  static String projectPathFor(String video) => '$video.njbproj.json';

  Future<void> save() async {
    await File(projectPathFor(source)).writeAsString(encode());
  }

  static Future<EditorProject?> tryLoad(String video) async {
    final f = File(projectPathFor(video));
    if (!await f.exists()) return null;
    try {
      return decode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }
}

String newClipId() =>
    '${DateTime.now().microsecondsSinceEpoch}${math.Random().nextInt(9999)}';
