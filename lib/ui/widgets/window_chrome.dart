import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/theme.dart';
import 'logo.dart';

/// Barra de título personalizada (arrastrable) con botones de ventana.
class WindowChrome extends StatelessWidget {
  const WindowChrome({super.key, this.title, this.leading, this.actions});

  final String? title;
  final Widget? leading;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    leading ?? const NjbLogo(size: 24),
                    const SizedBox(width: 10),
                    Text(
                      title ?? 'NJB Rec',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: NjbColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ...?actions,
          _WinButton(
            icon: Icons.remove_rounded,
            onTap: () => windowManager.minimize(),
          ),
          _WinButton(
            icon: Icons.crop_square_rounded,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _WinButton(
            icon: Icons.close_rounded,
            hoverColor: NjbColors.red,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

class _WinButton extends StatefulWidget {
  const _WinButton({required this.icon, required this.onTap, this.hoverColor});

  final IconData icon;
  final VoidCallback onTap;
  final Color? hoverColor;

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 46,
          height: 48,
          color: _hover
              ? (widget.hoverColor ?? NjbColors.surfaceHigh)
              : Colors.transparent,
          child: Icon(widget.icon, size: 18, color: NjbColors.text),
        ),
      ),
    );
  }
}
