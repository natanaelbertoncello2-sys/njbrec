import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Resultado de una ejecución de ffmpeg.
class FfmpegResult {
  const FfmpegResult(this.exitCode, this.log);
  final int exitCode;
  final String log;
  bool get ok => exitCode == 0;

  /// Últimas líneas relevantes del log, útiles para mostrar errores.
  String get tail {
    final lines = log.trim().split('\n');
    return lines.skip(lines.length > 8 ? lines.length - 8 : 0).join('\n');
  }
}

/// Localiza y ejecuta ffmpeg.
class Ffmpeg {
  Ffmpeg._(this.path);

  final String path;

  static Ffmpeg? _instance;
  static Ffmpeg? get instance => _instance;

  /// Busca ffmpeg: ruta personalizada → junto al ejecutable → PATH.
  static Future<Ffmpeg?> locate({String customPath = ''}) async {
    final candidates = <String>[];
    if (customPath.trim().isNotEmpty) candidates.add(customPath.trim());
    final exeDir = p.dirname(Platform.resolvedExecutable);
    candidates.add(p.join(exeDir, 'ffmpeg.exe'));
    candidates.add(p.join(exeDir, 'ffmpeg', 'ffmpeg.exe'));
    // Durante el desarrollo (flutter run) también probamos windows/ffmpeg.
    candidates.add(p.join(Directory.current.path, 'windows', 'ffmpeg', 'ffmpeg.exe'));

    for (final c in candidates) {
      if (await File(c).exists()) {
        _instance = Ffmpeg._(c);
        return _instance;
      }
    }
    try {
      final r = await Process.run('where', ['ffmpeg']);
      if (r.exitCode == 0) {
        final first = (r.stdout as String)
            .split('\n')
            .map((e) => e.trim())
            .firstWhere((e) => e.isNotEmpty, orElse: () => '');
        if (first.isNotEmpty) {
          _instance = Ffmpeg._(first);
          return _instance;
        }
      }
    } catch (_) {}
    _instance = null;
    return null;
  }

  Future<String> version() async {
    final r = await Process.run(path, ['-version']);
    final out = (r.stdout as String).split('\n').first.trim();
    return out;
  }

  /// Dispositivos de audio DirectShow (micrófonos).
  Future<List<String>> listAudioInputs() async {
    final r = await Process.run(
      path,
      ['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final text = '${r.stderr}\n${r.stdout}';
    final re = RegExp(r'"([^"]+)"\s+\(audio\)');
    final devices = <String>[];
    for (final m in re.allMatches(text)) {
      final name = m.group(1)!;
      if (!devices.contains(name)) devices.add(name);
    }
    return devices;
  }

  /// Codificadores H.264 disponibles (software + aceleración por hardware).
  Future<List<String>> listH264Encoders() async {
    final r = await Process.run(path, ['-hide_banner', '-encoders']);
    final text = '${r.stdout}';
    final found = <String>['libx264'];
    for (final enc in ['h264_nvenc', 'h264_amf', 'h264_qsv']) {
      if (RegExp(r'\s' + enc + r'\s').hasMatch(text)) found.add(enc);
    }
    return found;
  }

  /// Duración de un archivo multimedia.
  Future<Duration?> probeDuration(String file) async {
    final r = await Process.run(path, ['-hide_banner', '-i', file]);
    final m = RegExp(r'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)')
        .firstMatch('${r.stderr}');
    if (m == null) return null;
    final frac = m.group(4)!;
    final ms = (int.parse(frac) * 1000 / (pow10(frac.length))).round();
    return Duration(
      hours: int.parse(m.group(1)!),
      minutes: int.parse(m.group(2)!),
      seconds: int.parse(m.group(3)!),
      milliseconds: ms,
    );
  }

  static int pow10(int n) {
    var v = 1;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }

  /// Ejecuta ffmpeg hasta que termine. [onProgress] recibe el tiempo procesado.
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(Duration processed)? onProgress,
  }) async {
    final fullArgs = <String>[
      '-y',
      '-hide_banner',
      '-nostdin',
      if (onProgress != null) ...['-progress', 'pipe:1', '-nostats'],
      ...args,
    ];
    final proc = await Process.start(path, fullArgs);
    final log = StringBuffer();
    final stderrDone = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(log.writeln)
        .asFuture<void>();
    final stdoutDone = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (onProgress != null && line.startsWith('out_time_us=')) {
        final us = int.tryParse(line.substring('out_time_us='.length).trim());
        if (us != null && us >= 0) onProgress(Duration(microseconds: us));
      }
    }).asFuture<void>();
    final code = await proc.exitCode;
    await Future.wait([stderrDone, stdoutDone]);
    return FfmpegResult(code, log.toString());
  }

  /// Genera una miniatura JPG de [video] en [out].
  Future<bool> thumbnail(String video, String out, {Duration at = const Duration(seconds: 1), int width = 480}) async {
    final r = await run([
      '-ss',
      formatDuration(at),
      '-i',
      video,
      '-frames:v',
      '1',
      '-vf',
      'scale=$width:-2',
      '-q:v',
      '4',
      out,
    ]);
    return r.ok && await File(out).exists();
  }

  static String formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final ms = d.inMilliseconds % 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(h)}:${two(m)}:${two(s)}.${ms.toString().padLeft(3, '0')}';
  }
}
