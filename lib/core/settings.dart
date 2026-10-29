import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

enum CaptureMode { desktop, monitor, region }

enum VideoQuality { low, medium, high, ultra }

extension VideoQualityX on VideoQuality {
  String get label => switch (this) {
        VideoQuality.low => 'Ligera',
        VideoQuality.medium => 'Equilibrada',
        VideoQuality.high => 'Alta',
        VideoQuality.ultra => 'Máxima',
      };

  /// Valor CRF/CQ aproximado (menor = más calidad).
  int get crf => switch (this) {
        VideoQuality.low => 30,
        VideoQuality.medium => 24,
        VideoQuality.high => 20,
        VideoQuality.ultra => 16,
      };
}

/// Qué se muestra mientras se graba.
enum RecordingOverlay { floatingBar, hidden }

/// Configuración persistente de la app.
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static Future<AppSettings> load() async {
    final s = AppSettings._();
    s._prefs = await SharedPreferences.getInstance();
    s._read();
    return s;
  }

  late SharedPreferences _prefs;

  CaptureMode captureMode = CaptureMode.desktop;
  int monitorIndex = 0;
  int regionX = 0;
  int regionY = 0;
  int regionW = 1280;
  int regionH = 720;
  int fps = 30;
  VideoQuality quality = VideoQuality.medium;
  String encoder = 'libx264';
  bool captureCursor = true;
  bool captureGpu = false;

  bool micEnabled = true;
  String? micDevice;
  double micVolume = 1.0;
  bool systemAudioEnabled = true;
  double systemVolume = 1.0;

  String outputDir = '';
  RecordingOverlay overlay = RecordingOverlay.floatingBar;
  int countdownSeconds = 3;
  bool openEditorAfterStop = true;
  bool hotkeysEnabled = true;
  String ffmpegPath = '';

  static String defaultOutputDir() {
    final home = Platform.environment['USERPROFILE'] ?? '';
    return p.join(home, 'Videos', 'NJB Rec');
  }

  void _read() {
    captureMode = CaptureMode.values[_prefs.getInt('captureMode') ?? 0];
    monitorIndex = _prefs.getInt('monitorIndex') ?? 0;
    regionX = _prefs.getInt('regionX') ?? 0;
    regionY = _prefs.getInt('regionY') ?? 0;
    regionW = _prefs.getInt('regionW') ?? 1280;
    regionH = _prefs.getInt('regionH') ?? 720;
    fps = _prefs.getInt('fps') ?? 30;
    quality = VideoQuality.values[_prefs.getInt('quality') ?? 1];
    encoder = _prefs.getString('encoder') ?? 'libx264';
    captureCursor = _prefs.getBool('captureCursor') ?? true;
    captureGpu = _prefs.getBool('captureGpu') ?? false;
    micEnabled = _prefs.getBool('micEnabled') ?? true;
    micDevice = _prefs.getString('micDevice');
    micVolume = _prefs.getDouble('micVolume') ?? 1.0;
    systemAudioEnabled = _prefs.getBool('systemAudioEnabled') ?? true;
    systemVolume = _prefs.getDouble('systemVolume') ?? 1.0;
    outputDir = _prefs.getString('outputDir') ?? defaultOutputDir();
    overlay = RecordingOverlay.values[_prefs.getInt('overlay') ?? 0];
    countdownSeconds = _prefs.getInt('countdownSeconds') ?? 3;
    openEditorAfterStop = _prefs.getBool('openEditorAfterStop') ?? true;
    hotkeysEnabled = _prefs.getBool('hotkeysEnabled') ?? true;
    ffmpegPath = _prefs.getString('ffmpegPath') ?? '';
  }

  Future<void> save() async {
    await Future.wait([
      _prefs.setInt('captureMode', captureMode.index),
      _prefs.setInt('monitorIndex', monitorIndex),
      _prefs.setInt('regionX', regionX),
      _prefs.setInt('regionY', regionY),
      _prefs.setInt('regionW', regionW),
      _prefs.setInt('regionH', regionH),
      _prefs.setInt('fps', fps),
      _prefs.setInt('quality', quality.index),
      _prefs.setString('encoder', encoder),
      _prefs.setBool('captureCursor', captureCursor),
      _prefs.setBool('captureGpu', captureGpu),
      _prefs.setBool('micEnabled', micEnabled),
      if (micDevice != null) _prefs.setString('micDevice', micDevice!),
      _prefs.setDouble('micVolume', micVolume),
      _prefs.setBool('systemAudioEnabled', systemAudioEnabled),
      _prefs.setDouble('systemVolume', systemVolume),
      _prefs.setString('outputDir', outputDir),
      _prefs.setInt('overlay', overlay.index),
      _prefs.setInt('countdownSeconds', countdownSeconds),
      _prefs.setBool('openEditorAfterStop', openEditorAfterStop),
      _prefs.setBool('hotkeysEnabled', hotkeysEnabled),
      _prefs.setString('ffmpegPath', ffmpegPath),
    ]);
    notifyListeners();
  }

  /// Aplica cambios y persiste.
  Future<void> update(void Function(AppSettings s) fn) async {
    fn(this);
    await save();
  }
}
