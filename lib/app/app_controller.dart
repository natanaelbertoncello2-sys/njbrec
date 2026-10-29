import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../core/ffmpeg.dart';
import '../core/hotkeys.dart';
import '../core/native_bridge.dart';
import '../core/recorder.dart';
import '../core/settings.dart';
import '../core/tray.dart';

enum WindowMode { normal, floating, hidden }

/// Orquesta ventana, bandeja, atajos y grabador.
class AppController extends ChangeNotifier with WindowListener {
  AppController(this.settings) : recorder = Recorder(settings);

  final AppSettings settings;
  final Recorder recorder;
  late final TrayController tray;

  WindowMode windowMode = WindowMode.normal;
  Rect? _normalBounds;
  bool _barHidden = false;
  bool ffmpegAvailable = false;
  bool ffmpegChecked = false;
  String ffmpegVersion = '';
  List<String> audioInputs = const [];
  List<String> encoders = const ['libx264'];

  /// Archivo recién guardado que la UI debería abrir en el editor.
  final _openEditor = StreamController<String>.broadcast();
  Stream<String> get openEditorRequests => _openEditor.stream;

  Future<void> init() async {
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    settings.addListener(notifyListeners);
    recorder.addListener(_onRecorderChanged);
    recorder.onFinished.listen(_onRecordingFinished);

    tray = TrayController(
      onShow: showWindow,
      onStartStop: toggleRecording,
      onPauseResume: () => recorder.togglePause(),
      onQuit: quit,
    );
    await tray.init();

    await refreshFfmpeg();
    await applyHotkeys();
  }

  Future<void> refreshFfmpeg() async {
    final ff = await Ffmpeg.locate(customPath: settings.ffmpegPath);
    ffmpegAvailable = ff != null;
    if (ff != null) {
      ffmpegVersion = await ff.version();
      audioInputs = await ff.listAudioInputs();
      encoders = await ff.listH264Encoders();
      if (settings.micDevice == null ||
          !audioInputs.contains(settings.micDevice)) {
        settings.micDevice = audioInputs.isNotEmpty ? audioInputs.first : null;
      }
      if (!encoders.contains(settings.encoder)) settings.encoder = 'libx264';
    }
    ffmpegChecked = true;
    notifyListeners();
  }

  Future<void> applyHotkeys() async {
    if (settings.hotkeysEnabled) {
      await Hotkeys.register(
        onStartStop: toggleRecording,
        onPauseResume: () => recorder.togglePause(),
        onToggleBar: toggleFloatingBar,
      );
    } else {
      await Hotkeys.unregister();
    }
  }

  // --------------------------------------------------------------- grabación

  RecState _lastState = RecState.idle;

  Future<void> toggleRecording() async {
    if (recorder.isActive) {
      await recorder.stop();
    } else if (recorder.state == RecState.idle) {
      await recorder.start();
    }
  }

  void _onRecorderChanged() {
    final s = recorder.state;
    if (s != _lastState) {
      _lastState = s;
      tray.update(s);
      _syncWindowMode(s);
    }
    notifyListeners();
  }

  Future<void> _syncWindowMode(RecState s) async {
    switch (s) {
      case RecState.recording:
        if (windowMode == WindowMode.normal) {
          if (settings.overlay == RecordingOverlay.floatingBar) {
            await enterFloatingMode();
          } else {
            await enterHiddenMode();
          }
        }
      case RecState.processing:
      case RecState.idle:
        if (windowMode != WindowMode.normal) await exitFloatingMode();
      default:
        break;
    }
  }

  void _onRecordingFinished(String file) {
    if (settings.openEditorAfterStop) {
      _openEditor.add(file);
    }
  }

  // --------------------------------------------------------------- ventana

  static const floatingSize = Size(332, 64);

  Future<void> enterFloatingMode() async {
    _normalBounds = await windowManager.getBounds();
    windowMode = WindowMode.floating;
    _barHidden = false;
    notifyListeners();
    await windowManager.setMinimumSize(floatingSize);
    await windowManager.setResizable(false);
    await windowManager.setSize(floatingSize);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    // Arriba al centro del monitor principal.
    final layout = await NativeBridge.listMonitors();
    final primary = layout.monitors.where((m) => m.primary).firstOrNull ??
        layout.monitors.firstOrNull;
    final dpr = PlatformDispatcher.instance.views.first.devicePixelRatio;
    final screenW = primary == null ? 1920.0 : primary.width / dpr;
    final x = ((screenW - floatingSize.width) / 2).clamp(0.0, double.infinity);
    await windowManager.setPosition(Offset(x, 12));
    await windowManager.show();
  }

  Future<void> enterHiddenMode() async {
    _normalBounds = await windowManager.getBounds();
    windowMode = WindowMode.hidden;
    notifyListeners();
    await windowManager.hide();
  }

  Future<void> exitFloatingMode() async {
    windowMode = WindowMode.normal;
    _barHidden = false;
    notifyListeners();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setMinimumSize(const Size(860, 560));
    await windowManager.setResizable(true);
    final b = _normalBounds;
    if (b != null) {
      await windowManager.setBounds(b);
    } else {
      await windowManager.setSize(const Size(1100, 720));
      await windowManager.center();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// Ctrl+Shift+H: muestra/oculta la barra flotante mientras se graba.
  Future<void> toggleFloatingBar() async {
    if (!recorder.isActive) return;
    if (windowMode == WindowMode.hidden) {
      windowMode = WindowMode.floating;
      await enterFloatingMode();
      return;
    }
    if (windowMode == WindowMode.floating) {
      _barHidden = !_barHidden;
      if (_barHidden) {
        await windowManager.hide();
      } else {
        await windowManager.show();
      }
    }
  }

  Future<void> showWindow() async {
    if (recorder.isActive && windowMode != WindowMode.normal) {
      _barHidden = false;
      if (windowMode == WindowMode.hidden) windowMode = WindowMode.floating;
      await enterFloatingMode();
      return;
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    if (recorder.isActive) await recorder.discard();
    await Hotkeys.unregister();
    await tray.dispose();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  /// Pedido de cierre: la UI decide (muestra diálogo si graba).
  final _closeRequests = StreamController<void>.broadcast();
  Stream<void> get closeRequests => _closeRequests.stream;

  @override
  void onWindowClose() {
    _closeRequests.add(null);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    recorder.removeListener(_onRecorderChanged);
    _openEditor.close();
    _closeRequests.close();
    super.dispose();
  }
}
