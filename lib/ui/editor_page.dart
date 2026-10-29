import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app.dart';
import '../app/theme.dart';
import '../core/ffmpeg.dart';
import '../editor/export.dart';
import '../editor/narration.dart';
import '../editor/preview_audio.dart';
import '../editor/project.dart';
import '../editor/sfx_library.dart';
import 'library_panel.dart';
import 'widgets/window_chrome.dart';

/// Editor multipista: cortes, narración, música, textos e imágenes.
class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.file});

  final String file;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final Player _player = Player();
  late final VideoController _video;
  final _previewAudio = PreviewAudio();

  EditorProject? _project;
  MediaInfo? _info;
  Duration _position = Duration.zero;
  bool _playing = false;
  double _selStart = 0;
  double _selEnd = 0;
  String? _selectedId;
  List<String> _thumbs = const [];
  final List<String> _undo = [];
  final List<String> _redo = [];
  Timer? _saveTimer;

  NarrationRecorder? _narration;
  double _narrationStart = 0;
  DateTime? _narrationSince;
  Timer? _narrationTick;

  bool _exporting = false;
  double _exportProgress = 0;
  String? _status;
  bool _statusError = false;

  final List<StreamSubscription> _subs = [];

  // ------------------------------------------------------------------ init

  @override
  void initState() {
    super.initState();
    // El controlador de video debe existir antes de abrir el archivo.
    _video = VideoController(_player);
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
      if (!v) _previewAudio.pauseAll();
    }));
    _subs.add(_player.stream.completed.listen((done) {
      if (done) _previewAudio.pauseAll();
    }));
    _load();
  }

  Future<void> _load() async {
    final ff = Ffmpeg.instance;
    final info = ff == null ? null : await ff.probe(widget.file);
    final dur = info?.seconds ?? 0;
    var project = await EditorProject.tryLoad(widget.file);
    project ??= EditorProject(source: widget.file, duration: dur);
    if (dur > 0) project.duration = dur;
    if (!mounted) return;
    setState(() {
      _info = info;
      _project = project;
      _selStart = 0;
      _selEnd = dur;
    });
    await _player.open(Media(widget.file), play: false);
    _buildThumbs();
  }

  Future<void> _buildThumbs() async {
    final ff = Ffmpeg.instance;
    final dur = _project?.duration ?? 0;
    if (ff == null || dur <= 0) return;
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'njbrec', 'editor_${DateTime.now().millisecondsSinceEpoch}'));
    await dir.create(recursive: true);
    final n = (dur / 2).clamp(10, 40).round();
    final r = await ff.run([
      '-i', widget.file, '-vf', 'fps=${n / dur},scale=120:-2', '-frames:v', '$n',
      p.join(dir.path, 't_%03d.jpg'),
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
    _saveTimer?.cancel();
    _narrationTick?.cancel();
    _narration?.cancel();
    _previewAudio.dispose();
    _player.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ helpers

  EditorProject get _p => _project!;
  double get _dur => _p.duration;
  double get _posS => _position.inMilliseconds / 1000;
  Clip? get _selected => _selectedId == null
      ? null
      : _p.clips.where((c) => c.id == _selectedId).firstOrNull;

  String _fmt(double s) {
    final d = Duration(milliseconds: (s * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    final cs = (d.inMilliseconds % 1000) ~/ 10;
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}.${two(cs)}';
  }

  void _onPosition(Duration pos) {
    if (!mounted || _project == null) return;
    setState(() => _position = pos);
    final s = pos.inMilliseconds / 1000;
    if (_playing && _narration == null && _p.isCut(s)) {
      final next = _p.skipCut(s);
      if (next >= _dur) {
        _player.pause();
      } else {
        _seek(next);
      }
      return;
    }
    _previewAudio.sync(_p, s, _playing);
  }

  Future<void> _seek(double s) =>
      _player.seek(Duration(milliseconds: (s.clamp(0, _dur) * 1000).round()));

  Future<void> _togglePlay() async {
    if (_narration != null) return;
    if (_playing) {
      await _player.pause();
    } else {
      if (_posS >= _dur - 0.05) await _seek(0);
      await _player.play();
    }
  }

  /// Aplica un cambio al proyecto con soporte de deshacer y guardado.
  void _mutate(void Function(EditorProject p) fn, {bool snapshot = true}) {
    if (snapshot) {
      _undo.add(_p.encode());
      if (_undo.length > 60) _undo.removeAt(0);
      _redo.clear();
    }
    setState(() => fn(_p));
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () => _p.save());
  }

  void _undoAction() {
    if (_undo.isEmpty) return;
    _redo.add(_p.encode());
    final snap = _undo.removeLast();
    setState(() => _project = EditorProject.decode(snap));
    _scheduleSave();
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    _undo.add(_p.encode());
    final snap = _redo.removeLast();
    setState(() => _project = EditorProject.decode(snap));
    _scheduleSave();
  }

  void _flash(String msg, {bool error = false}) {
    setState(() {
      _status = msg;
      _statusError = error;
    });
  }

  // ------------------------------------------------------------------ acciones

  void _cutSelection() {
    if (_selEnd - _selStart < 0.05) return;
    _mutate((p) => p.addCut(_selStart, _selEnd));
    _flash('Tramo eliminado: ${_fmt(_selStart)} → ${_fmt(_selEnd)}');
  }

  void _deleteSelected() {
    final c = _selected;
    if (c == null) {
      _cutSelection();
      return;
    }
    _mutate((p) => p.clips.removeWhere((x) => x.id == c.id));
    _selectedId = null;
  }

  void _addText() {
    final start = _posS;
    final clip = TextClip(id: newClipId(), start: start, end: math.min(_dur, start + 4));
    _mutate((p) => p.clips.add(clip));
    setState(() => _selectedId = clip.id);
  }

  Future<void> _addImage() async {
    final r = await FilePicker.pickFiles(
      dialogTitle: 'Elegir imagen (logo, sticker…)',
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    );
    final path = r.isEmpty ? null : r.first.path;
    if (path == null) return;
    final start = _posS;
    final clip = ImageClip(id: newClipId(), start: start, end: math.min(_dur, start + 5), path: path);
    _mutate((p) => p.clips.add(clip));
    setState(() => _selectedId = clip.id);
  }

  Future<void> _addAudioFile() async {
    final ff = Ffmpeg.instance;
    if (ff == null) return;
    final r = await FilePicker.pickFiles(
      dialogTitle: 'Elegir audio (música, efectos…)',
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac', 'wma', 'mp4'],
    );
    final path = r.isEmpty ? null : r.first.path;
    if (path == null) return;
    final d = await ff.probeDuration(path);
    if (d == null) {
      _flash('No se pudo leer el archivo de audio', error: true);
      return;
    }
    final fileDur = d.inMilliseconds / 1000;
    final start = _posS;
    final clip = AudioClip(
      id: newClipId(),
      start: start,
      end: math.min(_dur, start + fileDur),
      path: path,
      fileDuration: fileDur,
      audioKind: AudioKind.music,
      volume: 0.6,
      fadeIn: 1,
      fadeOut: 1.5,
    );
    _mutate((p) => p.clips.add(clip));
    setState(() => _selectedId = clip.id);
  }

  Future<void> _addSfx() async {
    final ff = Ffmpeg.instance;
    if (ff == null) return;
    final c = AppScope.of(context);
    final lib = SfxLibrary(ff, c.settings.outputDir);
    await _player.pause();
    if (!mounted) return;
    final item = await showDialog<SfxItem>(
      context: context,
      builder: (_) => _SfxDialog(library: lib),
    );
    if (item == null || !mounted) return;
    final start = _posS;
    final clip = AudioClip(
      id: newClipId(),
      start: start,
      end: math.min(_dur, start + math.max(0.3, item.duration)),
      path: item.path,
      fileDuration: item.duration,
      audioKind: AudioKind.sfx,
      name: item.name,
      volume: 0.9,
    );
    _mutate((p) => p.clips.add(clip));
    setState(() => _selectedId = clip.id);
    _flash('Efecto "${item.name}" agregado en ${_fmt(start)}');
  }

  Future<void> _toggleNarration() async {
    if (_narration != null) {
      await _stopNarration();
      return;
    }
    final c = AppScope.of(context);
    final ff = Ffmpeg.instance;
    final mic = c.settings.micDevice;
    if (ff == null || mic == null || mic.isEmpty) {
      _flash('No hay micrófono configurado (Ajustes → Audio)', error: true);
      return;
    }
    if (_posS >= _dur - 0.1) await _seek(0);
    await _player.pause();
    final rec = NarrationRecorder(ff, mic);
    final dir = p.join(c.settings.outputDir, 'Narraciones');
    try {
      await rec.start(dir);
    } catch (e) {
      _flash('$e', error: true);
      return;
    }
    _narrationStart = _posS;
    _narrationSince = DateTime.now();
    setState(() => _narration = rec);
    _narrationTick = Timer.periodic(const Duration(milliseconds: 200), (_) => setState(() {}));
    await _player.setVolume(0); // sin audio original para no colarlo en la voz
    await _player.play();
  }

  Future<void> _stopNarration() async {
    final rec = _narration;
    if (rec == null) return;
    _narrationTick?.cancel();
    await _player.pause();
    await _player.setVolume(100);
    setState(() => _narration = null);
    try {
      final (path, dur) = await rec.stop();
      if (dur < 0.2) {
        _flash('La narración quedó vacía', error: true);
        return;
      }
      final clip = AudioClip(
        id: newClipId(),
        start: _narrationStart,
        end: math.min(_dur, _narrationStart + dur),
        path: path,
        fileDuration: dur,
        audioKind: AudioKind.narration,
        name: 'Narración ${_fmt(_narrationStart)}',
      );
      _mutate((p) => p.clips.add(clip));
      setState(() => _selectedId = clip.id);
      await _seek(_narrationStart);
      _flash('Narración agregada (${_fmt(dur)})');
    } catch (e) {
      _flash('Error al guardar la narración: $e', error: true);
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
    final r = await ff.run(['-ss', Ffmpeg.formatDuration(_position), '-i', widget.file, '-frames:v', '1', out]);
    _flash(r.ok ? 'Captura guardada: $name' : 'No se pudo guardar la captura', error: !r.ok);
  }

  Future<void> _export() async {
    final ff = Ffmpeg.instance;
    final info = _info;
    if (ff == null || info == null) return;
    final result = await showDialog<_ExportChoice>(
      context: context,
      builder: (_) => _ExportDialog(defaultName: '${p.basenameWithoutExtension(widget.file)} editado'),
    );
    if (result == null || !mounted) return;
    final c = AppScope.of(context);
    final outDir = Directory(c.settings.outputDir);
    await outDir.create(recursive: true);
    final ext = switch (result.options.format) {
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
    await _player.pause();
    setState(() {
      _exporting = true;
      _exportProgress = 0;
      _status = null;
    });
    final r = await ProjectExporter(ff, _p, info).run(outPath, result.options, onProgress: (v) {
      if (mounted) setState(() => _exportProgress = v);
    });
    if (!mounted) return;
    setState(() => _exporting = false);
    if (r.ok) {
      _flash('Exportado: ${p.basename(outPath)}');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Guardado en ${p.basename(outPath)}'),
        action: SnackBarAction(label: 'Ver carpeta', onPressed: () => LibraryActions.revealInExplorer(outPath)),
      ));
    } else {
      _flash('Error al exportar:\n${r.tail}', error: true);
    }
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    if (_project == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
          const SingleActivator(LogicalKeyboardKey.keyI): () => setState(() => _selStart = _posS.clamp(0, _selEnd)),
          const SingleActivator(LogicalKeyboardKey.keyO): () => setState(() => _selEnd = _posS.clamp(_selStart, _dur)),
          const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
          const SingleActivator(LogicalKeyboardKey.keyT): _addText,
          const SingleActivator(LogicalKeyboardKey.keyE): _addSfx,
          const SingleActivator(LogicalKeyboardKey.keyR): _toggleNarration,
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undoAction,
          const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redoAction,
          const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _selectedId = null),
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 8, 12),
                        child: Column(
                          children: [
                            Expanded(child: _buildPreview()),
                            const SizedBox(height: 8),
                            _buildTransport(),
                            const SizedBox(height: 6),
                            _buildToolbar(),
                            const SizedBox(height: 8),
                            _Timeline(
                              project: _p,
                              thumbs: _thumbs,
                              position: _posS,
                              selStart: _selStart,
                              selEnd: _selEnd,
                              selectedId: _selectedId,
                              narrationFrom: _narration == null ? null : _narrationStart,
                              onSeek: _seek,
                              onSelection: (a, b) => setState(() {
                                _selStart = a;
                                _selEnd = b;
                              }),
                              onSelectClip: (id) => setState(() => _selectedId = id),
                              onClipChanged: (snapshot) => _mutate((_) {}, snapshot: snapshot),
                              onRemoveCut: (c) => _mutate((p) => p.cuts.remove(c)),
                            ),
                            const SizedBox(height: 8),
                            _buildStatusBar(),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 300,
                      child: _Inspector(
                        project: _p,
                        clip: _selected,
                        position: _posS,
                        onChanged: (snapshot) => _mutate((_) {}, snapshot: snapshot),
                        onDelete: _deleteSelected,
                        onClose: () => setState(() => _selectedId = null),
                        fmt: _fmt,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final info = _info;
    final aspect = (info != null && info.width > 0) ? info.width / info.height : 16 / 9;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            final h = c.maxHeight;
            final t = _posS;
            final active = _p.clips.where((x) => t >= x.start && t < x.end && x.kind != ClipKind.audio).toList();
            return Stack(
              fit: StackFit.expand,
              children: [
                Container(color: Colors.black, child: Video(controller: _video, controls: NoVideoControls)),
                if (_p.isCut(t))
                  Container(
                    color: Colors.black.withValues(alpha: 0.6),
                    alignment: Alignment.center,
                    child: const Text('TRAMO ELIMINADO', style: TextStyle(color: NjbColors.red, fontWeight: FontWeight.w800, letterSpacing: 2)),
                  ),
                for (final clip in active)
                  _OverlayWidget(
                    clip: clip,
                    width: w,
                    height: h,
                    selected: clip.id == _selectedId,
                    onTap: () => setState(() => _selectedId = clip.id),
                    onMoved: (x, y) {
                      setState(() {
                        if (clip is TextClip) {
                          clip.x = x;
                          clip.y = y;
                        } else if (clip is ImageClip) {
                          clip.x = x;
                          clip.y = y;
                        }
                      });
                      _scheduleSave();
                    },
                    onMoveStart: () => _mutate((_) {}),
                  ),
                if (_narration != null)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(10)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.mic_rounded, color: NjbColors.red, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Grabando narración  ${_fmt(DateTime.now().difference(_narrationSince!).inMilliseconds / 1000)}   (R para terminar)',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ]),
                    ),
                  ),
              ],
            );
          }),
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
        IconButton(onPressed: () => _seek(0), icon: const Icon(Icons.first_page_rounded), tooltip: 'Al inicio'),
        IconButton(onPressed: () => _seek(_posS - 5), icon: const Icon(Icons.replay_5_rounded), tooltip: '−5 s'),
        IconButton(onPressed: () => _seek(_posS + 5), icon: const Icon(Icons.forward_5_rounded), tooltip: '+5 s'),
        const SizedBox(width: 10),
        Text('${_fmt(_posS)}  /  ${_fmt(_dur)}',
            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        Text('→ salida ${_fmt(_p.outputDuration)}', style: const TextStyle(color: NjbColors.textMuted, fontSize: 12)),
        const Spacer(),
        IconButton(onPressed: _undo.isEmpty ? null : _undoAction, icon: const Icon(Icons.undo_rounded), tooltip: 'Deshacer (Ctrl+Z)'),
        IconButton(onPressed: _redo.isEmpty ? null : _redoAction, icon: const Icon(Icons.redo_rounded), tooltip: 'Rehacer (Ctrl+Y)'),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => setState(() => _selStart = _posS.clamp(0, _selEnd)),
          icon: const Icon(Icons.start_rounded, size: 18),
          label: const Text('Inicio (I)'),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          onPressed: () => setState(() => _selEnd = _posS.clamp(_selStart, _dur)),
          icon: const Icon(Icons.keyboard_tab_rounded, size: 18),
          label: const Text('Fin (O)'),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: NjbColors.red),
          onPressed: _cutSelection,
          icon: const Icon(Icons.content_cut_rounded, size: 18),
          label: const Text('Eliminar tramo'),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    final recording = _narration != null;
    return Row(
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: recording ? NjbColors.red : NjbColors.surfaceHigh),
          onPressed: _exporting ? null : _toggleNarration,
          icon: Icon(recording ? Icons.stop_rounded : Icons.mic_rounded, size: 18),
          label: Text(recording ? 'Terminar narración' : 'Grabar narración (R)'),
        ),
        const SizedBox(width: 8),
        _ToolButton(icon: Icons.library_music_rounded, label: 'Música / audio', onTap: _addAudioFile),
        const SizedBox(width: 8),
        _ToolButton(icon: Icons.surround_sound_rounded, label: 'Efectos (E)', onTap: _addSfx),
        const SizedBox(width: 8),
        _ToolButton(icon: Icons.title_rounded, label: 'Texto (T)', onTap: _addText),
        const SizedBox(width: 8),
        _ToolButton(icon: Icons.image_rounded, label: 'Imagen / logo', onTap: _addImage),
        const Spacer(),
        _ToolButton(icon: Icons.photo_camera_rounded, label: 'Capturar cuadro', onTap: _snapshot),
        const SizedBox(width: 8),
        _ToolButton(icon: Icons.folder_open_rounded, label: 'Carpeta', onTap: () => LibraryActions.revealInExplorer(widget.file)),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _exporting || recording ? null : _export,
          icon: const Icon(Icons.save_alt_rounded, size: 18),
          label: const Text('Exportar'),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    return SizedBox(
      height: 22,
      child: Row(
        children: [
          if (_exporting) ...[
            SizedBox(width: 200, child: LinearProgressIndicator(value: _exportProgress, minHeight: 6, borderRadius: BorderRadius.circular(4))),
            const SizedBox(width: 10),
            Text('Exportando… ${(_exportProgress * 100).round()} %'),
          ] else if (_status != null)
            Expanded(
              child: Text(
                _status!.split('\n').first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _statusError ? NjbColors.red : NjbColors.green, fontSize: 12.5),
              ),
            )
          else
            const Text(
              'Espacio: reproducir · I/O: marcar tramo · Supr: eliminar · T: texto · E: efecto · R: narración · arrastrá textos e imágenes sobre el video',
              style: TextStyle(color: NjbColors.textMuted, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
    );
  }
}

// ---------------------------------------------------------------------------
// Overlays en la vista previa (texto / imagen arrastrables)
// ---------------------------------------------------------------------------

class _OverlayWidget extends StatelessWidget {
  const _OverlayWidget({
    required this.clip,
    required this.width,
    required this.height,
    required this.selected,
    required this.onTap,
    required this.onMoved,
    required this.onMoveStart,
  });

  final Clip clip;
  final double width;
  final double height;
  final bool selected;
  final VoidCallback onTap;
  final void Function(double x, double y) onMoved;
  final VoidCallback onMoveStart;

  @override
  Widget build(BuildContext context) {
    final double cx, cy;
    final Widget child;
    if (clip is TextClip) {
      final t = clip as TextClip;
      cx = t.x;
      cy = t.y;
      final fs = height * t.size;
      child = Container(
        padding: t.showBg ? EdgeInsets.symmetric(horizontal: fs * 0.35, vertical: fs * 0.35) : EdgeInsets.zero,
        color: t.showBg ? t.bgColor : null,
        child: Text(
          t.text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Segoe UI',
            fontSize: fs,
            height: 1.15,
            fontWeight: t.bold ? FontWeight.w700 : FontWeight.w400,
            color: t.color,
          ),
        ),
      );
    } else {
      final im = clip as ImageClip;
      cx = im.x;
      cy = im.y;
      child = Opacity(
        opacity: im.opacity,
        child: Image.file(File(im.path), width: width * im.width, fit: BoxFit.contain),
      );
    }
    return Positioned.fill(
      child: Align(
        alignment: Alignment(cx * 2 - 1, cy * 2 - 1),
        child: GestureDetector(
          onTap: onTap,
          onPanStart: (_) {
            onTap();
            onMoveStart();
          },
          onPanUpdate: (d) => onMoved(
            (cx + d.delta.dx / width).clamp(0.0, 1.0),
            (cy + d.delta.dy / height).clamp(0.0, 1.0),
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: selected ? NjbColors.cyan : Colors.transparent, width: 1.5),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Línea de tiempo multipista
// ---------------------------------------------------------------------------

class _Timeline extends StatefulWidget {
  const _Timeline({
    required this.project,
    required this.thumbs,
    required this.position,
    required this.selStart,
    required this.selEnd,
    required this.selectedId,
    required this.narrationFrom,
    required this.onSeek,
    required this.onSelection,
    required this.onSelectClip,
    required this.onClipChanged,
    required this.onRemoveCut,
  });

  final EditorProject project;
  final List<String> thumbs;
  final double position;
  final double selStart;
  final double selEnd;
  final String? selectedId;
  final double? narrationFrom;
  final ValueChanged<double> onSeek;
  final void Function(double a, double b) onSelection;
  final ValueChanged<String?> onSelectClip;
  final void Function(bool snapshot) onClipChanged;
  final ValueChanged<CutRange> onRemoveCut;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  static const _videoH = 58.0;
  static const _trackH = 30.0;
  static const _rulerH = 18.0;

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    final dur = p.duration <= 0 ? 1.0 : p.duration;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      double px(double t) => (t / dur * w).clamp(0, w);
      return Container(
        decoration: BoxDecoration(
          color: NjbColors.bgElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: NjbColors.border),
        ),
        clipBehavior: ui.Clip.antiAlias,
        child: Stack(
          children: [
            Column(
              children: [
                _buildRuler(w, dur),
                _buildVideoTrack(w, dur, px),
                _buildClipTrack(w, dur, px, ClipKind.text, Icons.title_rounded, NjbColors.cyan),
                _buildClipTrack(w, dur, px, ClipKind.image, Icons.image_rounded, NjbColors.violet),
                _buildClipTrack(w, dur, px, ClipKind.audio, Icons.graphic_eq_rounded, NjbColors.green),
              ],
            ),
            // Cabezal
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: EdgeInsets.only(left: px(widget.position).clamp(0, w - 2)),
                  child: Align(alignment: Alignment.centerLeft, child: Container(width: 2, color: NjbColors.red)),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildRuler(double w, double dur) {
    final step = dur <= 30 ? 5.0 : dur <= 120 ? 10.0 : dur <= 600 ? 30.0 : 60.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => widget.onSeek(d.localPosition.dx / w * dur),
      onHorizontalDragUpdate: (d) => widget.onSeek(d.localPosition.dx / w * dur),
      child: SizedBox(
        height: _rulerH,
        child: Stack(
          children: [
            for (double t = 0; t < dur; t += step)
              Positioned(
                left: t / dur * w,
                top: 0,
                bottom: 0,
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Container(width: 1, height: 8, color: NjbColors.border),
                  const SizedBox(width: 3),
                  Text('${t ~/ 60}:${(t % 60).toInt().toString().padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 9, color: NjbColors.textMuted)),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoTrack(double w, double dur, double Function(double) px) {
    final p = widget.project;
    return SizedBox(
      height: _videoH,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                widget.onSelectClip(null);
                widget.onSeek(d.localPosition.dx / w * dur);
              },
              onHorizontalDragUpdate: (d) => widget.onSeek(d.localPosition.dx / w * dur),
              child: widget.thumbs.isEmpty
                  ? Container(color: Colors.black26)
                  : Row(children: [for (final t in widget.thumbs) Expanded(child: Image.file(File(t), fit: BoxFit.cover, height: _videoH))]),
            ),
          ),
          // Cortes
          for (final c in p.cuts)
            Positioned(
              left: px(c.start),
              width: math.max(2, px(c.end) - px(c.start)),
              top: 0,
              bottom: 0,
              child: Tooltip(
                message: 'Tramo eliminado. Clic para restaurar.',
                child: GestureDetector(
                  onTap: () => widget.onRemoveCut(c),
                  child: Container(
                    decoration: BoxDecoration(
                      color: NjbColors.red.withValues(alpha: 0.45),
                      border: Border.symmetric(vertical: BorderSide(color: NjbColors.red.withValues(alpha: 0.9))),
                    ),
                    child: const Center(child: Icon(Icons.close_rounded, size: 16, color: Colors.white)),
                  ),
                ),
              ),
            ),
          // Selección I/O
          Positioned(
            left: px(widget.selStart),
            width: math.max(0, px(widget.selEnd) - px(widget.selStart)),
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: NjbColors.cyan.withValues(alpha: 0.10),
                  border: Border.symmetric(vertical: BorderSide(color: NjbColors.cyan.withValues(alpha: 0.9), width: 2)),
                ),
              ),
            ),
          ),
          if (widget.narrationFrom != null)
            Positioned(
              left: px(widget.narrationFrom!),
              width: math.max(2, px(widget.position) - px(widget.narrationFrom!)),
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(color: NjbColors.red.withValues(alpha: 0.35)),
              ),
            ),
          // Manijas de selección
          Positioned.fill(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 0,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                rangeThumbShape: const _HandleShape(_videoH),
                overlayShape: SliderComponentShape.noOverlay,
                rangeTrackShape: const RectangularRangeSliderTrackShape(),
              ),
              child: RangeSlider(
                min: 0,
                max: dur,
                values: RangeValues(widget.selStart.clamp(0, dur), widget.selEnd.clamp(0, dur)),
                onChanged: (v) {
                  final startChanged = v.start != widget.selStart;
                  widget.onSelection(v.start, v.end);
                  widget.onSeek(startChanged ? v.start : v.end);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipTrack(double w, double dur, double Function(double) px, ClipKind kind, IconData icon, Color color) {
    final clips = widget.project.clips.where((c) => c.kind == kind).toList();
    return Container(
      height: _trackH,
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: NjbColors.border))),
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                widget.onSelectClip(null);
                widget.onSeek(d.localPosition.dx / w * dur);
              },
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(padding: const EdgeInsets.only(left: 4), child: Icon(icon, size: 14, color: NjbColors.textMuted.withValues(alpha: 0.5))),
              ),
            ),
          ),
          for (final c in clips)
            _ClipBlock(
              clip: c,
              left: px(c.start),
              width: math.max(6, px(c.end) - px(c.start)),
              height: _trackH,
              color: c is AudioClip
                  ? switch (c.audioKind) {
                      AudioKind.narration => NjbColors.amber,
                      AudioKind.sfx => const Color(0xFFFF8A3D),
                      AudioKind.music => color,
                    }
                  : color,
              selected: c.id == widget.selectedId,
              pxPerSec: w / dur,
              maxEnd: dur,
              onSelect: () => widget.onSelectClip(c.id),
              onChanged: widget.onClipChanged,
            ),
        ],
      ),
    );
  }
}

