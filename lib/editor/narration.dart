import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';

/// Graba la voz del micrófono (vía ffmpeg/dshow) a un archivo M4A.
class NarrationRecorder {
  NarrationRecorder(this.ffmpeg, this.micDevice);

  final Ffmpeg ffmpeg;
  final String micDevice;

  Process? _proc;
  String? _path;
  Future<int>? _exit;
  final _log = StringBuffer();

  bool get isRecording => _proc != null;

  /// Inicia la grabación en [dir]. Devuelve la ruta del archivo.
  Future<String> start(String dir) async {
    await Directory(dir).create(recursive: true);
    final path = p.join(dir, 'narracion_${DateTime.now().millisecondsSinceEpoch}.m4a');
    final proc = await Process.start(ffmpeg.path, [
      '-y', '-hide_banner', '-loglevel', 'info',
      '-f', 'dshow', '-thread_queue_size', '1024', '-i', 'audio=$micDevice',
      '-c:a', 'aac', '-b:a', '160k', '-ar', '48000',
      path,
    ]);
    final ready = Completer<bool>();
    proc.stdout.transform(utf8.decoder).listen((_) {});
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _log.writeln(line);
      if (!ready.isCompleted &&
          (line.contains('Press [q] to stop') || line.startsWith('size=') || line.startsWith('Output #0'))) {
        ready.complete(true);
      }
    });
    _exit = proc.exitCode.then((c) {
      if (!ready.isCompleted) ready.complete(false);
      return c;
    });
    final ok = await ready.future.timeout(const Duration(seconds: 6), onTimeout: () => false);
    if (!ok) {
      proc.kill();
      final lines = _log.toString().trim().split('\n');
      throw Exception('No se pudo abrir el micrófono:\n${lines.skip(lines.length > 4 ? lines.length - 4 : 0).join('\n')}');
    }
    _proc = proc;
    _path = path;
    return path;
  }

  /// Detiene la grabación y devuelve (ruta, duración en segundos).
  Future<(String, double)> stop() async {
    final proc = _proc;
    final path = _path;
    _proc = null;
    _path = null;
    if (proc == null || path == null) throw StateError('No hay grabación');
    try {
      proc.stdin.write('q');
      await proc.stdin.flush();
    } catch (_) {}
    await (_exit ?? Future.value(0)).timeout(const Duration(seconds: 8), onTimeout: () {
      proc.kill();
      return -1;
    });
    final d = await ffmpeg.probeDuration(path);
    return (path, (d?.inMilliseconds ?? 0) / 1000);
  }

  Future<void> cancel() async {
    final proc = _proc;
    final path = _path;
    _proc = null;
    _path = null;
    if (proc != null) {
      try {
        proc.stdin.write('q');
        await proc.stdin.flush();
      } catch (_) {}
      await (_exit ?? Future.value(0)).timeout(const Duration(seconds: 5), onTimeout: () {
        proc.kill();
        return -1;
      });
    }
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }
}
