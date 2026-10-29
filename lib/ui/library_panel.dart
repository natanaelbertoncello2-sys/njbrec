import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app.dart';
import '../app/theme.dart';
import '../core/ffmpeg.dart';
import 'editor_page.dart';

/// Acciones compartidas sobre archivos de video.
class LibraryActions {
  LibraryActions._();

  static void openEditor(BuildContext context, String file) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(file: file)));
  }

  static Future<void> revealInExplorer(String file) async {
    await Process.start('explorer.exe', ['/select,', file]);
  }

  static Future<void> openExternally(String file) async {
    await Process.start('explorer.exe', [file]);
  }

  static Future<void> openFolder(String dir) async {
    await Directory(dir).create(recursive: true);
    await Process.start('explorer.exe', [dir]);
  }

  /// Miniatura en caché (temp/njbrec/thumbs).
  static Future<String?> thumbnailFor(String file) async {
    final ff = Ffmpeg.instance;
    if (ff == null) return null;
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'njbrec', 'thumbs'));
    await dir.create(recursive: true);
    final stat = await File(file).stat();
    final key = '${p.basenameWithoutExtension(file)}_${stat.modified.millisecondsSinceEpoch}_${stat.size}'
        .replaceAll(RegExp(r'[^\w\-]'), '_');
    final out = p.join(dir.path, '$key.jpg');
    if (await File(out).exists()) return out;
    final ok = await ff.thumbnail(file, out, at: const Duration(milliseconds: 500));
    return ok ? out : null;
  }

  static String formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String formatDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }
}

class LibraryPanel extends StatefulWidget {
  const LibraryPanel({super.key});

  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

class _LibraryPanelState extends State<LibraryPanel> {
  List<FileSystemEntity> _files = const [];
  String? _dir;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = AppScope.of(context);
    final dir = c.settings.outputDir;
    // Recarga al cambiar de carpeta o cuando termina una grabación.
    if (dir != _dir || c.recorder.lastOutputFile != _lastSeen) {
      _dir = dir;
      _lastSeen = c.recorder.lastOutputFile;
      _refresh();
    }
  }

  String? _lastSeen;

  Future<void> _refresh() async {
    final dir = Directory(_dir!);
    setState(() => _loading = true);
    var files = <FileSystemEntity>[];
    if (await dir.exists()) {
      files = await dir
          .list()
          .where((e) => e is File && const ['.mp4', '.mkv', '.webm', '.mov', '.gif'].contains(p.extension(e.path).toLowerCase()))
          .toList();
      final stats = <String, DateTime>{};
      for (final f in files) {
        stats[f.path] = (await f.stat()).modified;
      }
      files.sort((a, b) => stats[b.path]!.compareTo(stats[a.path]!));
    }
    if (mounted) {
      setState(() {
        _files = files;
        _loading = false;
      });
    }
  }

  Future<void> _delete(String file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar grabación'),
        content: Text('¿Eliminar "${p.basename(file)}"? Esta acción no se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NjbColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await File(file).delete();
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
          child: Row(
            children: [
              const Text('Videos', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => LibraryActions.openFolder(_dir!),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('Abrir carpeta'),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: _refresh, tooltip: 'Actualizar', icon: const Icon(Icons.refresh_rounded)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(_dir ?? '', style: const TextStyle(color: NjbColors.textMuted, fontSize: 12)),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _files.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.videocam_off_rounded, size: 56, color: NjbColors.textMuted),
                          SizedBox(height: 12),
                          Text('Todavía no hay grabaciones', style: TextStyle(color: NjbColors.textMuted)),
                        ],
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 300,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 1.15,
                      ),
                      itemCount: _files.length,
                      itemBuilder: (_, i) => _VideoCard(
                        file: _files[i].path,
                        onDelete: () => _delete(_files[i].path),
                      ),
                    ),
        ),
      ],
    );
  }
}

class _VideoCard extends StatefulWidget {
  const _VideoCard({required this.file, required this.onDelete});

  final String file;
  final VoidCallback onDelete;

  @override
  State<_VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<_VideoCard> {
  String? _thumb;
  FileStat? _stat;

  @override
  void initState() {
    super.initState();
    File(widget.file).stat().then((s) => mounted ? setState(() => _stat = s) : null);
    LibraryActions.thumbnailFor(widget.file).then((t) => mounted ? setState(() => _thumb = t) : null);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => LibraryActions.openEditor(context, widget.file),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Colors.black,
                child: _thumb == null
                    ? const Center(child: Icon(Icons.movie_rounded, color: NjbColors.textMuted, size: 40))
                    : Image.file(File(_thumb!), fit: BoxFit.cover),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.basename(widget.file), maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(
                          _stat == null ? '' : '${LibraryActions.formatDate(_stat!.modified)} · ${LibraryActions.formatSize(_stat!.size)}',
                          style: const TextStyle(color: NjbColors.textMuted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded, size: 18),
                    onSelected: (v) {
                      switch (v) {
                        case 'edit':
                          LibraryActions.openEditor(context, widget.file);
                        case 'play':
                          LibraryActions.openExternally(widget.file);
                        case 'reveal':
                          LibraryActions.revealInExplorer(widget.file);
                        case 'delete':
                          widget.onDelete();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.content_cut_rounded), title: Text('Editar'))),
                      PopupMenuItem(value: 'play', child: ListTile(leading: Icon(Icons.play_arrow_rounded), title: Text('Reproducir'))),
                      PopupMenuItem(value: 'reveal', child: ListTile(leading: Icon(Icons.folder_open_rounded), title: Text('Mostrar en carpeta'))),
                      PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline_rounded, color: NjbColors.red), title: Text('Eliminar'))),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
