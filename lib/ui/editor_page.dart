import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app.dart';
import '../app/theme.dart';
import '../core/ffmpeg.dart';
import 'library_panel.dart';
import 'widgets/window_chrome.dart';

enum ExportFormat { mp4, gif, mp3 }

/// Editor: recorte por inicio/fin, silenciar audio, exportar MP4/GIF/MP3.
class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.file});

  final String file;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _playing = false;
  double _start = 0; // segundos
  double _end = 0;
  bool _loopRange = true;
  bool _mute = false;
  List<String> _thumbs = const [];
  bool _exporting = false;
  double _exportProgress = 0;
  String? _exportMessage;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _subs.add(_player.stream.duration.listen((d) {
      if (d > Duration.zero && _duration == Duration.zero) {
        setState(() {
          _duration = d;
          _end = d.inMilliseconds / 1000;
        });
        _buildThumbs();
      }
    }));
    _subs.add(_player.stream.position.listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
      final posS = pos.inMilliseconds / 1000;
      if (_loopRange && _playing && _end > _start && posS >= _end) {
        _player.seek(Duration(milliseconds: (_start * 1000).round()));
      }
    }));
    _subs.add(_player.stream.playing.listen((v) => mounted ? setState(() => _playing = v) : null));
    _player.open(Media(widget.file), play: false);
  }

  Future<void> _buildThumbs() async {
    final ff = Ffmpeg.instance;
    if (ff == null || _duration == Duration.zero) return;
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'njbrec', 'editor_${DateTime.now().millisecondsSinceEpoch}'));
    await dir.create(recursive: true);
    const n = 14;
    final secs = _duration.inMilliseconds / 1000;
    final r = await ff.run([
      '-i', widget.file,
      '-vf', 'fps=${n / secs},scale=160:-2',
      '-frames:v', '$n',
      p.join(dir.path, 't_%02d.jpg'),
    ]);
    if (!r.ok || !mounted) return;
    final files = (await dir.list().toList()).map((e) => e.path).toList()..sort();
    if (mounted) setState(() => _thumbs = files);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  double get _durS => _duration.inMilliseconds / 1000;
  double get _posS => _position.inMilliseconds / 1000;

  String _fmt(double s) {
    final d = Duration(milliseconds: (s * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000) ~/ 10;
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}.${two(ms)}';
  }

  Future<void> _seek(double s) => _player.seek(Duration(milliseconds: (s.clamp(0, _durS) * 1000).round()));

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else {
      if (_loopRange && (_posS >= _end || _posS < _start)) await _seek(_start);
      await _player.play();
    }
  }

  // ------------------------------------------------------------- exportar

  Future<void> _export() async {
    final ff = Ffmpeg.instance;
    if (ff == null) return;
    final result = await showDialog<_ExportOptions>(
      context: context,
      builder: (_) => _ExportDialog(
        defaultName: '${p.basenameWithoutExtension(widget.file)} recorte',
        rangeLabel: '${_fmt(_start)} → ${_fmt(_end)}',
        initialMute: _mute,
      ),
    );
    if (result == null || !mounted) return;

    final c = AppScope.of(context);
    final outDir = Directory(c.settings.outputDir);
    await outDir.create(recursive: true);
    final ext = switch (result.format) {
      ExportFormat.mp4 => '.mp4',
      ExportFormat.gif => '.gif',
      ExportFormat.mp3 => '.mp3',
    };
    var outPath = p.join(outDir.path, '${result.name}$ext');
    var n = 2;
    while (await File(outPath).exists()) {
      outPath = p.join(outDir.path, '${result.name} ($n)$ext');
      n++;
    }

    final wholeRange = _start <= 0.01 && (_durS - _end).abs() < 0.01;
    final ss = Ffmpeg.formatDuration(Duration(milliseconds: (_start * 1000).round()));
    final to = Ffmpeg.formatDuration(Duration(milliseconds: (_end * 1000).round()));
    final args = <String>[
      if (!wholeRange) ...['-ss', ss, '-to', to],
      '-i', widget.file,
    ];
    switch (result.format) {
      case ExportFormat.mp4:
        if (result.precise || result.mute || !wholeRange && result.precise) {
          args.addAll(['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p']);
          args.addAll(result.mute ? ['-an'] : ['-c:a', 'aac', '-b:a', '192k']);
        } else {
          args.addAll(['-c', 'copy']);
          if (result.mute) args.add('-an');
        }
        args.addAll(['-movflags', '+faststart']);
      case ExportFormat.gif:
        args.addAll([
          '-vf',
          'fps=${result.gifFps},scale=${result.gifWidth}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5',
          '-loop', '0',
        ]);
      case ExportFormat.mp3:
        args.addAll(['-vn', '-c:a', 'libmp3lame', '-b:a', '192k']);
    }
    args.add(outPath);

    setState(() {
      _exporting = true;
      _exportProgress = 0;
      _exportMessage = null;
    });
    final total = (_end - _start).clamp(0.1, double.infinity);
    final r = await ff.run(args, onProgress: (d) {
      if (mounted) setState(() => _exportProgress = (d.inMilliseconds / 1000 / total).clamp(0, 1));
    });
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _exportMessage = r.ok ? 'Exportado: $outPath' : 'Error al exportar:\n${r.tail}';
    });
    if (r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Guardado en ${p.basename(outPath)}'),
        action: SnackBarAction(label: 'Ver carpeta', onPressed: () => LibraryActions.revealInExplorer(outPath)),
      ));
    }
  }

  Future<void> _snapshot() async {
    final ff = Ffmpeg.instance;
    if (ff == null) return;
    final c = AppScope.of(context);
    final outDir = Directory(c.settings.outputDir);
    await outDir.create(recursive: true);
    final name = '${p.basenameWithoutExtension(widget.file)} ${_fmt(_posS).replaceAll(':', '-')}.png';
    final out = p.join(outDir.path, name);
    final r = await ff.run([
      '-ss', Ffmpeg.formatDuration(_position), '-i', widget.file, '-frames:v', '1', out,
    ]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok ? 'Captura guardada: $name' : 'No se pudo guardar la captura'),
    ));
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
          const SingleActivator(LogicalKeyboardKey.keyI): () => setState(() => _start = _posS.clamp(0, _end)),
          const SingleActivator(LogicalKeyboardKey.keyO): () => setState(() => _end = _posS.clamp(_start, _durS)),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seek(_posS - 1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seek(_posS + 1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () => _seek(_posS - 0.1),
          const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () => _seek(_posS + 0.1),
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              WindowChrome(
                title: 'Editor · ${p.basename(widget.file)}',
                leading: IconButton(
                  tooltip: 'Volver',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
                  child: Column(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            color: Colors.black,
                            child: Video(controller: _video, controls: NoVideoControls),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildTransport(),
                      const SizedBox(height: 10),
                      _buildTimeline(),
                      const SizedBox(height: 12),
                      _buildBottomBar(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTransport() {
    return Row(
      children: [
        IconButton.filled(
          style: IconButton.styleFrom(backgroundColor: NjbColors.violet),
          onPressed: _togglePlay,
          icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
          tooltip: 'Reproducir / pausar (espacio)',
        ),
        const SizedBox(width: 6),
        IconButton(onPressed: () => _seek(_start), icon: const Icon(Icons.first_page_rounded), tooltip: 'Ir al inicio del recorte'),
        IconButton(onPressed: () => _seek(_posS - 5), icon: const Icon(Icons.replay_5_rounded), tooltip: '−5 s'),
        IconButton(onPressed: () => _seek(_posS + 5), icon: const Icon(Icons.forward_5_rounded), tooltip: '+5 s'),
        const SizedBox(width: 12),
        Text(
          '${_fmt(_posS)}  /  ${_fmt(_durS)}',
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: () => setState(() => _start = _posS.clamp(0, _end)),
          icon: const Icon(Icons.start_rounded, size: 18),
          label: const Text('Inicio aquí (I)'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => setState(() => _end = _posS.clamp(_start, _durS)),
          icon: const Icon(Icons.keyboard_tab_rounded, size: 18),
          label: const Text('Fin aquí (O)'),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () => setState(() {
            _start = 0;
            _end = _durS;
          }),
          child: const Text('Restablecer'),
        ),
      ],
    );
  }

  Widget _buildTimeline() {
    final dur = _durS <= 0 ? 1.0 : _durS;
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      return SizedBox(
        height: 92,
        child: Stack(
          children: [
            // Miniaturas
            Positioned.fill(
              child: GestureDetector(
                onTapDown: (d) => _seek(d.localPosition.dx / w * dur),
                onHorizontalDragUpdate: (d) => _seek(d.localPosition.dx / w * dur),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    color: NjbColors.bgElevated,
                    child: _thumbs.isEmpty
                        ? const SizedBox.expand()
                        : Row(
                            children: [
                              for (final t in _thumbs)
                                Expanded(child: Image.file(File(t), fit: BoxFit.cover, height: 92)),
                            ],
                          ),
                  ),
                ),
              ),
            ),
            // Zonas descartadas
            IgnorePointer(
              child: Row(
                children: [
                  Container(width: w * (_start / dur), color: Colors.black.withValues(alpha: 0.65)),
                  const Spacer(),
                  Container(width: w * (1 - _end / dur), color: Colors.black.withValues(alpha: 0.65)),
                ],
              ),
            ),
            // Marco del rango
            IgnorePointer(
              child: Padding(
                padding: EdgeInsets.only(left: w * (_start / dur), right: w * (1 - _end / dur)),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: NjbColors.cyan, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            // Cabezal
            IgnorePointer(
              child: Padding(
                padding: EdgeInsets.only(left: (w * (_posS / dur)).clamp(0, w - 2)),
                child: Container(width: 2, color: NjbColors.red),
              ),
            ),
            // Manijas
            Positioned.fill(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 0,
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  rangeThumbShape: const _HandleShape(),
                  overlayShape: SliderComponentShape.noOverlay,
                  rangeTrackShape: const RectangularRangeSliderTrackShape(),
                ),
                child: RangeSlider(
                  min: 0,
                  max: dur,
                  values: RangeValues(_start.clamp(0, dur), _end.clamp(0, dur)),
                  onChanged: (v) {
                    final startChanged = v.start != _start;
                    setState(() {
                      _start = v.start;
                      _end = v.end;
                    });
                    _seek(startChanged ? v.start : v.end);
                  },
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildBottomBar() {
    return Row(
      children: [
        Text('Recorte: ${_fmt(_start)} → ${_fmt(_end)}  (${_fmt(_end - _start)})',
            style: const TextStyle(color: NjbColors.textMuted, fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(width: 18),
        FilterChip(
          label: const Text('Repetir recorte'),
          selected: _loopRange,
          onSelected: (v) => setState(() => _loopRange = v),
        ),
        const SizedBox(width: 8),
        FilterChip(
          label: const Text('Silenciar'),
          avatar: Icon(_mute ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 16),
          selected: _mute,
          onSelected: (v) {
            setState(() => _mute = v);
            _player.setVolume(v ? 0 : 100);
          },
        ),
        const Spacer(),
        if (_exporting) ...[
          SizedBox(
            width: 160,
            child: LinearProgressIndicator(value: _exportProgress, minHeight: 6, borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(width: 12),
          Text('${(_exportProgress * 100).round()} %'),
          const SizedBox(width: 12),
        ],
        if (_exportMessage != null && !_exporting)
          Tooltip(
            message: _exportMessage!,
            child: Icon(
              _exportMessage!.startsWith('Error') ? Icons.error_outline_rounded : Icons.check_circle_rounded,
              color: _exportMessage!.startsWith('Error') ? NjbColors.red : NjbColors.green,
            ),
          ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: _exporting ? null : _snapshot,
          icon: const Icon(Icons.photo_camera_rounded, size: 18),
          label: const Text('Capturar cuadro'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => LibraryActions.revealInExplorer(widget.file),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('Carpeta'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _exporting ? null : _export,
          icon: const Icon(Icons.save_alt_rounded, size: 18),
          label: const Text('Exportar'),
        ),
      ],
    );
  }
}

class _HandleShape extends RangeSliderThumbShape {
  const _HandleShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(14, 92);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool? isOnTop,
    bool? isPressed,
    required SliderThemeData sliderTheme,
    TextDirection? textDirection,
    Thumb? thumb,
  }) {
    final canvas = context.canvas;
    final rect = Rect.fromCenter(center: center, width: 12, height: 92);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      Paint()..color = NjbColors.cyan,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: 2, height: 22), const Radius.circular(1)),
      Paint()..color = NjbColors.bg,
    );
  }
}

class _ExportOptions {
  _ExportOptions({
    required this.name,
    required this.format,
    required this.precise,
    required this.mute,
    required this.gifFps,
    required this.gifWidth,
  });
  final String name;
  final ExportFormat format;
  final bool precise;
  final bool mute;
  final int gifFps;
  final int gifWidth;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.defaultName, required this.rangeLabel, required this.initialMute});

  final String defaultName;
  final String rangeLabel;
  final bool initialMute;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final _name = TextEditingController(text: widget.defaultName);
  ExportFormat _format = ExportFormat.mp4;
  bool _precise = true;
  late bool _mute = widget.initialMute;
  int _gifFps = 12;
  int _gifWidth = 640;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exportar recorte'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rango: ${widget.rangeLabel}', style: const TextStyle(color: NjbColors.textMuted)),
            const SizedBox(height: 14),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre del archivo')),
            const SizedBox(height: 14),
            SegmentedButton<ExportFormat>(
              segments: const [
                ButtonSegment(value: ExportFormat.mp4, label: Text('MP4')),
                ButtonSegment(value: ExportFormat.gif, label: Text('GIF')),
                ButtonSegment(value: ExportFormat.mp3, label: Text('Solo audio')),
              ],
              selected: {_format},
              onSelectionChanged: (v) => setState(() => _format = v.first),
            ),
            const SizedBox(height: 10),
            if (_format == ExportFormat.mp4) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Corte preciso (recodifica)'),
                subtitle: const Text('Desactivado: más rápido, pero el corte cae en el cuadro clave más cercano.',
                    style: TextStyle(fontSize: 12, color: NjbColors.textMuted)),
                value: _precise,
                onChanged: (v) => setState(() => _precise = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Quitar el audio'),
                value: _mute,
                onChanged: (v) => setState(() => _mute = v),
              ),
            ],
            if (_format == ExportFormat.gif)
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _gifFps,
                      decoration: const InputDecoration(labelText: 'FPS'),
                      items: const [8, 10, 12, 15, 20].map((v) => DropdownMenuItem(value: v, child: Text('$v'))).toList(),
                      onChanged: (v) => setState(() => _gifFps = v ?? 12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _gifWidth,
                      decoration: const InputDecoration(labelText: 'Ancho'),
                      items: const [320, 480, 640, 800, 1024].map((v) => DropdownMenuItem(value: v, child: Text('$v px'))).toList(),
                      onChanged: (v) => setState(() => _gifWidth = v ?? 640),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _ExportOptions(
              name: _name.text.trim().isEmpty ? widget.defaultName : _name.text.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
              format: _format,
              precise: _precise,
              mute: _mute,
              gifFps: _gifFps,
              gifWidth: _gifWidth,
            ),
          ),
          child: const Text('Exportar'),
        ),
      ],
    );
  }
}
