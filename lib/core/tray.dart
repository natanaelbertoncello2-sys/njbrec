import 'package:tray_manager/tray_manager.dart';

import 'recorder.dart';

/// Icono en la bandeja del sistema con menú contextual.
class TrayController with TrayListener {
  TrayController({
    required this.onShow,
    required this.onStartStop,
    required this.onPauseResume,
    required this.onQuit,
  });

  final void Function() onShow;
  final void Function() onStartStop;
  final void Function() onPauseResume;
  final void Function() onQuit;

  RecState _last = RecState.idle;

  Future<void> init() async {
    trayManager.addListener(this);
    await trayManager.setIcon('assets/branding/tray_idle.ico');
    await trayManager.setToolTip('NJB Rec');
    await update(RecState.idle);
  }

  Future<void> update(RecState state) async {
    final icon = switch (state) {
      RecState.recording => 'assets/branding/tray_rec.ico',
      RecState.paused => 'assets/branding/tray_pause.ico',
      _ => 'assets/branding/tray_idle.ico',
    };
    if (state != _last) {
      await trayManager.setIcon(icon);
      await trayManager.setToolTip(switch (state) {
        RecState.recording => 'NJB Rec · Grabando',
        RecState.paused => 'NJB Rec · En pausa',
        RecState.processing => 'NJB Rec · Procesando…',
        _ => 'NJB Rec',
      });
    }
    _last = state;
    final active = state == RecState.recording || state == RecState.paused;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Mostrar NJB Rec'),
      MenuItem.separator(),
      MenuItem(
        key: 'startstop',
        label: active ? 'Detener grabación' : 'Iniciar grabación',
        disabled: state == RecState.processing || state == RecState.countdown,
      ),
      MenuItem(
        key: 'pause',
        label: state == RecState.paused ? 'Reanudar' : 'Pausar',
        disabled: !active,
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Salir'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => onShow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        onShow();
      case 'startstop':
        onStartStop();
      case 'pause':
        onPauseResume();
      case 'quit':
        onQuit();
    }
  }

  Future<void> dispose() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}
