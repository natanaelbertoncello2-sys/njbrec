import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// Atajos globales de NJB Rec (funcionan aunque la app no tenga el foco).
class Hotkeys {
  Hotkeys._();

  static final startStop = HotKey(
    key: PhysicalKeyboardKey.keyR,
    modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
    scope: HotKeyScope.system,
  );
  static final pauseResume = HotKey(
    key: PhysicalKeyboardKey.keyP,
    modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
    scope: HotKeyScope.system,
  );
  static final toggleBar = HotKey(
    key: PhysicalKeyboardKey.keyH,
    modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
    scope: HotKeyScope.system,
  );

  static const startStopLabel = 'Ctrl + Shift + R';
  static const pauseResumeLabel = 'Ctrl + Shift + P';
  static const toggleBarLabel = 'Ctrl + Shift + H';

  static bool _registered = false;

  static Future<void> register({
    required void Function() onStartStop,
    required void Function() onPauseResume,
    required void Function() onToggleBar,
  }) async {
    await unregister();
    await hotKeyManager.register(startStop, keyDownHandler: (_) => onStartStop());
    await hotKeyManager.register(pauseResume, keyDownHandler: (_) => onPauseResume());
    await hotKeyManager.register(toggleBar, keyDownHandler: (_) => onToggleBar());
    _registered = true;
  }

  static Future<void> unregister() async {
    if (!_registered) return;
    await hotKeyManager.unregisterAll();
    _registered = false;
  }
}
