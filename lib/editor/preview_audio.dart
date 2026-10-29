import 'package:media_kit/media_kit.dart';

import 'project.dart';

/// Reproduce los clips de audio del proyecto sincronizados con la posición
/// del video (vista previa aproximada; la mezcla final la hace ffmpeg).
class PreviewAudio {
  final Map<String, Player> _players = {};
  final Map<String, bool> _playing = {};

  Future<void> sync(EditorProject project, double pos, bool playing) async {
    final ids = project.audios.map((c) => c.id).toSet();
    // Eliminar reproductores de clips borrados.
    for (final id in _players.keys.toList()) {
      if (!ids.contains(id)) {
        await _players.remove(id)?.dispose();
        _playing.remove(id);
      }
    }
    for (final clip in project.audios) {
      final local = pos - clip.start;
      final inside = playing && local >= 0 && local < clip.duration && !project.isCut(pos);
      final player = _players.putIfAbsent(clip.id, () => Player());
      final wasPlaying = _playing[clip.id] ?? false;
      if (inside) {
        // Con repetición, la posición dentro del archivo vuelve a empezar.
        final span = clip.fileDuration - clip.offset;
        final inFile = clip.loop && span > 0 ? clip.offset + (local % span) : clip.offset + local;
        final target = Duration(milliseconds: (inFile * 1000).round());
        if (!wasPlaying) {
          await player.open(Media(clip.path), play: false);
          await player.setPlaylistMode(clip.loop ? PlaylistMode.loop : PlaylistMode.none);
          await player.setVolume((clip.volume * 100).clamp(0, 100));
          await player.seek(target);
          await player.play();
          _playing[clip.id] = true;
        } else {
          final drift = (player.state.position - target).inMilliseconds.abs();
          if (drift > 350 && !(clip.loop && drift > (span * 1000) - 400)) {
            await player.seek(target);
          }
          await player.setVolume((clip.volume * 100).clamp(0, 100));
        }
      } else if (wasPlaying) {
        await player.pause();
        _playing[clip.id] = false;
      }
    }
  }

  Future<void> pauseAll() async {
    for (final e in _players.entries) {
      await e.value.pause();
      _playing[e.key] = false;
    }
  }

  Future<void> dispose() async {
    for (final p in _players.values) {
      await p.dispose();
    }
    _players.clear();
  }
}
