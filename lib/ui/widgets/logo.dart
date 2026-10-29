import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Isotipo de NJB Rec dibujado en vectores (anillo degradado + punto REC).
class NjbLogo extends StatelessWidget {
  const NjbLogo({
    super.key,
    this.size = 64,
    this.withBackground = true,
    this.dotColor = NjbColors.red,
    this.paused = false,
  });

  final double size;
  final bool withBackground;
  final Color dotColor;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _LogoPainter(
        withBackground: withBackground,
        dotColor: dotColor,
        paused: paused,
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter({
    required this.withBackground,
    required this.dotColor,
    required this.paused,
  });

  final bool withBackground;
  final Color dotColor;
  final bool paused;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);

    if (withBackground) {
      final rrect = RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(s * 0.23),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1D1A36), Color(0xFF0C0A18)],
          ).createShader(Offset.zero & size),
      );
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawCircle(
        Offset(s * 0.25, s * 0.05),
        s * 0.45,
        Paint()
          ..color = NjbColors.violet.withValues(alpha: 0.28)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.12),
      );
      canvas.restore();
    }

    final rOut = s * 0.36;
    final rIn = s * 0.285;
    final ringWidth = rOut - rIn;
    final rMid = (rOut + rIn) / 2;

    // Sombra del anillo.
    canvas.drawCircle(
      c.translate(0, s * 0.02),
      rMid,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
    );

    // Anillo con degradado angular.
    canvas.drawCircle(
      c,
      rMid,
      Paint()
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: math.pi * 2,
          colors: const [
            NjbColors.violet,
            NjbColors.cyan,
            NjbColors.violet,
          ],
          stops: const [0, 0.5, 1],
          transform: const GradientRotation(math.pi),
        ).createShader(Rect.fromCircle(center: c, radius: rOut))
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth,
    );

    // Resplandor del punto.
    final rDot = s * 0.17;
    canvas.drawCircle(
      c,
      rDot * 1.25,
      Paint()
        ..color = dotColor.withValues(alpha: 0.45)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.05),
    );

    if (paused) {
      final bw = rDot * 0.55;
      final gap = rDot * 0.25;
      final paint = Paint()..color = dotColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(c.dx - gap - bw, c.dy - rDot, c.dx - gap, c.dy + rDot),
          Radius.circular(bw * 0.3),
        ),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(c.dx + gap, c.dy - rDot, c.dx + gap + bw, c.dy + rDot),
          Radius.circular(bw * 0.3),
        ),
        paint,
      );
    } else {
      canvas.drawCircle(c, rDot, Paint()..color = dotColor);
      canvas.drawOval(
        Rect.fromLTRB(c.dx - rDot * 0.55, c.dy - rDot * 0.8, c.dx + rDot * 0.1,
            c.dy - rDot * 0.15),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.5)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.012),
      );
    }
  }

  @override
  bool shouldRepaint(_LogoPainter old) =>
      old.withBackground != withBackground ||
      old.dotColor != dotColor ||
      old.paused != paused;
}

/// Logotipo completo: isotipo + "NJB REC".
class NjbWordmark extends StatelessWidget {
  const NjbWordmark({super.key, this.height = 40});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NjbLogo(size: height),
        SizedBox(width: height * 0.3),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'NJB',
              style: TextStyle(
                fontSize: height * 0.52,
                fontWeight: FontWeight.w800,
                height: 1,
                letterSpacing: height * 0.02,
                color: NjbColors.text,
              ),
            ),
            SizedBox(height: height * 0.06),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'REC',
                  style: TextStyle(
                    fontSize: height * 0.3,
                    fontWeight: FontWeight.w700,
                    height: 1,
                    letterSpacing: height * 0.06,
                    color: NjbColors.red,
                  ),
                ),
                SizedBox(width: height * 0.08),
                Container(
                  width: height * 0.14,
                  height: height * 0.14,
                  decoration: const BoxDecoration(
                    color: NjbColors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
