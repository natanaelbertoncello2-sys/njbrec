import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app/app.dart';
import '../app/theme.dart';
import '../core/recorder.dart';
import 'widgets/logo.dart';

/// Barra compacta siempre visible mientras se graba.
class FloatingBar extends StatefulWidget {
  const FloatingBar({super.key});

  @override
  State<FloatingBar> createState() => _FloatingBarState();
}

class _FloatingBarState extends State<FloatingBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final rec = c.recorder;
    final paused = rec.state == RecState.paused;

    return Scaffold(
      backgroundColor: NjbColors.bgElevated,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => windowManager.startDragging(),
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [NjbColors.surface, NjbColors.bgElevated],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: NjbColors.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              NjbLogo(
                size: 30,
                paused: paused,
                dotColor: paused ? NjbColors.amber : NjbColors.red,
              ),
              const SizedBox(width: 10),
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) => Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: paused
                        ? NjbColors.amber
                        : NjbColors.red.withValues(
                            alpha: 0.45 + 0.55 * _pulse.value),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _fmt(rec.elapsed),
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                paused ? 'PAUSA' : 'REC',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: paused ? NjbColors.amber : NjbColors.red,
                ),
              ),
              const Spacer(),
              _Btn(
                tooltip: paused ? 'Reanudar (Ctrl+Shift+P)' : 'Pausar (Ctrl+Shift+P)',
                icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: NjbColors.amber,
                onTap: () => rec.togglePause(),
              ),
              const SizedBox(width: 4),
              _Btn(
                tooltip: 'Detener y guardar (Ctrl+Shift+R)',
                icon: Icons.stop_rounded,
                color: NjbColors.red,
                filled: true,
                onTap: () => rec.stop(),
              ),
              const SizedBox(width: 4),
              _Btn(
                tooltip: 'Ocultar barra (Ctrl+Shift+H para volver)',
                icon: Icons.visibility_off_rounded,
                color: NjbColors.textMuted,
                onTap: () => c.toggleFloatingBar(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
    this.filled = false,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled ? color : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 20, color: filled ? Colors.white : color),
          ),
        ),
      ),
    );
  }
}
