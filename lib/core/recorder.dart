import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ffmpeg.dart';
import 'native_bridge.dart';
import 'settings.dart';

enum RecState { idle, countdown, recording, paused, processing }

/// Un tramo de grabación (entre pausas).
class _Segment {
  _Segment(this.index, this.video, this.systemWav);
  final int index;
  final String video;
  final String? systemWav;
  bool hasMic = false;
}

/// Motor de grabación: pantalla + micrófono (ffmpeg) + audio del sistema
/// (WASAPI loopback nativo). La pausa se implementa cortando en segmentos
/// que se unen al finalizar.
class Recorder extends ChangeNotifier {
  Recorder(this.settings);

  final AppSettings settings;

  RecState _state = RecState.idle;
  RecState get state => _state;
  bool get isActive =>
      _state == RecState.recording || _state == RecState.paused;
  bool get isBusy => _state != RecState.idle;

  int countdown = 0;
  Duration elapsed = Duration.zero;
  String? lastError;
  String? lastOutputFile;
  String processingLabel = '';
  double processingProgress = 0; // 0..1, -1 indeterminado

  final List<_Segment> _segments = [];
  Process? _ffmpeg;
  Future<void>? _ffmpegExit;
  StringBuffer _ffmpegLog = StringBuffer();
  Directory? _sessionDir;
  Timer? _ticker;
  Timer? _countdownTimer;
  final Stopwatch _stopwatch = Stopwatch();
  bool _cancelCountdown = false;
  ScreenLayout? _layout;

  /// Se dispara cuando una grabación quedó lista en disco.
  final StreamController<String> _finished = StreamController.broadcast();
  Stream<String> get onFinished => _finished.stream;

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  void _setState(RecState s) {
    _state = s;
    notifyListeners();
  }

  // ---------------------------------------------------------------- inicio