class _ClipBlock extends StatelessWidget {
  const _ClipBlock({
    required this.clip,
    required this.left,
    required this.width,
    required this.height,
    required this.color,
    required this.selected,
    required this.pxPerSec,
    required this.maxEnd,
    required this.onSelect,
    required this.onChanged,
  });

  final Clip clip;
  final double left;
  final double width;
  final double height;
  final Color color;
  final bool selected;
  final double pxPerSec;
  final double maxEnd;
  final VoidCallback onSelect;
  final void Function(bool snapshot) onChanged;

  @override
  Widget build(BuildContext context) {
    final maxLen = clip is AudioClip ? (clip as AudioClip).maxLength : double.infinity;
    return Positioned(
      left: left,
      width: width,
      top: 3,
      height: height - 6,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onSelect,
              onHorizontalDragStart: (_) {
                onSelect();
                onChanged(true);
              },
              onHorizontalDragUpdate: (d) {
                final dt = d.delta.dx / pxPerSec;
                final len = clip.end - clip.start;
                var s = (clip.start + dt).clamp(0.0, maxEnd - len);
                clip.start = s;
                clip.end = s + len;
                onChanged(false);
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Container(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: selected ? 0.95 : 0.65),
                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(6)),
                    border: Border.all(color: selected ? Colors.white : Colors.transparent),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.centerLeft,
                  child: Text(clip.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black)),
                ),
              ),
            ),
          ),
          GestureDetector(
            onHorizontalDragStart: (_) {
              onSelect();
              onChanged(true);
            },
            onHorizontalDragUpdate: (d) {
              final dt = d.delta.dx / pxPerSec;
              final newEnd = (clip.end + dt).clamp(clip.start + 0.2, math.min(maxEnd, clip.start + maxLen));
              clip.end = newEnd.toDouble();
              onChanged(false);
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: Container(
                width: 8,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HandleShape extends RangeSliderThumbShape {
  const _HandleShape(this.h);
  final double h;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(12, h);

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
    final rect = Rect.fromCenter(center: center, width: 10, height: h);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), Paint()..color = NjbColors.cyan);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: 2, height: 16), const Radius.circular(1)),
      Paint()..color = NjbColors.bg,
    );
  }
}

