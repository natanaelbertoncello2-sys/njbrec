// Prueba de integración del grabador: captura real de pantalla (región
// chica) y micrófono con ffmpeg, con el canal nativo simulado (monitores y
// audio del sistema generado con ffmpeg). Verifica pausa/reanudar, unión de
// segmentos, mezcla con compensación de desfase y el MP4 final.
//
// Se omite si no hay ffmpeg.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:njbrec/core/ffmpeg.dart';
import 'package:njbrec/core/recorder.dart';
import 'package:njbrec/core/settings.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('graba, pausa, reanuda y produce un MP4 sincronizado', () async {
    final ff = await Ffmpeg.locate();
    if (ff == null) {
      markTestSkipped('sin ffmpeg');
      return;
    }
    final mics = await ff.listAudioInputs();
    final tmp = Directory.systemTemp.createTempSync('njbrec_rec_test');
    final outDir = Directory(p.join(tmp.path, 'out'))..createSync();

    SharedPreferences.setMockInitialValues({
      'outputDir': outDir.path,
      'countdownSeconds': 0,
      'captureMode': CaptureMode.region.index,
      'regionX': 0,
      'regionY': 0,
      'regionW': 640,
      'regionH': 360,
      'fps': 30,
      'micEnabled': mics.isNotEmpty,
      if (mics.isNotEmpty) 'micDevice': mics.first,
      'systemAudioEnabled': true,
      'openEditorAfterStop': false,
    });

    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );

    double wavStartEpoch = 0;
    Future<FfmpegResult>? wavJob;
    messenger.setMockMethodCallHandler(const MethodChannel('njbrec/native'), (call) async {
      switch (call.method) {
        case 'listMonitors':
          return {
            'monitors': [
              {'id': 0, 'name': 'test', 'x': 0, 'y': 0, 'width': 1920, 'height': 1080, 'primary': true},
            ],
            'virtual': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080},
          };
        case 'loopbackStart':
          final path = (call.arguments as Map)['path'] as String;
          wavStartEpoch = DateTime.now().millisecondsSinceEpoch.toDouble();
          // Audio "del sistema" simulado: un bip de 1 kHz cada segundo.
          // Se genera en segundo plano (como haría la captura real).
          wavJob = ff.run([
            '-f', 'lavfi', '-i', 'sine=f=1000:r=48000', '-t', '30',
            '-af', "volume=0:enable='gte(mod(t\\,1)\\,0.1)'", '-ac', '2', '-c:a', 'pcm_s16le', path,
          ]);
          return true;
        case 'loopbackStop':
          final r = await wavJob;
          if (r != null && !r.ok) throw PlatformException(code: 'gen', message: r.tail);
          return wavStartEpoch;
        case 'loopbackIsRunning':
          return false;
      }
      return null;
    });

    final settings = await AppSettings.load();
    final rec = Recorder(settings);

    await rec.start();
    expect(rec.state, RecState.recording, reason: rec.lastError ?? '');
    await Future<void>.delayed(const Duration(seconds: 3));
    await rec.pause();
    expect(rec.state, RecState.paused);
    await Future<void>.delayed(const Duration(seconds: 1));
    await rec.resume();
    expect(rec.state, RecState.recording, reason: rec.lastError ?? '');
    await Future<void>.delayed(const Duration(seconds: 2));
    await rec.stop();
    expect(rec.state, RecState.idle);
    expect(rec.lastError, isNull);
    expect(rec.lastOutputFile, isNotNull);

    final info = await ff.probe(rec.lastOutputFile!);
    expect(info, isNotNull);
    expect(info!.hasVideo, isTrue);
    expect(info.hasAudio, isTrue);
    // ~5 s grabados (3 + 2), con tolerancia por arranque/parada de ffmpeg.
    expect(info.seconds, inInclusiveRange(4.0, 7.5), reason: 'duración ${info.seconds}');
    expect(info.start.abs(), lessThan(0.05), reason: 'el MP4 debe empezar en 0');

    rec.dispose();
    if (Platform.environment['NJBREC_KEEP'] == null) {
      tmp.deleteSync(recursive: true);
    } else {
      // ignore: avoid_print
      print('archivos conservados en ${tmp.path}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
