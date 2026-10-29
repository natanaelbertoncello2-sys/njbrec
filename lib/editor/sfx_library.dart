import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';

/// Un efecto de sonido disponible en la biblioteca.
class SfxItem {
  const SfxItem({required this.name, required this.path, required this.duration, required this.builtin});
  final String name;
  final String path;
  final double duration;
  final bool builtin;
}

/// Efecto sintetizado con ffmpeg (fuente lavfi + filtros).
class _Builtin {
  const _Builtin(this.file, this.name, this.source, this.filters, this.seconds);
  final String file;
  final String name;
  final String source;
  final String filters;
  final double seconds;
}

/// Biblioteca de efectos: una carpeta `Efectos` dentro de la carpeta de
/// grabaciones. Los efectos incluidos se generan con ffmpeg la primera vez;
/// el usuario puede agregar cualquier MP3/WAV a esa carpeta.
class SfxLibrary {
  SfxLibrary(this.ffmpeg, this.outputDir);

  final Ffmpeg ffmpeg;
  final String outputDir;

  String get folder => p.join(outputDir, 'Efectos');

  static const _builtins = <_Builtin>[
    _Builtin('viento', 'Viento', 'anoisesrc=c=brown:r=48000:a=0.7',
        'lowpass=f=500,tremolo=f=0.25:d=0.6,afade=t=in:d=1,afade=t=out:st=9:d=1', 10),
    _Builtin('lluvia', 'Lluvia', 'anoisesrc=c=pink:r=48000:a=0.5',
        'highpass=f=1000,lowpass=f=9000,afade=t=in:d=0.5,afade=t=out:st=9.3:d=0.7', 10),
    _Builtin('mar', 'Olas del mar', 'anoisesrc=c=brown:r=48000:a=0.8',
        'lowpass=f=800,tremolo=f=0.11:d=0.9,afade=t=in:d=1,afade=t=out:st=9:d=1', 10),
    _Builtin('estatica', 'Estática de TV', 'anoisesrc=c=white:r=48000:a=0.35',
        'afade=t=out:st=3.8:d=0.2', 4),
    _Builtin('whoosh', 'Whoosh (transición)', 'anoisesrc=c=white:r=48000:a=0.6',
        'bandpass=f=1400:w=900,afade=t=in:d=0.25,afade=t=out:st=0.35:d=0.45', 0.8),
    _Builtin('golpe_puerta', 'Golpe de puerta',
        "aevalsrc='0.9*sin(2*PI*65*t)*exp(-9*t)+0.5*random(0)*exp(-60*t)':s=48000", 'lowpass=f=1500', 1.2),
    _Builtin('golpe', 'Golpe seco', "aevalsrc='sin(2*PI*90*t)*exp(-14*t)':s=48000", 'volume=1.5', 0.8),
    _Builtin('tambor', 'Redoble de tambor', "aevalsrc='sin(2*PI*85*t)*exp(-10*mod(t,0.22))':s=48000",
        'volume=1.2,afade=t=out:st=2.2:d=0.3', 2.5),
    _Builtin('latido', 'Latido de corazón',
        "aevalsrc='sin(2*PI*50*t)*(exp(-18*mod(t,1))+0.7*exp(-18*mod(t+0.72,1)))':s=48000", 'volume=1.4', 5),
    _Builtin('tictac', 'Reloj tic-tac', "aevalsrc='0.7*sin(2*PI*2200*t)*exp(-70*mod(t,0.5))':s=48000", 'anull', 5),
    _Builtin('campana', 'Campanita (ding)',
        "aevalsrc='0.6*sin(2*PI*1760*t)*exp(-2.5*t)+0.3*sin(2*PI*2640*t)*exp(-4*t)':s=48000", 'anull', 2),
    _Builtin('notificacion', 'Notificación',
        "aevalsrc='0.5*sin(2*PI*880*t)*lt(t,0.14)+0.5*sin(2*PI*1320*t)*gte(t,0.16)*lt(t,0.4)':s=48000", 'anull', 0.5),
    _Builtin('pop', 'Pop', "aevalsrc='0.9*sin(2*PI*700*t)*exp(-45*t)':s=48000", 'anull', 0.15),
    _Builtin('error', 'Error (buzz)', 'sine=f=140:r=48000', 'tremolo=f=28:d=1,afade=t=out:st=0.4:d=0.1', 0.5),
    _Builtin('exito', 'Éxito (acorde)',
        "aevalsrc='0.35*(sin(2*PI*523*t)*gte(t,0)+sin(2*PI*659*t)*gte(t,0.12)+sin(2*PI*784*t)*gte(t,0.24))*exp(-1.5*t)':s=48000",
        'anull', 1.8),
    _Builtin('sirena', 'Sirena', 'sine=f=750:r=48000', 'vibrato=f=0.7:d=0.8,volume=4,afade=t=out:st=4.5:d=0.5', 5),
    _Builtin('aplausos', 'Aplausos', 'anoisesrc=c=pink:r=48000:a=0.6',
        'highpass=f=700,tremolo=f=11:d=0.95,afade=t=in:d=0.3,afade=t=out:st=3.5:d=0.5', 4),
    _Builtin('zumbido', 'Zumbido eléctrico', 'sine=f=60:r=48000',
        'aecho=0.8:0.8:6:0.5,volume=4,afade=t=in:d=0.3,afade=t=out:st=3.6:d=0.4', 4),
  ];

  /// Genera los efectos incluidos que falten.
  Future<void> ensureBuiltins() async {
    final dir = Directory(folder);
    await dir.create(recursive: true);
    for (final b in _builtins) {
      final out = p.join(dir.path, '${b.file}.wav');
      if (await File(out).exists()) continue;
      await ffmpeg.run([
        '-f', 'lavfi', '-i', b.source,
        '-t', b.seconds.toStringAsFixed(2),
        '-af', b.filters,
        '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s16le',
        out,
      ]);
    }
  }

  /// Lista todos los efectos (incluidos + los que agregó el usuario).
  Future<List<SfxItem>> list() async {
    final dir = Directory(folder);
    if (!await dir.exists()) return const [];
    final builtinNames = {for (final b in _builtins) '${b.file}.wav': b};
    final items = <SfxItem>[];
    final files = (await dir.list().toList()).whereType<File>().where((f) =>
        const ['.wav', '.mp3', '.m4a', '.aac', '.ogg', '.flac'].contains(p.extension(f.path).toLowerCase()));
    for (final f in files) {
      final base = p.basename(f.path);
      final b = builtinNames[base];
      double dur;
      if (b != null) {
        dur = b.seconds;
      } else {
        dur = (await ffmpeg.probeDuration(f.path))?.inMilliseconds.toDouble() ?? 0;
        dur /= 1000;
      }
      items.add(SfxItem(
        name: b?.name ?? p.basenameWithoutExtension(f.path),
        path: f.path,
        duration: dur,
        builtin: b != null,
      ));
    }
    items.sort((a, b) {
      if (a.builtin != b.builtin) return a.builtin ? 1 : -1; // los del usuario primero
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }
}
