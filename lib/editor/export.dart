import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/ffmpeg.dart';
import 'project.dart';

enum ExportFormat { mp4, gif, mp3 }

class ExportOptions {
  const ExportOptions({
    required this.format,
    this.quality = 20,
    this.gifFps = 12,
    this.gifWidth = 640,
  });
  final ExportFormat format;
  final int quality; // crf
  final int gifFps;
  final int gifWidth;
}

/// Arma el grafo de filtros de ffmpeg a partir del proyecto y lo ejecuta.
class ProjectExporter {
  ProjectExporter(this.ffmpeg, this.project, this.info);

  final Ffmpeg ffmpeg;
  final EditorProject project;
  final MediaInfo info;

  static String _f(double v) => v.toStringAsFixed(3);

  /// Ruta para usar dentro de un filtro (barras normales, ':' escapado).
  static String _filterPath(String path) =>
      path.replaceAll('\\', '/').replaceAll(':', r'\:').replaceAll("'", r"\'");

  static String _color(Color c) {
    final rgb = (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    final a = (c.a).toStringAsFixed(3);
    return '0x$rgb@$a';
  }

  static String _fontFile(bool bold) {
    final candidates = [
      if (bold) r'C:\Windows\Fonts\segoeuib.ttf' else r'C:\Windows\Fonts\segoeui.ttf',
      if (bold) r'C:\Windows\Fonts\arialbd.ttf' else r'C:\Windows\Fonts\arial.ttf',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return candidates.last;
  }

  String _cutExpr() =>
      project.cuts.map((c) => 'between(t,${_f(c.start)},${_f(c.end)})').join('+');

  Future<FfmpegResult> run(
    String outPath,
    ExportOptions opts, {
    void Function(double progress)? onProgress,
    String? tempRoot,
  }) async {
    tempRoot ??= (await getTemporaryDirectory()).path;
    final tmp = Directory(p.join(tempRoot, 'njbrec',
        'export_${DateTime.now().millisecondsSinceEpoch}'));
    await tmp.create(recursive: true);

    // Caso trivial: sin ediciones y MP4 → copia directa.
    if (project.isEmpty && opts.format == ExportFormat.mp4) {
      return ffmpeg.run(
        ['-i', project.source, '-c', 'copy', '-movflags', '+faststart', outPath],
        onProgress: (d) => onProgress?.call(d.inMilliseconds / 1000 / project.outputDuration),
      );
    }

    final inputs = <String>['-i', project.source];
    final graph = StringBuffer();
    var inputIndex = 1;
    final W = info.width;
    final H = info.height;

    // ---------------------------------------------------------------- video
    var v = '[0:v]';
    var step = 0;
    String next(String prefix) => '[$prefix${step++}]';

    final chain = <String>[];
    if (project.cuts.isNotEmpty) {
      chain.add("select='not(${_cutExpr()})',setpts=N/FRAME_RATE/TB");
    }
    chain.add('format=yuv420p');
    {
      final out = next('v');
      graph.writeln('$v${chain.join(',')}$out;');
      v = out;
    }

    // Textos (drawtext) — el texto se pasa por archivo para evitar escapes.
    var textIdx = 0;
    for (final t in project.texts) {
      final a = project.toOutput(t.start);
      final b = project.toOutput(t.end);
      if (b - a < 0.05) continue;
      final txtFile = File(p.join(tmp.path, 'text_${textIdx++}.txt'));
      await txtFile.writeAsString(t.text);
      final fontsize = (H * t.size).round().clamp(8, 400);
      final parts = <String>[
        "fontfile='${_filterPath(_fontFile(t.bold))}'",
        "textfile='${_filterPath(txtFile.path)}'",
        'fontsize=$fontsize',
        'fontcolor=${_color(t.color)}',
        'x=w*${_f(t.x)}-text_w/2',
        'y=h*${_f(t.y)}-text_h/2',
        if (t.showBg) ...[
          'box=1',
          'boxcolor=${_color(t.bgColor)}',
          'boxborderw=${(fontsize * 0.35).round()}',
        ],
        "enable='between(t,${_f(a)},${_f(b)})'",
        if (t.fade)
          "alpha='if(lt(t,${_f(a)}+0.3),(t-${_f(a)})/0.3,if(gt(t,${_f(b)}-0.3),(${_f(b)}-t)/0.3,1))'",
      ];
      final out = next('v');
      graph.writeln('${v}drawtext=${parts.join(':')}$out;');
      v = out;
    }

    // Imágenes (overlay)
    for (final im in project.images) {
      final a = project.toOutput(im.start);
      final b = project.toOutput(im.end);
      if (b - a < 0.05 || !File(im.path).existsSync()) continue;
      inputs.addAll(['-i', im.path]);
      final idx = inputIndex++;
      final scaled = next('i');
      final w = (W * im.width).round().clamp(2, W);
      graph.writeln(
          '[$idx:v]scale=$w:-1,format=rgba,colorchannelmixer=aa=${_f(im.opacity)}$scaled;');
      final out = next('v');
      graph.writeln(
          "$v${scaled}overlay=x=W*${_f(im.x)}-w/2:y=H*${_f(im.y)}-h/2:enable='between(t,${_f(a)},${_f(b)})':format=auto$out;");
      v = out;
    }

    // Fundidos de video
    final outDur = project.outputDuration;
    final vf = <String>[];
    if (project.fadeIn) vf.add('fade=t=in:st=0:d=0.6');
    if (project.fadeOut) vf.add('fade=t=out:st=${_f(outDur - 0.6)}:d=0.6');
    if (vf.isNotEmpty) {
      final out = next('v');
      graph.writeln('$v${vf.join(',')}$out;');
      v = out;
    }
    final vOut = v;

    // ---------------------------------------------------------------- audio
    final mixInputs = <String>[];
    String orig;
    if (info.hasAudio) {
      final ac = <String>[];
      if (project.cuts.isNotEmpty) {
        ac.add("aselect='not(${_cutExpr()})',asetpts=N/SR/TB");
      }
      ac.add('aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo');
      ac.add('volume=${_f(project.muteOriginal ? 0 : project.originalVolume)}');
      if (project.duckOriginal && !project.muteOriginal) {
        final ranges = project.audios
            .where((c) => c.audioKind == AudioKind.narration)
            .map((c) => 'between(t,${_f(project.toOutput(c.start))},${_f(project.toOutput(c.end))})')
            .join('+');
        if (ranges.isNotEmpty) ac.add("volume=0.2:enable='$ranges'");
      }
      if (project.fadeIn) ac.add('afade=t=in:st=0:d=0.6');
      if (project.fadeOut) ac.add('afade=t=out:st=${_f(outDur - 0.6)}:d=0.6');
      orig = next('a');
      graph.writeln('[0:a]${ac.join(',')}$orig;');
    } else {
      orig = next('a');
      graph.writeln('anullsrc=r=48000:cl=stereo,atrim=0:${_f(outDur)}$orig;');
    }
    mixInputs.add(orig);

    for (final c in project.audios) {
      if (!File(c.path).existsSync()) continue;
      final a = project.toOutput(c.start);
      final b = project.toOutput(c.end);
      final dur = (b - a).clamp(0.0, c.fileDuration - c.offset);
      if (dur < 0.05) continue;
      inputs.addAll(['-i', c.path]);
      final idx = inputIndex++;
      final parts = <String>[
        'atrim=start=${_f(c.offset)}:end=${_f(c.offset + dur)}',
        'asetpts=PTS-STARTPTS',
        'aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo',
        'volume=${_f(c.volume)}',
        if (c.fadeIn > 0) 'afade=t=in:st=0:d=${_f(c.fadeIn)}',
        if (c.fadeOut > 0) 'afade=t=out:st=${_f(dur - c.fadeOut)}:d=${_f(c.fadeOut)}',
        'adelay=${(a * 1000).round()}:all=1',
      ];
      final out = next('a');
      graph.writeln('[$idx:a]${parts.join(',')}$out;');
      mixInputs.add(out);
    }

    final aOut = next('a');
    if (mixInputs.length == 1) {
      graph.writeln('${mixInputs.first}acopy$aOut;');
    } else {
      graph.writeln(
          '${mixInputs.join()}amix=inputs=${mixInputs.length}:duration=first:dropout_transition=0:normalize=0$aOut;');
    }

    // ---------------------------------------------------------------- salida
    final List<String> tail;
    var finalV = vOut;
    switch (opts.format) {
      case ExportFormat.mp4:
        tail = [
          '-map', vOut, '-map', aOut,
          '-c:v', 'libx264', '-preset', 'fast', '-crf', '${opts.quality}',
          '-c:a', 'aac', '-b:a', '192k',
          '-movflags', '+faststart',
        ];
      case ExportFormat.gif:
        finalV = '[gif]';
        graph.writeln(
            '${vOut}fps=${opts.gifFps},scale=${opts.gifWidth}:-1:flags=lanczos,split[g0][g1];[g0]palettegen=stats_mode=diff[pal];[g1][pal]paletteuse=dither=bayer:bayer_scale=5$finalV;');
        graph.writeln('${aOut}anullsink;'); // el audio no se usa en GIF
        tail = ['-map', finalV, '-loop', '0'];
      case ExportFormat.mp3:
        graph.writeln('${vOut}nullsink;'); // el video no se usa en MP3
        tail = ['-map', aOut, '-c:a', 'libmp3lame', '-b:a', '192k'];
    }

    // El grafo va en un archivo: evita límites de longitud y problemas de comillas.
    var script = graph.toString().trim();
    if (script.endsWith(';')) script = script.substring(0, script.length - 1);
    final scriptFile = File(p.join(tmp.path, 'graph.txt'));
    await scriptFile.writeAsString(script);

    final args = <String>[
      ...inputs,
      '-filter_complex_script', scriptFile.path,
      ...tail,
      outPath,
    ];
    final r = await ffmpeg.run(args, onProgress: (d) {
      onProgress?.call((d.inMilliseconds / 1000 / outDur).clamp(0, 1));
    });
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
    return r;
  }
}
