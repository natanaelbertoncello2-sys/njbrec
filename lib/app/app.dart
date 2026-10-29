import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/editor_page.dart';
import '../ui/floating_bar.dart';
import '../ui/home_page.dart';
import 'app_controller.dart';
import 'theme.dart';

/// Punto de acceso al controlador desde cualquier widget.
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child})
      : super(notifier: controller);

  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class NjbApp extends StatefulWidget {
  const NjbApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<NjbApp> createState() => _NjbAppState();
}

class _NjbAppState extends State<NjbApp> {
  final _navKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _editorSub;
  StreamSubscription<void>? _closeSub;

  @override
  void initState() {
    super.initState();
    _editorSub = widget.controller.openEditorRequests.listen((file) {
      _navKey.currentState?.push(
        MaterialPageRoute(builder: (_) => EditorPage(file: file)),
      );
    });
    _closeSub = widget.controller.closeRequests.listen((_) => _onCloseRequest());
    widget.controller.addListener(_onControllerChanged);
  }

  WindowMode _lastMode = WindowMode.normal;

  void _onControllerChanged() {
    final mode = widget.controller.windowMode;
    if (mode != _lastMode) {
      _lastMode = mode;
      if (mode == WindowMode.floating) {
        // La barra flotante vive en la raíz: cerramos páginas abiertas.
        _navKey.currentState?.popUntil((r) => r.isFirst);
      }
    }
  }

  Future<void> _onCloseRequest() async {
    final c = widget.controller;
    final ctx = _navKey.currentContext;
    if (!c.recorder.isActive || ctx == null) {
      await c.quit();
      return;
    }
    final answer = await showDialog<String>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('Hay una grabación en curso'),
        content: const Text('¿Qué querés hacer antes de salir?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Seguir grabando'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Descartar y salir',
                style: TextStyle(color: NjbColors.red)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Guardar y salir'),
          ),
        ],
      ),
    );
    if (answer == 'save') {
      await c.recorder.stop();
      await c.quit();
    } else if (answer == 'discard') {
      await c.quit();
    }
  }

  @override
  void dispose() {
    _editorSub?.cancel();
    _closeSub?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: widget.controller,
      child: MaterialApp(
        title: 'NJB Rec',
        debugShowCheckedModeBanner: false,
        theme: buildNjbTheme(),
        navigatorKey: _navKey,
        home: const _Root(),
      ),
    );
  }
}

/// Decide qué mostrar según el modo de ventana.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    if (c.windowMode == WindowMode.floating) {
      return const FloatingBar();
    }
    return const HomePage();
  }
}
