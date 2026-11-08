import 'package:flutter/material.dart';

/// Palette from the prototype (`prototype/src/template.html`, `:root`).
abstract final class AppColors {
  static const page = Color(0xFF060D24);
  static const panel = Color(0xFF0C1736);
  static const line = Color(0xFF1C2B58);
  static const ink = Color(0xFFEAF1FF);
  static const muted = Color(0xFF93A6D1);
  static const cyan = Color(0xFF35E0FF);
  static const blue = Color(0xFF2F7DFF);
  static const green = Color(0xFF2FE07A);
  static const amber = Color(0xFFFFB547);
  static const red = Color(0xFFFF4D5E);
  static const violet = Color(0xFF8B5CFF);
  static const magenta = Color(0xFFE0359B);

  static const chrome = Color(0xE6081437); // rgba(8,20,55,.9)
  static const pill = Color(0xC7081848); // rgba(8,24,72,.78)
  static const pillBorder = Color(0x8C5AAAFF);

  // Category accents.
  static const train = Color(0xFF1F6FFF);
  static const flight = Color(0xFF7B45FF);
  static const traffic = Color(0xFFFF2E44);
  static const weather = Color(0xFF35E0FF);
  static const event = Color(0xFFFF2E8F);

  // Beam colours.
  static const beamTrain = Color(0xFF4FA3FF);
  static const beamFlight = Color(0xFFA07BFF);
  static const beamTraffic = Color(0xFFFF4D6A);
  static const beamWeather = Color(0xFF35E0FF);
  static const beamEvent = Color(0xFFFF4FB8);
}

/// Card styles per category (gradient, glow, badge colour).
class CardStyle {
  const CardStyle({
    required this.gradient,
    required this.glow,
    required this.edge,
    required this.badge,
    required this.iconBg,
    required this.iconFg,
  });

  final List<Color> gradient;
  final Color glow;
  final Color edge;
  final Color badge;
  final Gradient iconBg;
  final Color iconFg;

  static const train = CardStyle(
    gradient: [Color(0xED122E7A), Color(0xED091A4E)],
    glow: Color(0xCC2F7DFF),
    edge: Color(0xE678C8FF),
    badge: Color(0xFF1F6FFF),
    iconBg: LinearGradient(colors: [Color(0xFF3E8CFF), Color(0xFF1650E0)], begin: Alignment.topLeft, end: Alignment.bottomRight),
    iconFg: Colors.white,
  );
  static const flight = CardStyle(
    gradient: [Color(0xF0683EE2), Color(0xF03A1E96)],
    glow: Color(0xD97B45FF),
    edge: Color(0xE6BEA0FF),
    badge: Color(0xFF7B45FF),
    iconBg: LinearGradient(colors: [Color(0xFF9C7BFF), Color(0xFF5B2FE0)]),
    iconFg: Colors.white,
  );
  static const weather = CardStyle(
    gradient: [Color(0xF00E2260), Color(0xF0081440)],
    glow: Color(0xBF2FAAFF),
    edge: Color(0xE678D2FF),
    badge: Color(0xFF1F6FFF),
    iconBg: LinearGradient(colors: [Color(0xFF55B4FF), Color(0xFF1352E6)]),
    iconFg: Colors.white,
  );
  static const traffic = CardStyle(
    gradient: [Color(0xF0D62030), Color(0xF07A0A1A)],
    glow: Color(0xD9FF2E44),
    edge: Color(0xE6FF96A0),
    badge: Color(0xFFFF2E44),
    iconBg: LinearGradient(colors: [Colors.white, Colors.white]),
    iconFg: Color(0xFFFF2E44),
  );
  static const event = CardStyle(
    gradient: [Color(0xF0D4228C), Color(0xF0780E5C)],
    glow: Color(0xD9FF2E8F),
    edge: Color(0xE6FF96D2),
    badge: Color(0xFFFF2E8F),
    iconBg: LinearGradient(colors: [Colors.white, Colors.white]),
    iconFg: Color(0xFFE0359B),
  );
}