// ---------------------------------------------------------------------------
// Inspector (panel de propiedades)
// ---------------------------------------------------------------------------

class _Inspector extends StatelessWidget {
  const _Inspector({
    required this.project,
    required this.clip,
    required this.position,
    required this.onChanged,
    required this.onDelete,
    required this.onClose,
    required this.fmt,
  });

  final EditorProject project;
  final Clip? clip;
  final double position;
  final void Function(bool snapshot) onChanged;
  final VoidCallback onDelete;
  final VoidCallback onClose;
  final String Function(double) fmt;

  @override
  Widget build(BuildContext context) {
    final c = clip;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NjbColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NjbColors.border),
      ),
      child: SingleChildScrollView(
        child: c == null ? _projectPanel() : _clipPanel(context, c),
      ),
    );
  }

  Widget _title(String t, {Widget? trailing}) => Row(children: [
        Expanded(child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
        ?trailing,
      ]);

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChange, {String Function(double)? show}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, color: NjbColors.textMuted))),
        Text(show?.call(value) ?? '${(value * 100).round()} %', style: const TextStyle(fontSize: 12)),
      ]),
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChangeStart: (_) => onChanged(true),
        onChanged: (v) {
          onChange(v);
          onChanged(false);
        },
      ),
    ]);
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChange) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label, style: const TextStyle(fontSize: 13)),
        value: value,
        onChanged: (v) {
          onChanged(true);
          onChange(v);
          onChanged(false);
        },
      );

  Widget _timeRow(Clip c, {double? maxLen}) {
    return Column(children: [
      Row(children: [
        Expanded(child: _NumField(label: 'Inicio (s)', value: c.start, onSubmit: (v) {
          onChanged(true);
          final len = c.end - c.start;
          c.start = v.clamp(0, project.duration - 0.2);
          c.end = (c.start + len).clamp(c.start + 0.2, project.duration);
          onChanged(false);
        })),
        const SizedBox(width: 8),
        Expanded(child: _NumField(label: 'Fin (s)', value: c.end, onSubmit: (v) {
          onChanged(true);
          var e = v.clamp(c.start + 0.2, project.duration).toDouble();
          if (maxLen != null) e = math.min(e, c.start + maxLen);
          c.end = e;
          onChanged(false);
        })),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        TextButton.icon(
          onPressed: () {
            onChanged(true);
            final len = c.end - c.start;
            c.start = position.clamp(0, project.duration - 0.2);
            c.end = (c.start + len).clamp(c.start + 0.2, project.duration);
            onChanged(false);
          },
          icon: const Icon(Icons.vertical_align_center_rounded, size: 16),
          label: const Text('Mover al cabezal', style: TextStyle(fontSize: 12)),
        ),
        TextButton.icon(
          onPressed: () {
            onChanged(true);
            c.end = position.clamp(c.start + 0.2, project.duration);
            onChanged(false);
          },
          icon: const Icon(Icons.keyboard_tab_rounded, size: 16),
          label: const Text('Terminar aquí', style: TextStyle(fontSize: 12)),
        ),
      ]),
    ]);
  }

  Widget _projectPanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title('Proyecto'),
      const SizedBox(height: 6),
      const Text('Seleccioná un elemento de la línea de tiempo para editarlo, o arrastrá textos e imágenes sobre el video.',
          style: TextStyle(fontSize: 12, color: NjbColors.textMuted)),
      const Divider(height: 24),
      const Text('Audio original', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      _slider('Volumen', project.originalVolume, 0, 2, (v) => project.originalVolume = v),
      _switch('Silenciar audio original', project.muteOriginal, (v) => project.muteOriginal = v),
      _switch('Bajar el original mientras hay narración', project.duckOriginal, (v) => project.duckOriginal = v),
      const Divider(height: 24),
      const Text('Video', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      _switch('Fundido de entrada', project.fadeIn, (v) => project.fadeIn = v),
      _switch('Fundido de salida', project.fadeOut, (v) => project.fadeOut = v),
      const Divider(height: 24),
      Text('Tramos eliminados (${project.cuts.length})', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      const SizedBox(height: 4),
      if (project.cuts.isEmpty)
        const Text('Marcá un tramo con I/O y apretá "Eliminar tramo".', style: TextStyle(fontSize: 12, color: NjbColors.textMuted)),
      for (final cut in project.cuts)
        Row(children: [
          Expanded(child: Text('${fmt(cut.start)} → ${fmt(cut.end)}', style: const TextStyle(fontSize: 12.5))),
          IconButton(
            tooltip: 'Restaurar',
            iconSize: 18,
            onPressed: () {
              onChanged(true);
              project.cuts.remove(cut);
              onChanged(false);
            },
            icon: const Icon(Icons.restore_rounded),
          ),
        ]),
      const Divider(height: 24),
      Text('Duración final: ${fmt(project.outputDuration)}', style: const TextStyle(fontSize: 12.5, color: NjbColors.textMuted)),
      const SizedBox(height: 4),
      Text('El proyecto se guarda solo junto al video (.njbproj.json).',
          style: TextStyle(fontSize: 11.5, color: NjbColors.textMuted.withValues(alpha: 0.8))),
    ]);
  }

  Widget _clipPanel(BuildContext context, Clip c) {
    final header = switch (c.kind) {
      ClipKind.text => 'Texto',
      ClipKind.image => 'Imagen',
      ClipKind.audio => switch ((c as AudioClip).audioKind) {
          AudioKind.narration => 'Narración',
          AudioKind.sfx => 'Efecto de sonido',
          AudioKind.music => 'Música / audio',
        },
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(header, trailing: IconButton(onPressed: onClose, iconSize: 18, icon: const Icon(Icons.close_rounded))),
      const SizedBox(height: 8),
      if (c is TextClip) ..._textFields(c),
      if (c is ImageClip) ..._imageFields(c),
      if (c is AudioClip) ..._audioFields(c),
      const Divider(height: 24),
      _timeRow(c, maxLen: c is AudioClip && !c.loop ? c.fileDuration - c.offset : null),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: NjbColors.red),
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          label: const Text('Quitar (Supr)'),
        ),
      ),
    ]);
  }

  static const _palette = [
    Colors.white, Colors.black, Color(0xFFFFE14D), NjbColors.red, NjbColors.cyan, NjbColors.violet, NjbColors.green, Color(0xFFFF8A3D),
  ];

  Widget _colorRow(Color current, ValueChanged<Color> onPick) {
    return Wrap(spacing: 6, children: [
      for (final col in _palette)
        GestureDetector(
          onTap: () {
            onChanged(true);
            onPick(col);
            onChanged(false);
          },
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: col,
              shape: BoxShape.circle,
              border: Border.all(color: current.toARGB32() == col.toARGB32() ? NjbColors.cyan : NjbColors.border, width: 2),
            ),
          ),
        ),
    ]);
  }

  List<Widget> _textFields(TextClip t) => [
        _TextArea(
          key: ValueKey('txt_${t.id}'),
          value: t.text,
          onChanged: (v) {
            t.text = v;
            onChanged(false);
          },
          onFocusStart: () => onChanged(true),
        ),
        const SizedBox(height: 8),
        _slider('Tamaño', t.size, 0.02, 0.25, (v) => t.size = v, show: (v) => '${(v * 100).round()}'),
        const Text('Color', style: TextStyle(fontSize: 12.5, color: NjbColors.textMuted)),
        const SizedBox(height: 4),
        _colorRow(t.color, (c) => t.color = c),
        const SizedBox(height: 8),
        _switch('Negrita', t.bold, (v) => t.bold = v),
        _switch('Fondo detrás del texto', t.showBg, (v) => t.showBg = v),
        if (t.showBg) ...[
          const Text('Color de fondo', style: TextStyle(fontSize: 12.5, color: NjbColors.textMuted)),
          const SizedBox(height: 4),
          _colorRow(Color(t.bgColor.toARGB32() | 0xFF000000), (c) => t.bgColor = c.withValues(alpha: 0.6)),
          _slider('Opacidad del fondo', t.bgColor.a, 0.1, 1, (v) => t.bgColor = t.bgColor.withValues(alpha: v)),
        ],
        _switch('Aparecer / desaparecer suave', t.fade, (v) => t.fade = v),
        const Text('Posición: arrastrá el texto sobre el video.', style: TextStyle(fontSize: 11.5, color: NjbColors.textMuted)),
      ];

  List<Widget> _imageFields(ImageClip im) => [
        Text(im.label, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        _slider('Ancho', im.width, 0.03, 1, (v) => im.width = v),
        _slider('Opacidad', im.opacity, 0.05, 1, (v) => im.opacity = v),
        const Text('Posición: arrastrá la imagen sobre el video.', style: TextStyle(fontSize: 11.5, color: NjbColors.textMuted)),
      ];

  List<Widget> _audioFields(AudioClip a) => [
        Text(a.name, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis),
        Text('Archivo: ${fmt(a.fileDuration)} · ${p.basename(a.path)}', style: const TextStyle(fontSize: 11, color: NjbColors.textMuted), overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        _slider('Volumen', a.volume, 0, 2, (v) => a.volume = v),
        _slider('Entrada suave', a.fadeIn, 0, 5, (v) => a.fadeIn = v, show: (v) => '${v.toStringAsFixed(1)} s'),
        _slider('Salida suave', a.fadeOut, 0, 5, (v) => a.fadeOut = v, show: (v) => '${v.toStringAsFixed(1)} s'),
        _slider('Empezar el archivo desde', a.offset, 0, math.max(0.1, a.fileDuration - 0.5), (v) {
          a.offset = v;
          final maxLen = a.maxLength;
          if (a.end - a.start > maxLen) a.end = a.start + maxLen;
        }, show: fmt),
        _NumField(
          key: ValueKey('dur_${a.id}'),
          label: 'Duración del clip (s)',
          value: a.end - a.start,
          onSubmit: (v) {
            onChanged(true);
            final len = v.clamp(0.2, math.min(a.maxLength, project.duration - a.start));
            a.end = a.start + len;
            onChanged(false);
          },
        ),
        _switch('Repetir el sonido hasta cubrir la duración', a.loop, (v) {
          a.loop = v;
          if (!v && a.end - a.start > a.maxLength) a.end = a.start + a.maxLength;
        }),
        const SizedBox(height: 4),
        SegmentedButton<AudioKind>(
          style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: const TextStyle(fontSize: 12)),
          segments: const [
            ButtonSegment(value: AudioKind.narration, label: Text('Narración')),
            ButtonSegment(value: AudioKind.music, label: Text('Música')),
            ButtonSegment(value: AudioKind.sfx, label: Text('Efecto')),
          ],
          selected: {a.audioKind},
          onSelectionChanged: (v) {
            onChanged(true);
            a.audioKind = v.first;
            onChanged(false);
          },
        ),
        const SizedBox(height: 4),
        const Text('Con "Narración", el audio original baja mientras suena.', style: TextStyle(fontSize: 11.5, color: NjbColors.textMuted)),
      ];
}