  Future<void> start() async {
    if (_state != RecState.idle) return;
    lastError = null;
    final ff = Ffmpeg.instance;
    if (ff == null) {
      lastError = 'No se encontró ffmpeg. Revisá la configuración.';
      notifyListeners();
      return;
    }

    _layout = await NativeBridge.listMonitors();

    // Cuenta regresiva.
    _cancelCountdown = false;
    if (settings.countdownSeconds > 0) {
      countdown = settings.countdownSeconds;
      _setState(RecState.countdown);
      final done = Completer<void>();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        countdown--;
        notifyListeners();
        if (countdown <= 0) {
          t.cancel();
          done.complete();
        }
      });
      await done.future;
      if (_cancelCountdown) {
        _setState(RecState.idle);
        return;
      }
    }

    final tmp = await getTemporaryDirectory();
    _sessionDir = Directory(p.join(
        tmp.path, 'njbrec', 'session_${DateTime.now().millisecondsSinceEpoch}'));
    await _sessionDir!.create(recursive: true);
    _segments.clear();
    elapsed = Duration.zero;
    _stopwatch
      ..reset()
      ..start();

    final ok = await _startSegment();
    if (!ok) {
      _stopwatch.stop();
      _setState(RecState.idle);
      return;
    }
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      elapsed = _stopwatch.elapsed;
      notifyListeners();
    });
    _setState(RecState.recording);
  }

  void cancelCountdown() {
    if (_state == RecState.countdown) {
      _cancelCountdown = true;
      _countdownTimer?.cancel();
      countdown = 0;
      _setState(RecState.idle);
    }
  }

  // ---------------------------------------------------------------- pausa

  Future<void> pause() async {
    if (_state != RecState.recording) return;
    _stopwatch.stop();
    await _stopSegment();
    _setState(RecState.paused);
  }

  Future<void> resume() async {
    if (_state != RecState.paused) return;
    final ok = await _startSegment();
    if (!ok) return;
    _stopwatch.start();
    _setState(RecState.recording);
  }

  Future<void> togglePause() => _state == RecState.paused ? resume() : pause();

  // ---------------------------------------------------------------- fin

  Future<void> stop() async {
    if (!isActive) return;
    _ticker?.cancel();
    _stopwatch.stop();
    elapsed = _stopwatch.elapsed;
    if (_state == RecState.recording) await _stopSegment();

    processingLabel = 'Procesando grabación…';
    processingProgress = -1;
    _setState(RecState.processing);
    try {
      final out = await _assemble();
      lastOutputFile = out;
      _finished.add(out);
    } catch (e) {
      lastError = 'Error al procesar la grabación: $e';
    } finally {
      _cleanupSession();
      _setState(RecState.idle);
    }
  }

  /// Descarta la grabación actual sin guardar.
  Future<void> discard() async {
    if (!isActive) return;
    _ticker?.cancel();
    _stopwatch.stop();
    if (_state == RecState.recording) await _stopSegment();
    _cleanupSession();
    _setState(RecState.idle);
  }

  void _cleanupSession() {
    final dir = _sessionDir;
    _sessionDir = null;
    _segments.clear();
    if (dir != null) {
      dir.delete(recursive: true).catchError((_) => dir);
    }
  }

  // ---------------------------------------------------------------- segmentos

  List<String> _captureArgs() {
    final s = settings;
    final layout = _layout!;
    int x, y, w, h;
    switch (s.captureMode) {
      case CaptureMode.desktop:
        x = layout.virtualRect.left.toInt();
        y = layout.virtualRect.top.toInt();
        w = layout.virtualRect.width.toInt();
        h = layout.virtualRect.height.toInt();
      case CaptureMode.monitor:
        final mons = layout.monitors;
        final m = mons.isEmpty
            ? null
            : mons[s.monitorIndex.clamp(0, mons.length - 1)];
        if (m == null) {
          x = layout.virtualRect.left.toInt();
          y = layout.virtualRect.top.toInt();
          w = layout.virtualRect.width.toInt();
          h = layout.virtualRect.height.toInt();
        } else {
          x = m.x;
          y = m.y;
          w = m.width;
          h = m.height;
        }
      case CaptureMode.region:
        x = s.regionX;
        y = s.regionY;
        w = s.regionW;
        h = s.regionH;
    }
    // Dimensiones pares (requisito de yuv420p).
    w -= w % 2;
    h -= h % 2;
    if (w < 16) w = 16;
    if (h < 16) h = 16;

    if (s.captureGpu) {
      // Desktop Duplication API (más eficiente). Solo monitor completo.
      final mons = layout.monitors;
      var idx = s.captureMode == CaptureMode.monitor ? s.monitorIndex : 0;
      if (s.captureMode != CaptureMode.monitor) {
        final primary = mons.indexWhere((m) => m.primary);
        if (primary >= 0) idx = primary;
      }
      return [
        '-f', 'lavfi', '-thread_queue_size', '1024',
        '-i',
        'ddagrab=output_idx=$idx:framerate=${s.fps}:draw_mouse=${s.captureCursor ? 1 : 0},hwdownload,format=bgra',
      ];
    }

    return [
      '-f', 'gdigrab',
      '-framerate', '${s.fps}',
      '-draw_mouse', s.captureCursor ? '1' : '0',
      '-offset_x', '$x',
      '-offset_y', '$y',
      '-video_size', '${w}x$h',
      '-thread_queue_size', '1024',
      '-i', 'desktop',
    ];
  }

  List<String> _encoderArgs() {
    final q = settings.quality.crf;
    switch (settings.encoder) {
      case 'h264_nvenc':
        return ['-c:v', 'h264_nvenc', '-preset', 'p4', '-rc', 'vbr', '-cq', '$q', '-b:v', '0'];
      case 'h264_amf':
        return ['-c:v', 'h264_amf', '-quality', 'balanced', '-rc', 'cqp', '-qp_i', '$q', '-qp_p', '$q'];
      case 'h264_qsv':
        return ['-c:v', 'h264_qsv', '-preset', 'veryfast', '-global_quality', '$q'];
      default:
        return ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '$q'];
    }
  }

  Future<bool> _startSegment() async {
    final ff = Ffmpeg.instance!;
    final s = settings;
    final idx = _segments.length;
    final video = p.join(_sessionDir!.path, 'seg_${idx.toString().padLeft(3, '0')}.mkv');
    final useMic = s.micEnabled && (s.micDevice?.isNotEmpty ?? false);
    final useSys = s.systemAudioEnabled;
    final sysWav = useSys
        ? p.join(_sessionDir!.path, 'sys_${idx.toString().padLeft(3, '0')}.wav')
        : null;

    final args = <String>[
      '-y', '-hide_banner', '-loglevel', 'info',
      ..._captureArgs(),
      if (useMic) ...[
        '-f', 'dshow', '-thread_queue_size', '1024',
        '-i', 'audio=${s.micDevice}',
      ],
      '-map', '0:v',
      if (useMic) ...['-map', '1:a'],
      ..._encoderArgs(),
      '-pix_fmt', 'yuv420p',
      '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
      '-r', '${s.fps}',
      if (useMic) ...[
        '-c:a', 'aac', '-b:a', '160k', '-ar', '48000',
        if (s.micVolume != 1.0) ...['-af', 'volume=${s.micVolume.toStringAsFixed(2)}'],
      ],
      video,
    ];

    _ffmpegLog = StringBuffer();
    final ready = Completer<bool>();
    try {
      _ffmpeg = await Process.start(ff.path, args);
    } catch (e) {
      lastError = 'No se pudo iniciar ffmpeg: $e';
      notifyListeners();
      return false;
    }
    final proc = _ffmpeg!;
    proc.stdout.transform(utf8.decoder).listen((_) {});
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _ffmpegLog.writeln(line);
      if (!ready.isCompleted &&
          (line.contains('Press [q] to stop') ||
              line.startsWith('frame=') ||
              line.startsWith('Output #0'))) {
        ready.complete(true);
      }
    });
    _ffmpegExit = proc.exitCode.then((code) {
      if (!ready.isCompleted) ready.complete(false);
      if (code != 0 && code != 255 && _state == RecState.recording) {
        // Falló en medio de la grabación.
        lastError = 'ffmpeg terminó inesperadamente:\n${_logTail()}';
        _ticker?.cancel();
        _stopwatch.stop();
        _cleanupSession();
        _setState(RecState.idle);
      }
    });

    final ok = await ready.future.timeout(const Duration(seconds: 6), onTimeout: () => false);
    if (!ok) {
      lastError = 'ffmpeg no pudo iniciar la captura:\n${_logTail()}';
      try {
        proc.kill();
      } catch (_) {}
      _ffmpeg = null;
      notifyListeners();
      return false;
    }

    final seg = _Segment(idx, video, sysWav)..hasMic = useMic;
    if (sysWav != null) {
      try {
        await NativeBridge.loopbackStart(sysWav);
      } catch (e) {
        // Seguimos sin audio del sistema.
        _segments.add(_Segment(idx, video, null)..hasMic = useMic);
        lastError = 'No se pudo capturar el audio del sistema: $e';
        notifyListeners();
        return true;
      }
    }
    _segments.add(seg);
    return true;
  }

  String _logTail() {
    final lines = _ffmpegLog.toString().trim().split('\n');
    return lines.skip(lines.length > 6 ? lines.length - 6 : 0).join('\n');
  }

  Future<void> _stopSegment() async {
    final proc = _ffmpeg;
    _ffmpeg = null;
    if (proc != null) {
      try {
        proc.stdin.write('q');
        await proc.stdin.flush();
      } catch (_) {}
      await (_ffmpegExit ?? Future<void>.value())
          .timeout(const Duration(seconds: 8), onTimeout: () {
        proc.kill();
      });
    }
    try {
      await NativeBridge.loopbackStop();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- ensamblado

  Future<String> _assemble() async {
    final ff = Ffmpeg.instance!;
    final s = settings;
    final dir = _sessionDir!;
    final pieces = <String>[];

    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      processingLabel = 'Mezclando audio (${i + 1}/${_segments.length})…';
      notifyListeners();
      final wav = seg.systemWav;
      final wavOk = wav != null &&
          await File(wav).exists() &&
          (await File(wav).length()) > 1024;
      if (!wavOk) {
        pieces.add(seg.video);
        continue;
      }
      final mixed = p.join(dir.path, 'mix_${i.toString().padLeft(3, '0')}.mkv');
      final sysVol = s.systemVolume.toStringAsFixed(2);
      final micVol = '1.00';
      final List<String> args;
      if (seg.hasMic) {
        args = [
          '-i', seg.video, '-i', wav,
          '-filter_complex',
          '[0:a]volume=$micVol[m];[1:a]volume=$sysVol[s];'
              '[m][s]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]',
          '-map', '0:v', '-map', '[a]',
          '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000',
          mixed,
        ];
      } else {
        args = [
          '-i', seg.video, '-i', wav,
          '-filter_complex', '[1:a]volume=$sysVol[a]',
          '-map', '0:v', '-map', '[a]',
          '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000',
          '-shortest',
          mixed,
        ];
      }
      final r = await ff.run(args);
      if (!r.ok) {
        throw Exception('mezcla de audio falló:\n${r.tail}');
      }
      pieces.add(mixed);
    }

    // Unir segmentos y volcar a MP4.
    processingLabel = 'Guardando MP4…';
    notifyListeners();
    final outDir = Directory(s.outputDir);
    await outDir.create(recursive: true);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'NJB Rec ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}-${two(now.minute)}-${two(now.second)}.mp4';
    final outFile = p.join(outDir.path, name);

    final FfmpegResult r;
    if (pieces.length == 1) {
      r = await ff.run([
        '-i', pieces.first, '-c', 'copy', '-movflags', '+faststart', outFile,
      ]);
    } else {
      final list = File(p.join(dir.path, 'concat.txt'));
      await list.writeAsString(
        pieces.map((f) => "file '${f.replaceAll("'", r"'\''")}'").join('\n'),
      );
      r = await ff.run([
        '-f', 'concat', '-safe', '0', '-i', list.path,
        '-c', 'copy', '-movflags', '+faststart', outFile,
      ]);
    }
    if (!r.ok) throw Exception('no se pudo guardar el MP4:\n${r.tail}');
    return outFile;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _countdownTimer?.cancel();
    _ffmpeg?.kill();
    _finished.close();
    super.dispose();
  }
}
