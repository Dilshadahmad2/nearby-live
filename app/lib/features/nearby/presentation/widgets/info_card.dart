import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/geo/geo_utils.dart';
import '../../../../core/l10n.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../weather/weather.dart';
import '../../scene/scene.dart';

/// Glass card with sheen, coloured glow and a sweeping neon border. Shows with
/// a springy rise when [shown] turns true, fades away when it turns false.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.style,
    required this.shown,
    required this.t,
    required this.child,
    this.scale = 1,
    this.padding,
    this.onTap,
    this.semanticLabel,
  });

  final CardStyle style;
  final bool shown;
  final double t;
  final double scale;
  final Widget child;
  final EdgeInsets? padding;
  final VoidCallback? onTap;

  /// Read by screen readers instead of the card's individual texts.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14 * scale);
    final card = _build(radius);
    if (!shown) return ExcludeSemantics(child: card);
    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      onTap: onTap,
      child: card,
    );
  }

  Widget _build(BorderRadius radius) {
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
        child: AnimatedSlide(
          offset: shown ? Offset.zero : const Offset(0, .12),
          duration: const Duration(milliseconds: 600),
          curve: const Cubic(.2, 1.5, .4, 1),
          child: AnimatedScale(
            scale: shown ? 1 : .92,
            duration: const Duration(milliseconds: 600),
            curve: const Cubic(.2, 1.5, .4, 1),
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  gradient:
                      LinearGradient(colors: style.gradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
                  boxShadow: shown
                      ? [
                          BoxShadow(color: style.edge, spreadRadius: 1),
                          BoxShadow(color: style.glow, blurRadius: 26),
                          const BoxShadow(color: Color(0x80000A28), blurRadius: 30, offset: Offset(0, 12)),
                        ]
                      : const [],
                ),
                child: CustomPaint(
                  foregroundPainter: _SweepBorderPainter(t: t, radius: 14 * scale),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: Stack(children: [
                      const Positioned.fill(child: _Sheen()),
                      Padding(
                        padding: padding ?? EdgeInsets.fromLTRB(8 * scale, 8 * scale, 10 * scale, 8 * scale),
                        child: child,
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Sheen extends StatelessWidget {
  const _Sheen();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-1, -.6),
            end: Alignment(1, .6),
            colors: [Color(0x3DFFFFFF), Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0x1AFFFFFF)],
            stops: [0, .36, .72, 1],
          ),
        ),
      );
}

/// Conic highlight running around the card edge (3.2 s per lap).
class _SweepBorderPainter extends CustomPainter {
  _SweepBorderPainter({required this.t, required this.radius});
  final double t;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ang = (t / 3.2) % 1 * 2 * math.pi;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..shader = SweepGradient(
        colors: const [Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0xF2FFFFFF), Color(0x00FFFFFF), Color(0x00FFFFFF)],
        stops: const [0, .6, .75, .9, 1],
        transform: GradientRotation(ang - math.pi / 2),
      ).createShader(rect);
    canvas.drawRRect(RRect.fromRectAndRadius(rect.deflate(.75), Radius.circular(radius)), paint);
  }

  @override
  bool shouldRepaint(covariant _SweepBorderPainter old) => old.t != t;
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.text, this.scale);
  final String text;
  final double scale;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(6 * scale, 2 * scale, 8 * scale, 2 * scale),
        decoration: BoxDecoration(color: const Color(0x47000000), borderRadius: BorderRadius.circular(7 * scale)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 7 * scale,
            height: 7 * scale,
            decoration: const BoxDecoration(color: AppColors.green, shape: BoxShape.circle),
          ),
          SizedBox(width: 5 * scale),
          Text(text, style: outfit(10 * scale, weight: FontWeight.w600)),
        ]),
      );
}

class _KmChip extends StatelessWidget {
  const _KmChip(this.km, this.colour, this.scale);
  final double? km;
  final Color colour;
  final double scale;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 2 * scale),
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(7 * scale),
          boxShadow: const [BoxShadow(color: Color(0x2EFFFFFF), blurRadius: 12)],
        ),
        child: Text(formatKm(km), style: outfit(12 * scale, weight: FontWeight.w700)),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, this.scale);
  final String text;
  final double scale;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 2 * scale),
        decoration: BoxDecoration(color: const Color(0x4D000000), borderRadius: BorderRadius.circular(7 * scale)),
        child: Text(text, style: outfit(9.5 * scale, weight: FontWeight.w600)),
      );
}

/// Train / traffic / event card: round icon, title, subtitle, chips, chevron.
class ObjectCard extends StatelessWidget {
  const ObjectCard({
    super.key,
    required this.info,
    required this.style,
    required this.icon,
    required this.shown,
    required this.t,
    this.scale = 1,
    this.showIcon = true,
    this.onTap,
  });

