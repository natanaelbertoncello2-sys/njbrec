import 'package:flutter/services.dart';

/// Monitor físico detectado por Windows (coordenadas en píxeles reales).
class MonitorInfo {
  const MonitorInfo({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.primary,
  });

  final int id;
  final String name;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool primary;

  String get label =>
      'Monitor ${id + 1}${primary ? ' (principal)' : ''} · ${width}x$height';
}

class ScreenLayout {
  const ScreenLayout({required this.monitors, required this.virtualRect});

  final List<MonitorInfo> monitors;

  /// Rectángulo de todo el escritorio (todos los monitores).
  final Rect virtualRect;
}

/// Puente con el código C++ del runner (canal `njbrec/native`).
class NativeBridge {
  NativeBridge._();

  static const _channel = MethodChannel('njbrec/native');

  /// Comienza a grabar el audio del sistema en [wavPath].
  static Future<void> loopbackStart(String wavPath) async {
    await _channel.invokeMethod<bool>('loopbackStart', {'path': wavPath});
  }

  static Future<void> loopbackStop() async {
    await _channel.invokeMethod<bool>('loopbackStop');
  }

  static Future<bool> loopbackIsRunning() async {
    return await _channel.invokeMethod<bool>('loopbackIsRunning') ?? false;
  }

  static Future<ScreenLayout> listMonitors() async {
    final raw = await _channel.invokeMethod<Map>('listMonitors');
    final monitors = <MonitorInfo>[];
    if (raw != null) {
      for (final m in (raw['monitors'] as List)) {
        final map = m as Map;
        monitors.add(MonitorInfo(
          id: (map['id'] as num).toInt(),
          name: map['name'] as String,
          x: (map['x'] as num).toInt(),
          y: (map['y'] as num).toInt(),
          width: (map['width'] as num).toInt(),
          height: (map['height'] as num).toInt(),
          primary: map['primary'] as bool,
        ));
      }
      final v = raw['virtual'] as Map;
      return ScreenLayout(
        monitors: monitors,
        virtualRect: Rect.fromLTWH(
          (v['x'] as num).toDouble(),
          (v['y'] as num).toDouble(),
          (v['width'] as num).toDouble(),
          (v['height'] as num).toDouble(),
        ),
      );
    }
    return const ScreenLayout(monitors: [], virtualRect: Rect.zero);
  }
}
