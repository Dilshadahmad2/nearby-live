import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';

/// Teardrop map pin with a glyph, popping in with a springy scale.
class MapPin extends StatelessWidget {
  const MapPin({super.key, required this.colour, required this.icon, required this.shown, this.size = 30});

  final Color colour;
  final IconData icon;
  final bool shown;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: shown ? 1 : 0,
      duration: const Duration(milliseconds: 350),
      child: AnimatedScale(
        scale: shown ? 1 : 0,
        alignment: Alignment.bottomCenter,
        duration: const Duration(milliseconds: 500),
        curve: Curves.elasticOut,
        child: SizedBox(
          width: size,
          height: size * 4 / 3,
          child: CustomPaint(
            painter: _PinPainter(colour),
            child: Align(
              alignment: const Alignment(0, -.45),
              child: Icon(icon, size: size * .5, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinPainter extends CustomPainter {
  _PinPainter(this.colour);
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 30;
    final path = Path()
      ..moveTo(15 * s, 39 * s)
      ..cubicTo(15 * s, 39 * s, 2 * s, 24.5 * s, 2 * s, 15 * s)
      ..arcToPoint(Offset(28 * s, 15 * s), radius: Radius.circular(13 * s))
      ..cubicTo(28 * s, 24.5 * s, 15 * s, 39 * s, 15 * s, 39 * s)
      ..close();
    canvas.drawShadow(path, colour, 6, false);
    canvas.drawPath(path, Paint()..color = colour.withValues(alpha: .45)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawPath(path, Paint()..color = colour);
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 * s
          ..color = const Color(0xD9FFFFFF));
  }

  @override
  bool shouldRepaint(covariant _PinPainter old) => old.colour != colour;
}

/// Small coloured distance chip ("4.8 km").
class DistanceBadge extends StatelessWidget {
  const DistanceBadge({super.key, required this.text, required this.colour, this.scale = 1});
  final String text;
  final Color colour;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 2 * scale),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(7 * scale),
        boxShadow: [BoxShadow(color: colour.withValues(alpha: .7), blurRadius: 14)],
      ),
      child: Text(text, style: outfit(12 * scale, weight: FontWeight.w700)),
    );
  }
}

/// The "You" label under the person marker.
class YouLabel extends StatelessWidget {
  const YouLabel({super.key, this.scale = 1});
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(
        color: const Color(0xD9081437),
        borderRadius: BorderRadius.circular(12 * scale),
        border: Border.all(color: const Color(0x805AB4FF)),
        boxShadow: const [BoxShadow(color: Color(0xB33CAAFF), blurRadius: 16)],
      ),
      child: Text('You', style: outfit(15 * scale, weight: FontWeight.w600)),
    );
  }
}

/// Sky gradient with sun glow at the top of the map, vignette and the
/// scanline / scan-sweep effect from the prototype.
class SkyOverlay extends StatelessWidget {
  const SkyOverlay({super.key, required this.height});
  final double height;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: Stack(children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF0631B8), Color(0xFF1D6FF0), Color(0xD940A0FF), Color(0x5978C8FF), Color(0x0078C8FF)],
                  stops: [0, .3, .55, .8, 1],
                ),
              ),
            ),
          ),
          Positioned(
            right: -40,
            top: height * .45,
            width: 260,
            height: 180,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [Color(0xF2FFF8DC), Color(0x73FFE296), Color(0x00FFE296)],
                  stops: [0, .45, 1],
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class Vignette extends StatelessWidget {
  const Vignette({super.key});

  @override
  Widget build(BuildContext context) => const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, .2),
              radius: 1.1,
              colors: [Color(0x00020A30), Color(0x8C020A30)],
              stops: [.55, 1],
            ),
          ),
        ),
      );
}

/// Scanlines plus a soft sweep moving down every 6 s.
class ScanFx extends StatelessWidget {
  const ScanFx({super.key, required this.t, this.enabled = true});
  final double t;
  final bool enabled;

  @override
  Widget build(BuildContext context) => IgnorePointer(child: CustomPaint(painter: _ScanPainter(enabled ? t : null)));
}

class _ScanPainter extends CustomPainter {
  _ScanPainter(this.t);
  final double? t;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = const Color(0x09A0E6FF);
    for (var y = 0.0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), line);
    }
    final tt = t;
    if (tt == null) return;
    final p = (tt % 6) / 6;
    final y = -90 + p * (size.height + 180);
    canvas.drawRect(
      Rect.fromLTWH(0, y, size.width, 90),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x0078E6FF), Color(0x1478E6FF), Color(0x0078E6FF)],
        ).createShader(Rect.fromLTWH(0, y, size.width, 90)),
    );
  }

  @override
  bool shouldRepaint(covariant _ScanPainter old) => old.t != t;
}

/// Four swinging spotlight beams above an event stage.
class StageLights extends StatelessWidget {
  const StageLights({super.key, required this.t, required this.shown, this.height = 170});
  final double t;
  final bool shown;
  final double height;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 600),
        child: CustomPaint(size: Size(160, height), painter: _LightsPainter(t)),
      );
}

class _LightsPainter extends CustomPainter {
  _LightsPainter(this.t);
  final double t;

  static const _beams = [
    (Color(0xBFFF3CC8), -38.0, -8.0, 0.0),
    (Color(0xB33CDCFF), 12.0, -20.0, -.8),
    (Color(0xA6FFDC46), -14.0, 30.0, -1.6),
    (Color(0xBF965AFF), 36.0, 6.0, -2.2),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final base = Offset(size.width / 2, size.height);
    for (final (c, a, b, delay) in _beams) {
      // 2.6 s ease-in-out alternate swing between angles a and b.
      final phase = ((t - delay) / 2.6) % 2;
      final f = phase < 1 ? phase : 2 - phase;
      final e = .5 - math.cos(f * math.pi) / 2;
      final ang = (a + (b - a) * e) * math.pi / 180;
      canvas.save();
      canvas.translate(base.dx, base.dy);
      canvas.rotate(ang);
      final h = size.height;
      final path = Path()
        ..moveTo(-2.2, 0)
        ..lineTo(2.2, 0)
        ..lineTo(14, -h)
        ..lineTo(-14, -h)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..blendMode = BlendMode.plus
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [c, c.withValues(alpha: 0)],
            stops: const [0, .92],
          ).createShader(Rect.fromLTWH(-14, -h, 28, h)),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _LightsPainter old) => old.t != t;
}

/// Icon + colour for each overlay pin.
abstract final class PinStyle {
  static const train = (AppColors.train, Icons.train_rounded);
  static const flight = (AppColors.flight, Icons.flight_rounded);
  static const traffic = (AppColors.traffic, Icons.directions_car_rounded);
  static const event = (AppColors.event, Icons.music_note_rounded);
  static const you = (AppColors.blue, Icons.circle);
}