  final CardInfo? info;
  final CardStyle style;
  final IconData icon;
  final bool shown;
  final double t;
  final double scale;
  final bool showIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final i = info;
    final l = l10n(context);
    return GlassCard(
      style: style,
      shown: shown && i != null,
      t: t,
      scale: scale,
      onTap: onTap,
      semanticLabel: i == null
          ? null
          : l.cardSemantics(i.title, i.subtitle.replaceAll('\n', ' '),
              i.distanceKm == null ? '' : l.distanceAway(formatKm(i.distanceKm))),
      padding: showIcon ? null : EdgeInsets.fromLTRB(12 * scale, 8 * scale, 10 * scale, 8 * scale),
      child: i == null
          ? const SizedBox.shrink()
          : Row(children: [
              if (showIcon) ...[
                Container(
                  width: 40 * scale,
                  height: 40 * scale,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: style.iconBg,
                    boxShadow: const [BoxShadow(color: Color(0x1FFFFFFF), spreadRadius: 3)],
                  ),
                  child: Icon(icon, size: 22 * scale, color: style.iconFg),
                ),
                SizedBox(width: 8 * scale),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Flexible(
                      child: Text(i.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: outfit(14.5 * scale, weight: FontWeight.w700, height: 1.1)),
                    ),
                    if (i.moreCount > 0) ...[
                      SizedBox(width: 5 * scale),
                      _Chip(l10n(context).moreCount(i.moreCount), scale),
                    ],
                  ]),
                  SizedBox(height: 2 * scale),
                  Text(i.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: outfit(10.5 * scale, color: const Color(0xE0FFFFFF), height: 1.25)),
                  SizedBox(height: 5 * scale),
                  Wrap(spacing: 6 * scale, runSpacing: 3 * scale, children: [
                    if (i.status != null) _StatusChip(i.status!, scale),
                    if (i.distanceKm != null && showIcon) _KmChip(i.distanceKm, style.badge, scale),
                    if (i.extra != null) _Chip(i.extra!, scale),
                  ]),
                ]),
              ),
              if (onTap != null) Icon(Icons.chevron_right_rounded, size: 18 * scale, color: const Color(0xCCFFFFFF)),
            ]),
    );
  }
}

/// Weather card: icon, condition, big temperature, "0 km", humidity / wind / rain.
class WeatherCard extends StatelessWidget {
  const WeatherCard(
      {super.key, required this.weather, required this.shown, required this.t, this.scale = 1, this.onTap});

  final Weather? weather;
  final bool shown;
  final double t;
  final double scale;
  final VoidCallback? onTap;

  IconData get _icon => switch (weather?.visual) {
        WeatherVisual.sun => Icons.wb_sunny_rounded,
        WeatherVisual.partlyCloudy => Icons.wb_cloudy_rounded,
        WeatherVisual.rain => Icons.grain_rounded,
        WeatherVisual.storm => Icons.thunderstorm_rounded,
        WeatherVisual.snow => Icons.ac_unit_rounded,
        WeatherVisual.fog => Icons.foggy,
        _ => Icons.cloud_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final w = weather;
    final s = scale;
    final li = outfit(9.5 * s, color: const Color(0xE6FFFFFF), height: 1.55);
    final l = l10n(context);
    return GlassCard(
      style: CardStyle.weather,
      shown: shown && w != null,
      t: t,
      scale: s,
      onTap: onTap,
      semanticLabel: w == null
          ? null
          : '${l.cardWeather}: ${w.label}, ${w.temperatureC.round()}°C, '
              '${l.humidity(w.humidityPct)}, ${l.wind(w.windKmh.round())}, ${l.rain(w.rainPct)}',
      padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 8 * s),
      child: w == null
          ? const SizedBox.shrink()
          : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Icon(_icon, size: 28 * s, color: const Color(0xFFFFC928)),
                SizedBox(width: 6 * s),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n(context).cardWeather, style: outfit(14.5 * s, weight: FontWeight.w700, height: 1.1)),
                    Text(w.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: outfit(10.5 * s, color: const Color(0xE0FFFFFF))),
                  ]),
                ),
                if (onTap != null) Icon(Icons.chevron_right_rounded, size: 16 * s, color: const Color(0xCCFFFFFF)),
              ]),
              SizedBox(height: 4 * s),
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${w.temperatureC.round()}°C', style: outfit(25 * s, weight: FontWeight.w700, height: 1)),
                  SizedBox(height: 5 * s),
                  _KmChip(0, CardStyle.weather.badge, s),
                ]),
                SizedBox(width: 8 * s),
                // Flexible + scale-down so long values never overflow the card.
                Flexible(
                  child: Container(
                    padding: EdgeInsets.only(left: 8 * s),
                    decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0x33FFFFFF)))),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l10n(context).humidity(w.humidityPct), style: li),
                        Text(l10n(context).wind(w.windKmh.round()), style: li),
                        Text(l10n(context).rain(w.rainPct), style: li),
                      ]),
                    ),
                  ),
                ),
              ]),
            ]),
    );
  }
}
