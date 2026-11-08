import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The prototype's airliner (200 × 200 viewBox, nose up) with blinking nav
/// lights, strobe and flickering exhaust. [t] is seconds of animation time.
class PlanePainter extends CustomPainter {
  PlanePainter({required this.t, this.shadow = false});

  final double t;

  /// Draw only the dark silhouette (ground shadow).
  final bool shadow;

  static final Path _fuselage = Path()
    ..moveTo(100, 14)
    ..cubicTo(108, 14, 110, 30, 110, 44)
    ..lineTo(110, 160)
    ..cubicTo(110, 174, 104, 186, 100, 191)
    ..cubicTo(96, 186, 90, 174, 90, 160)
    ..lineTo(90, 44)
    ..cubicTo(90, 30, 92, 14, 100, 14)
    ..close();

  static final Path _wings = Path()
    ..moveTo(100, 76)
    ..lineTo(16, 118)
    ..lineTo(16, 129)
    ..lineTo(100, 108)
    ..lineTo(184, 129)
    ..lineTo(184, 118)
    ..close();

  static final Path _tail = Path()
    ..moveTo(100, 158)
    ..lineTo(68, 176)
    ..lineTo(68, 183)
    ..lineTo(100, 175)
    ..lineTo(132, 183)
    ..lineTo(132, 176)
    ..close();

  static final Path _shadow = Path()
    ..moveTo(100, 14)
    ..cubicTo(108, 14, 110, 30, 110, 44)
    ..lineTo(110, 78)
    ..lineTo(182, 118)
    ..lineTo(182, 128)
    ..lineTo(110, 108)
    ..lineTo(110, 160)
    ..lineTo(130, 176)
    ..lineTo(130, 182)
    ..lineTo(100, 175)
    ..lineTo(70, 182)
    ..lineTo(70, 176)
    ..lineTo(90, 160)
    ..lineTo(90, 108)
    ..lineTo(18, 128)
    ..lineTo(18, 118)
    ..lineTo(90, 78)
    ..lineTo(90, 44)
    ..cubicTo(90, 30, 92, 14, 100, 14)
    ..close();

  static const _livery = [Color(0xFFFF3D7F), Color(0xFFA23BFF), Color(0xFF2F7DFF)];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 200, size.height / 200);
    if (shadow) {
      canvas.drawPath(_shadow, Paint()..color = const Color(0xFF020A26));
      canvas.restore();
      return;
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = const Color(0xFF7F8FA8);

    // Exhaust glow.
    final flicker = .55 + .45 * (math.sin(t * 52) * .5 + .5);
    for (final x in const [60.5, 139.5]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, 121), width: 12, height: 18),
        Paint()
          ..shader = ui.Gradient.radial(Offset(x, 121), 9, [
            Color.fromRGBO(255, 242, 192, flicker),
            Color.fromRGBO(255, 165, 58, flicker),
            const Color(0x00FF7828),
          ], const [
            0,
            .5,
            1,
          ]),
      );
    }

    final wingShader = ui.Gradient.linear(const Offset(0, 76), const Offset(0, 129), const [Color(0xFFF1F5FB), Color(0xFF9FB1C9)]);
    canvas.drawPath(_wings, Paint()..shader = wingShader);
    canvas.drawPath(_wings, stroke);
    final liv = ui.Gradient.linear(const Offset(0, 110), const Offset(0, 129), _livery, const [0, .5, 1]);
    canvas.drawPath(
        Path()
          ..moveTo(16, 118)
          ..lineTo(32, 110)
          ..lineTo(32, 125)
          ..lineTo(16, 129)
          ..close(),
        Paint()..shader = liv);
    canvas.drawPath(
        Path()
          ..moveTo(184, 118)
          ..lineTo(168, 110)
          ..lineTo(168, 125)
          ..lineTo(184, 129)
          ..close(),
        Paint()..shader = liv);
    canvas.drawPath(
        Path()
          ..moveTo(40, 106)
          ..lineTo(100, 82)
          ..lineTo(160, 106),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xB3FFFFFF));

    // Engines.
    for (final x in const [56.0, 135.0]) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 94, 9, 22), const Radius.circular(4.5)),
          Paint()..color = const Color(0xFF4B5B78));
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + 1.5, 94, 6, 4), const Radius.circular(2)),
          Paint()..color = const Color(0xFFA9B8D0));
    }

    canvas.drawPath(_tail, Paint()..shader = wingShader);
    canvas.drawPath(_tail, stroke);

    final fus = ui.Gradient.linear(
        const Offset(90, 0), const Offset(110, 0), const [Color(0xFFC9D4E6), Color(0xFFFFFFFF), Color(0xFFB3C0D6)], const [0, .5, 1]);
    canvas.drawPath(_fuselage, Paint()..shader = fus);
    canvas.drawPath(_fuselage, stroke..color = const Color(0xFF8796AE));
    canvas.drawPath(
        Path()
          ..moveTo(97, 42)
          ..lineTo(97, 172)
          ..quadraticBezierTo(100, 182, 103, 172)
          ..lineTo(103, 42)
          ..close(),
        Paint()..shader = ui.Gradient.linear(const Offset(0, 42), const Offset(0, 182), _livery, const [0, .5, 1]));
    // Cockpit.
    canvas.drawPath(
        Path()
          ..moveTo(93.5, 27)
          ..quadraticBezierTo(100, 19, 106.5, 27)
          ..lineTo(105.5, 33)
          ..quadraticBezierTo(100, 29, 94.5, 33)
          ..close(),
        Paint()..color = const Color(0xFF14204A));
    canvas.drawPath(
        Path()
          ..moveTo(98, 148)
          ..lineTo(100, 189)
          ..lineTo(102, 148)
          ..close(),
        Paint()..color = const Color(0xFF7B2FF7));

    // Nav lights (left red, right green, alternating) and the strobe.
    double blink(double phase) => ((t + phase) % 1.1) / 1.1 <= .6 ? 1.0 : .15;
    canvas.drawCircle(const Offset(16, 124), 3.4, Paint()..color = const Color(0xFFFF3B3B).withValues(alpha: blink(0)));
    canvas.drawCircle(const Offset(184, 124), 3.4, Paint()..color = const Color(0xFF2BFF88).withValues(alpha: blink(.55)));
    final strobe = (t % 1.4) / 1.4 <= .08;
    if (strobe) {
      canvas.drawCircle(const Offset(100, 62), 3, Paint()..color = Colors.white);
      canvas.drawCircle(const Offset(100, 62), 9, Paint()..color = const Color(0x55FFFFFF));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PlanePainter old) => old.t != t || old.shadow != shadow;
}
