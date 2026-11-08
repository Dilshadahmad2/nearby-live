import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A beam from the user to an object.
class Beam {
  const Beam({required this.key, required this.target, required this.colour, required this.on, required this.phase});
  final String key;
  final Offset? target;
  final Color colour;
  final bool on;
  final double phase;
}

class _Mote {
  _Mote(this.x, this.y, this.v, this.ph, this.r);
  double x, y;
  final double v, ph, r;
}

/// Everything the prototype drew on its HUD canvas: pulsing range ring with
/// radar sweep and ticks, beams with travelling sparks, the person marker,
/// floating particles and the plane's contrail.
class HudState {
  HudState() {
    final r = math.Random(11);
    for (var i = 0; i < 60; i++) {
      _motes.add(_Mote(r.nextDouble(), .34 + r.nextDouble() * .62, 6 + r.nextDouble() * 14, r.nextDouble() * 6, .6 + r.nextDouble() * 1.4));
    }
  }

  double t = 0;
  Offset? you;
  double ringRadius = 100;
  String rangeLabel = '5 KM';
  List<Beam> beams = const [];
  final Map<String, double> beamVis = {};
  final List<Offset> contrail = [];
  double contrailVis = 1;
  final List<_Mote> _motes = [];
  final _rng = math.Random(3);
  bool reduceMotion = false;

  void advance(double dt, Size size) {
    t += dt;
    for (final b in beams) {
      final v = beamVis[b.key] ?? 0;
      beamVis[b.key] = v + ((b.on ? 1 : 0) - v) * math.min(1.0, dt * 3);
    }
    for (final m in _motes) {
      m.y -= m.v * dt / math.max(1, size.height);
      if (m.y < .33) {
        m.y = .96;
        m.x = _rng.nextDouble();
      }
    }
  }
}

class HudPainter extends CustomPainter {
  HudPainter(this.state, {required Listenable repaint, this.scale = 1}) : super(repaint: repaint);

  final HudState state;

