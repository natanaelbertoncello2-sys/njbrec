// Verifica que el modelo del proyecto se serialice y que la lógica de cortes
// (mapeo de tiempos) sea correcta.
import 'package:flutter_test/flutter_test.dart';
import 'package:njbrec/editor/project.dart';

void main() {
  test('cortes: fusión y mapeo a tiempo de salida', () {
    final p = EditorProject(source: 'x.mp4', duration: 100);
    p.addCut(10, 20);
    p.addCut(15, 30); // se fusiona con el anterior
    p.addCut(50, 55);
    expect(p.cuts.length, 2);
    expect(p.cuts.first.start, 10);
    expect(p.cuts.first.end, 30);
    expect(p.outputDuration, 75);
    expect(p.toOutput(5), 5);
    expect(p.toOutput(25), 10); // dentro del corte → fin del tramo anterior
    expect(p.toOutput(40), 20);
    expect(p.toOutput(60), 35);
    expect(p.isCut(12), isTrue);
    expect(p.skipCut(12), 30);
    expect(p.skipCut(40), 40);
  });

  test('serialización ida y vuelta', () {
    final p = EditorProject(source: 'x.mp4', duration: 60);
    p.addCut(1, 2);
    p.clips.add(TextClip(id: 't', start: 0, end: 3, text: 'Hola\n"mundo"'));
    p.clips.add(ImageClip(id: 'i', start: 1, end: 4, path: 'C:\\logo.png'));
    p.clips.add(AudioClip(id: 'a', start: 2, end: 5, path: 'C:\\voz.m4a', fileDuration: 10, audioKind: AudioKind.narration));
    p.fadeOut = true;
    final copy = p.clone();
    expect(copy.encode(), p.encode());
    expect(copy.texts.first.text, 'Hola\n"mundo"');
    expect(copy.audios.first.audioKind, AudioKind.narration);
    expect(copy.cuts.length, 1);
    expect(copy.fadeOut, isTrue);
  });
}