class _NumField extends StatefulWidget {
  const _NumField({super.key, required this.label, required this.value, required this.onSubmit});
  final String label;
  final double value;
  final ValueChanged<double> onSubmit;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final _c = TextEditingController(text: widget.value.toStringAsFixed(2));
  final _focus = FocusNode();

  @override
  void didUpdateWidget(_NumField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) {
      _c.text = widget.value.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _apply() {
    final v = double.tryParse(_c.text.replaceAll(',', '.'));
    if (v != null) widget.onSubmit(v);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      focusNode: _focus,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(labelText: widget.label, isDense: true),
      onSubmitted: (_) => _apply(),
      onTapOutside: (_) {
        _apply();
        _focus.unfocus();
      },
    );
  }
}

class _TextArea extends StatefulWidget {
  const _TextArea({super.key, required this.value, required this.onChanged, required this.onFocusStart});
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onFocusStart;

  @override
  State<_TextArea> createState() => _TextAreaState();
}

class _TextAreaState extends State<_TextArea> {
  late final _c = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) widget.onFocusStart();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      focusNode: _focus,
      minLines: 2,
      maxLines: 4,
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(labelText: 'Texto', isDense: true),
      onChanged: widget.onChanged,
    );
  }
}

// ---------------------------------------------------------------------------
// Diálogo de efectos de sonido
// ---------------------------------------------------------------------------

