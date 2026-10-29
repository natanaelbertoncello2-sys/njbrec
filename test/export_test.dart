// Prueba de integración del exportador: arma un proyecto con cortes, texto,
// imagen, audio y fundidos sobre una grabación real y verifica que ffmpeg
// genere el archivo con la duración esperada.
//
// Requiere ffmpeg y un video de muestra; si faltan, se omite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:njbrec/core/ffmpeg.dart';
import 'package:njbrec/editor/export.dart';
import 'package:njbrec/editor/project.dart';
import 'package:path/path.dart' as p;

void main() {
  test('exporta un proyecto completo con ffmpeg', () async {
    final ff = await Ffmpeg.locate();
    final sample = Platform.environment['NJBREC_SAMPLE'] ??
        _firstMp4(p.join(Platform.environment['USERPROFILE'] ?? '', 'Videos', 'NJB Rec'));
    if (ff == null || sample == null) {
      markTestSkipped('sin ffmpeg o sin video de muestra');
      return;
    }
    final info = await ff.probe(sample);
    expect(info, isNotNull);
    expect(info!.hasVideo, isTrue);

    final project = EditorProject(source: sample, duration: info.seconds);
    final d = info.seconds;
    project.addCut(d * 0.2, d * 0.3); // elimina 10 %
    project.fadeIn = true;
    project.fadeOut = true;
    project.clips.add(TextClip(
      id: 't1',
      start: 0,
      end: d * 0.5,
      text: "Hola: 'NJB' Rec, 100% \\ listo",
      x: 0.5,
      y: 0.8,
    ));
    project.clips.add(ImageClip(
      id: 'i1',
      start: 0,
      end: d,
      path: p.join(Directory.current.path, 'assets', 'branding', 'logo_mark.png'),
      opacity: 0.8,
    ));
    project.clips.add(AudioClip(
      id: 'a1',
      start: d * 0.1,
      end: d * 0.6,
      path: sample, // el propio video como pista de audio
      fileDuration: d,
      audioKind: AudioKind.narration,
      volume: 0.8,
      fadeIn: 0.5,
      fadeOut: 0.5,
    ));

    final tmp = Directory.systemTemp.createTempSync('njbrec_export_test');
    final out = p.join(tmp.path, 'salida.mp4');
    var lastProgress = 0.0;
    final r = await ProjectExporter(ff, project, info).run(
      out,
      const ExportOptions(format: ExportFormat.mp4, quality: 28),
      tempRoot: tmp.path,
      onProgress: (v) => lastProgress = v,
    );
    expect(r.ok, isTrue, reason: r.tail);
    expect(lastProgress, greaterThan(0.5));

    final outInfo = await ff.probe(out);
    expect(outInfo, isNotNull);
    expect(outInfo!.hasAudio, isTrue);
    expect((outInfo.seconds - project.outputDuration).abs(), lessThan(0.5),
        reason: 'duración ${outInfo.seconds} vs esperada ${project.outputDuration}');

    // GIF y MP3 también deben funcionar.
    final gif = await ProjectExporter(ff, project, info)
        .run(p.join(tmp.path, 'salida.gif'), const ExportOptions(format: ExportFormat.gif, gifWidth: 240, gifFps: 8), tempRoot: tmp.path);
    expect(gif.ok, isTrue, reason: gif.tail);
    final mp3 = await ProjectExporter(ff, project, info)
        .run(p.join(tmp.path, 'salida.mp3'), const ExportOptions(format: ExportFormat.mp3), tempRoot: tmp.path);
    expect(mp3.ok, isTrue, reason: mp3.tail);

    tmp.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

String? _firstMp4(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return null;
  for (final f in d.listSync()) {
    if (f is File && f.path.toLowerCase().endsWith('.mp4')) return f.path;
  }
  return null;
}