  /// Stage scale (screen width / 512).
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final you = state.you;
    if (you != null) {
      _ring(canvas, you, state.ringRadius);
      _beams(canvas, Offset(you.dx, you.dy - 95 * scale));
      _person(canvas, you);
    }
    if (!state.reduceMotion) _motes(canvas, size);
    _contrail(canvas);
  }

  void _ring(Canvas c, Offset center, double r) {
    final t = state.t;
    c.save();
    c.translate(center.dx, center.dy);
    c.scale(1, .48);
    final glow = Paint()
      ..blendMode = BlendMode.plus
      ..shader = ui.Gradient.radial(Offset.zero, r, const [
        Color(0x0028A0FF),
        Color(0x1F28A0FF),
        Color(0x525AE1FF),
      ], const [
        .15,
        .8,
        1,
      ]);
    c.drawCircle(Offset.zero, r, glow);

    // Radar sweep: 16 fading wedges trailing the leading edge.
    final a = t * 1.5;
    final rect = Rect.fromCircle(center: Offset.zero, radius: r);
    for (var i = 0; i < 16; i++) {
      final a0 = a - i * .055;
      final p = Paint()
        ..blendMode = BlendMode.plus
        ..color = Color.fromRGBO(90, 230, 255, .28 * (1 - i / 16));
      c.drawArc(rect, a0 - .055, .055, true, p);
    }

    // Dashed rotating ring.
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = const Color(0xF282EBFF);
    final circ = 2 * math.pi * r;
    const dashLen = 16.0, gap = 9.0;
    final offset = (t * 30) % (dashLen + gap);
    for (var s = -offset; s < circ; s += dashLen + gap) {
      final s0 = math.max(0.0, s), s1 = math.min(circ, s + dashLen);
      if (s1 <= s0) continue;
      c.drawArc(rect, s0 / r, (s1 - s0) / r, false, dash);
    }

    // Tick marks.
    final tick = Paint()
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < 48; i++) {
      final an = i / 48 * math.pi * 2 - t * .15;
      final major = i % 4 == 0;
      final r1 = r + 5, r2 = r + (major ? 15 : 9);
      tick.color = Color.fromRGBO(130, 235, 255, major ? .85 : .35);
      c.drawLine(Offset(math.cos(an) * r1, math.sin(an) * r1), Offset(math.cos(an) * r2, math.sin(an) * r2), tick);
    }

    // Two expanding pulse rings.
    for (var i = 0; i < 2; i++) {
      final p = ((t * .45) + i * .5) % 1;
      c.drawCircle(
        Offset.zero,
        14 + p * (r - 14),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Color.fromRGBO(160, 240, 255, (1 - p) * .9),
      );
    }
    c.restore();

    // "5 KM" label on the ring.
    final tp = TextPainter(
      text: TextSpan(
        text: state.rangeLabel,
        style: GoogleFonts.outfit(
          fontSize: 11 * scale.clamp(.8, 1.4),
          fontWeight: FontWeight.w700,
          color: const Color(0xFAC8F8FF),
          shadows: const [Shadow(color: Color(0xFF35E0FF), blurRadius: 8)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(center.dx + r * .78 - tp.width / 2, center.dy - r * .48 * .62 - 6 - tp.height));
  }

  void _beams(Canvas c, Offset src) {
    for (final b in state.beams) {
      final v = state.beamVis[b.key] ?? 0;
      final tgt = b.target;
      if (v < .02 || tgt == null) continue;
      final mid = Offset((src.dx + tgt.dx) / 2, math.min(src.dy, tgt.dy) - 50);
      final path = Path()
        ..moveTo(src.dx, src.dy)
        ..quadraticBezierTo(mid.dx, mid.dy, tgt.dx, tgt.dy);
      c.drawPath(
        path,
        Paint()
          ..blendMode = BlendMode.plus
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 6
          ..color = b.colour.withValues(alpha: v * .3),
      );
      // Moving dashes.
      final dash = Paint()
        ..blendMode = BlendMode.plus
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.5
        ..color = b.colour.withValues(alpha: v * .95);
      for (final metric in path.computeMetrics()) {
        final off = (state.t * 40) % 9;
        for (var d = off; d < metric.length; d += 9) {
          c.drawPath(metric.extractPath(d, math.min(metric.length, d + 3)), dash);
        }
      }
      // Travelling spark.
      final u = (state.t * .55 + b.phase) % 1, iu = 1 - u;
      final p = Offset(
        iu * iu * src.dx + 2 * iu * u * mid.dx + u * u * tgt.dx,
        iu * iu * src.dy + 2 * iu * u * mid.dy + u * u * tgt.dy,
      );
      c.drawCircle(p, 6, Paint()
        ..blendMode = BlendMode.plus
        ..color = b.colour.withValues(alpha: v * .5));
      c.drawCircle(p, 2.2, Paint()..color = Colors.white.withValues(alpha: v));
    }
  }

  void _person(Canvas c, Offset at) {
    c.save();
    c.translate(at.dx, at.dy);
    c.scale(.82 * scale.clamp(.8, 1.3));
    void rr(double x, double y, double w, double h, double r, Color col) =>
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)), Paint()..color = col);
    c.drawOval(Rect.fromCenter(center: const Offset(0, 2), width: 30, height: 10), Paint()..color = const Color(0x73001440));
    rr(-8, -36, 7, 36, 2.5, const Color(0xFF2453A0));
    rr(1, -36, 7, 36, 2.5, const Color(0xFF2453A0));
    c.drawRect(const Rect.fromLTWH(-9, -3, 8, 3), Paint()..color = const Color(0xFFFF6A3D));
    c.drawRect(const Rect.fromLTWH(1, -3, 8, 3), Paint()..color = const Color(0xFFFF6A3D));
    rr(-13, -72, 26, 40, 7, const Color(0xFF2B2F3A));
    rr(-10, -68, 20, 26, 5, const Color(0xFF14161C));
    c.drawRect(const Rect.fromLTWH(-10, -50, 20, 1.6), Paint()..color = const Color(0xFF35E0FF));
    c.drawCircle(const Offset(0, -80), 8, Paint()..color = const Color(0xFFD9A37A));
    c.drawCircle(const Offset(0, -81), 7.8, Paint()..color = const Color(0xFF14161C));
    c.restore();
  }

  void _motes(Canvas c, Size size) {
    final p = Paint()..blendMode = BlendMode.plus;
    for (final m in state._motes) {
      p.color = Color.fromRGBO(130, 235, 255, (.3 + .35 * math.sin(state.t * 3 + m.ph)).clamp(0.0, 1.0));
      c.drawCircle(Offset(m.x * size.width + math.sin(state.t + m.ph) * 3, m.y * size.height), m.r, p);
    }
  }

  void _contrail(Canvas c) {
    final trail = state.contrail;
    if (trail.length < 2) return;
    final vis = state.contrailVis;
    for (var i = 1; i < trail.length; i++) {
      final f = i / trail.length;
      c.drawLine(
        trail[i - 1],
        trail[i],
        Paint()
          ..blendMode = BlendMode.plus
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 7 * f
          ..color = Color.fromRGBO(160, 110, 255, f * .35 * vis),
      );
      c.drawLine(
        trail[i - 1],
        trail[i],
        Paint()
          ..blendMode = BlendMode.plus
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1 + f * 3.5
          ..color = Color.fromRGBO(235, 245, 255, f * .75 * vis),
      );
    }
  }

  @override
  bool shouldRepaint(covariant HudPainter old) => old.state != state || old.scale != scale;
}
