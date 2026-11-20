import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../weather/weather.dart';

/// The prototype's weather illustration (150 × 150 viewBox): holo beam and
/// pulsing base ring, sun with rotating rays, bobbing cloud and rain drops.
/// The variant follows the live weather code.
class WeatherPainter extends CustomPainter {
  WeatherPainter({required this.t, required this.visual});

  final double t;
  final WeatherVisual visual;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 150, size.height / 150);

    // Holo beam and base ring.
    canvas.drawPath(
      Path()
        ..moveTo(58, 138)
        ..lineTo(92, 138)
        ..lineTo(104, 70)
        ..lineTo(46, 70)
        ..close(),
      Paint()
        ..shader = ui.Gradient.linear(const Offset(0, 138), const Offset(0, 70), const [Color(0xB33CDCFF), Color(0x003CDCFF)]),
    );
    final base = Rect.fromCenter(center: const Offset(75, 138), width: 60, height: 18);
    canvas.drawOval(base, Paint()..color = const Color(0x4050DCFF));
    canvas.drawOval(
        base,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF5FE8FF));
    final pulse = (t % 2.2) / 2.2;
    final ps = .6 + pulse;
    canvas.drawOval(
        Rect.fromCenter(center: const Offset(75, 138), width: 60 * ps, height: 18 * ps),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF9FF3FF).withValues(alpha: 1 - pulse));

    final hasSun = visual == WeatherVisual.sun || visual == WeatherVisual.partlyCloudy;
    final hasCloud = visual != WeatherVisual.sun;
    final dark = visual == WeatherVisual.storm || visual == WeatherVisual.rain;

    if (hasSun) {
      final sunC = visual == WeatherVisual.sun ? const Offset(75, 70) : const Offset(58, 56);
      canvas.drawCircle(
          sunC,
          40,
          Paint()
            ..shader = ui.Gradient.radial(sunC, 40, const [Color(0xD9FFDC5A), Color(0x00FFDC5A)]));
      canvas.save();
      canvas.translate(sunC.dx, sunC.dy);
      canvas.rotate(t * 2 * math.pi / 14);
      final ray = Paint()
        ..color = const Color(0xFFFFD23F)
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 8; i++) {
        final a = i * math.pi / 4;
        canvas.drawLine(Offset(math.cos(a) * 26, math.sin(a) * 26), Offset(math.cos(a) * 34, math.sin(a) * 34), ray);
      }
      canvas.restore();
      canvas.drawCircle(
          sunC,
          21,
          Paint()
            ..shader = ui.Gradient.radial(sunC.translate(-4, -6), 24, const [Color(0xFFFFF7B0), Color(0xFFFFC21A), Color(0xFFFF8A00)],
                const [0, .55, 1]));
    }

    if (hasCloud) {
      final bob = math.sin(t * 2 * math.pi / 4) * 2 - 2;
      canvas.save();
      canvas.translate(0, bob);
      canvas.drawOval(Rect.fromCenter(center: const Offset(82, 94), width: 88, height: 18), Paint()..color = const Color(0x806EA0E6));
      final top = dark ? const Color(0xFFB8C6DE) : Colors.white;
      final bottom = dark ? const Color(0xFF6E86AD) : const Color(0xFFA9CDF5);
      final cloud = Paint()
        ..shader = ui.Gradient.linear(const Offset(0, 46), const Offset(0, 96), [top, Color.lerp(top, bottom, .5)!, bottom], const [0, .7, 1]);
      final path = Path()
        ..addOval(Rect.fromCircle(center: const Offset(62, 80), radius: 16))
        ..addOval(Rect.fromCircle(center: const Offset(84, 68), radius: 22))
        ..addOval(Rect.fromCircle(center: const Offset(106, 80), radius: 16))
        ..addOval(Rect.fromCircle(center: const Offset(44, 88), radius: 10))
        ..addOval(Rect.fromCircle(center: const Offset(120, 88), radius: 10))
        ..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(40, 78, 88, 18), const Radius.circular(9)));
      canvas.drawPath(path, cloud);
      canvas.drawArc(Rect.fromCircle(center: const Offset(84, 72), radius: 18), math.pi * 1.1, math.pi * .45, false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xE6FFFFFF));
      canvas.restore();
    }

    if (visual == WeatherVisual.rain || visual == WeatherVisual.storm || visual == WeatherVisual.partlyCloudy) {
      final drop = Paint()..color = const Color(0xFF5FD0FF);
      final n = visual == WeatherVisual.partlyCloudy ? 3 : 5;
      for (var i = 0; i < n; i++) {
        final x = n == 3 ? 64.0 + i * 20 : 56.0 + i * 14;
        final p = ((t + i * .35) % 1);
        final y = 104 - 6 + p * 28;
        final a = p < .2 ? p / .2 : 1 - (p - .2) / .8;
        drop.color = const Color(0xFF5FD0FF).withValues(alpha: a.clamp(0.0, 1.0));
        canvas.drawPath(
            Path()
              ..moveTo(x, y)
              ..lineTo(x - 3, y + 7)
              ..arcToPoint(Offset(x + 3, y + 7), radius: const Radius.circular(3), clockwise: false)
              ..close(),
            drop);
      }
    }

    if (visual == WeatherVisual.storm && (t % 2.6) < .12) {
      canvas.drawPath(
          Path()
            ..moveTo(86, 96)
            ..lineTo(76, 114)
            ..lineTo(84, 114)
            ..lineTo(74, 132)
            ..lineTo(94, 108)
            ..lineTo(85, 108)
            ..lineTo(92, 96)
            ..close(),
          Paint()..color = const Color(0xFFFFE14D));
    }

    if (visual == WeatherVisual.snow) {
      final flake = Paint()..color = Colors.white;
      for (var i = 0; i < 5; i++) {
        final p = ((t * .6 + i * .27) % 1);
        canvas.drawCircle(Offset(54.0 + i * 15 + math.sin(t * 2 + i) * 3, 102 + p * 30), 2.2, flake..color = Colors.white.withValues(alpha: 1 - p));
      }
    }

    if (visual == WeatherVisual.fog) {
      final fog = Paint()
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = const Color(0x99DDEBFF);
      for (var i = 0; i < 3; i++) {
        final dx = math.sin(t + i) * 6;
        canvas.drawLine(Offset(44 + dx, 104.0 + i * 9), Offset(110 + dx, 104.0 + i * 9), fog);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant WeatherPainter old) => old.t != t || old.visual != visual;
}