class _SfxDialog extends StatefulWidget {
  const _SfxDialog({required this.library});
  final SfxLibrary library;

  @override
  State<_SfxDialog> createState() => _SfxDialogState();
}

class _SfxDialogState extends State<_SfxDialog> {
  List<SfxItem>? _items;
  String _filter = '';
  String? _playingPath;
  final Player _preview = Player();
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _preview.stream.completed.listen((done) {
      if (done && mounted) setState(() => _playingPath = null);
    });
    _load();
  }

  Future<void> _load() async {
    await widget.library.ensureBuiltins();
    final items = await widget.library.list();
    if (mounted) setState(() => _items = items);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _preview.dispose();
    super.dispose();
  }

  Future<void> _togglePreview(SfxItem item) async {
    if (_playingPath == item.path) {
      await _preview.stop();
      setState(() => _playingPath = null);
      return;
    }
    setState(() => _playingPath = item.path);
    await _preview.open(Media(item.path), play: true);
  }

  String _fmt(double s) => s >= 10 ? '${s.toStringAsFixed(0)} s' : '${s.toStringAsFixed(1)} s';

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final filtered = items?.where((i) => i.name.toLowerCase().contains(_filter.toLowerCase())).toList();
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.surround_sound_rounded, color: NjbColors.cyan),
        const SizedBox(width: 10),
        const Expanded(child: Text('Efectos de sonido')),
        TextButton.icon(
          onPressed: () => LibraryActions.openFolder(widget.library.folder),
          icon: const Icon(Icons.folder_open_rounded, size: 16),
          label: const Text('Carpeta', style: TextStyle(fontSize: 12)),
        ),
        TextButton.icon(
          onPressed: () => Process.start('explorer.exe', ['https://pixabay.com/es/sound-effects/']),
          icon: const Icon(Icons.download_rounded, size: 16),
          label: const Text('Más efectos gratis', style: TextStyle(fontSize: 12)),
        ),
      ]),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Buscar…', isDense: true),
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 8),
          const Text(
            'Copiá tus propios MP3/WAV en la carpeta "Efectos" y aparecen acá. Los incluidos están sintetizados.',
            style: TextStyle(fontSize: 11.5, color: NjbColors.textMuted),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: items == null
                ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 10),
                    Text('Preparando efectos…', style: TextStyle(color: NjbColors.textMuted)),
                  ]))
                : filtered!.isEmpty
                    ? const Center(child: Text('Sin resultados', style: TextStyle(color: NjbColors.textMuted)))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final it = filtered[i];
                          final playing = _playingPath == it.path;
                          return ListTile(
                            dense: true,
                            leading: IconButton(
                              tooltip: playing ? 'Detener' : 'Escuchar',
                              onPressed: () => _togglePreview(it),
                              icon: Icon(playing ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded,
                                  color: playing ? NjbColors.red : NjbColors.cyan, size: 28),
                            ),
                            title: Text(it.name),
                            subtitle: Text(it.builtin ? 'Incluido · ${_fmt(it.duration)}' : 'Mío · ${_fmt(it.duration)}',
                                style: const TextStyle(fontSize: 11, color: NjbColors.textMuted)),
                            trailing: FilledButton.tonal(
                              onPressed: () => Navigator.pop(context, it),
                              child: const Text('Agregar'),
                            ),
                            onTap: () => Navigator.pop(context, it),
                          );
                        },
                      ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Diálogo de exportación
// ---------------------------------------------------------------------------

class _ExportChoice {
  _ExportChoice(this.name, this.options);
  final String name;
  final ExportOptions options;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.defaultName});
  final String defaultName;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final _name = TextEditingController(text: widget.defaultName);
  ExportFormat _format = ExportFormat.mp4;
  int _quality = 20;
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
      title: const Text('Exportar'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            const SizedBox(height: 12),
            if (_format == ExportFormat.mp4)
              DropdownButtonFormField<int>(
                initialValue: _quality,
                decoration: const InputDecoration(labelText: 'Calidad'),
                items: const [
                  DropdownMenuItem(value: 26, child: Text('Ligera (archivo chico)')),
                  DropdownMenuItem(value: 20, child: Text('Alta (recomendada)')),
                  DropdownMenuItem(value: 16, child: Text('Máxima')),
                ],
                onChanged: (v) => setState(() => _quality = v ?? 20),
              ),
            if (_format == ExportFormat.gif)
              Row(children: [
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
              ]),
            const SizedBox(height: 8),
            const Text('Se aplican los cortes, narraciones, música, textos, imágenes y fundidos del proyecto.',
                style: TextStyle(fontSize: 12, color: NjbColors.textMuted)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _ExportChoice(
              _name.text.trim().isEmpty ? widget.defaultName : _name.text.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
              ExportOptions(format: _format, quality: _quality, gifFps: _gifFps, gifWidth: _gifWidth),
            ),
          ),
          child: const Text('Exportar'),
        ),
      ],
    );
  }
}
