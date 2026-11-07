import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo/geo_utils.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../demo/demo_director.dart';
import '../nearby/application/nearby_controller.dart';
import '../nearby/scene/scene.dart';
import '../traffic/traffic.dart';
import '../weather/weather.dart';

/// Simple list screen for one category (bottom-nav tabs other than Nearby).
class CategoryListScreen extends ConsumerStatefulWidget {
  const CategoryListScreen({super.key, required this.kind, required this.bottomInset});
  final NearbyKind kind;
  final double bottomInset;

  @override
  ConsumerState<CategoryListScreen> createState() => _CategoryListScreenState();
}

class _CategoryListScreenState extends ConsumerState<CategoryListScreen> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    // Distances move with dead reckoning; refresh once a second.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  String get _title => switch (widget.kind) {
        NearbyKind.train => 'Trains',
        NearbyKind.flight => 'Flights',
        NearbyKind.traffic => 'Traffic',
        NearbyKind.weather => 'Weather',
        NearbyKind.event => 'Events',
      };

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(nearbyControllerProvider);
    final now = DateTime.now();
    final range = st.rangeKm.toDouble();
    final rows = st.isDemo ? _demoRows() : _liveRows(st, now, range);

    return Scaffold(
      backgroundColor: AppColors.page,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(_title, style: outfit(30, weight: FontWeight.w800)),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text(
                st.isDemo ? 'Demo mode · Old Delhi · ${st.rangeKm} km range' : 'Within ${st.rangeKm} km of you, nearest first',
                style: outfit(14, color: AppColors.muted),
              ),
            ),
          ),
          if (widget.kind == NearbyKind.weather && st.weather != null && !st.isDemo)
            SliverToBoxAdapter(child: _WeatherPanel(weather: st.weather!))
          else if (widget.kind == NearbyKind.weather && st.isDemo)
            SliverToBoxAdapter(child: _WeatherPanel(weather: DemoDirector.demoWeather)),
          if (rows.isEmpty && widget.kind != NearbyKind.weather)
            SliverToBoxAdapter(child: _Empty(kind: widget.kind, mode: st.mode))
          else
            SliverList.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.line),
              itemBuilder: (_, i) => rows[i],
            ),
          SliverToBoxAdapter(child: SizedBox(height: widget.bottomInset + 24)),
        ]),
      ),
    );
  }

  List<Widget> _liveRows(NearbyState st, DateTime now, double range) {
    switch (widget.kind) {
      case NearbyKind.train:
        return [
          for (final r in st.trainsByDistance(now))
            _Row(
              colour: AppColors.train,
              icon: Icons.train_rounded,
              title: '${r.item.name} · ${r.item.number}',
              subtitle: '${r.item.from} → ${r.item.to} · ${r.item.statusText}${r.item.estimated ? ' (estimated)' : ''}',
              km: r.distanceKm,
              inRange: r.distanceKm <= range,
            ),
        ];
      case NearbyKind.flight:
        return [
          for (final r in st.flightsByDistance(now))
            _Row(
              colour: AppColors.flight,
              icon: Icons.flight_rounded,
              title: r.item.state.callsign.isEmpty ? r.item.state.icao24.toUpperCase() : r.item.state.callsign,
              subtitle: '${r.item.route ?? r.item.state.originCountry} · ${(r.item.state.altitudeM).round()} m · '
                  '${(r.item.state.velocityMs * 3.6).round()} km/h',
              km: r.distanceKm,
              inRange: r.distanceKm <= range,
            ),
        ];
      case NearbyKind.traffic:
        return [
          for (final r in st.trafficByDistance())
            _Row(
              colour: _congestionColour(r.item.congestion),
              icon: Icons.directions_car_rounded,
              title: '${congestionLabel(r.item.congestion)}${r.item.roadName == null ? '' : ' · ${r.item.roadName}'}',
              subtitle: '${r.item.currentSpeedKmh.round()} / ${r.item.freeFlowSpeedKmh.round()} km/h'
                  '${st.trafficIsMock ? ' · simulated' : ' · TomTom'}',
              km: r.distanceKm,
              inRange: r.distanceKm <= range,
            ),
        ];
      case NearbyKind.weather:
      case NearbyKind.event:
        return const [];
    }
  }

  List<Widget> _demoRows() => switch (widget.kind) {
        NearbyKind.train => const [
            _Row(
                colour: AppColors.train,
                icon: Icons.train_rounded,
                title: 'Rajdhani Express · 12951',
                subtitle: 'NDLS → BPL · Moving (scripted)',
                km: 2.3,
                inRange: true),
          ],
        NearbyKind.flight => const [
            _Row(colour: AppColors.flight, icon: Icons.flight_rounded, title: 'AI138', subtitle: 'DEL → BOM · In Air', km: 4.8, inRange: true),
          ],
        NearbyKind.traffic => const [
            _Row(
                colour: AppColors.traffic,
                icon: Icons.directions_car_rounded,
                title: 'Heavy · Ring Road',
                subtitle: 'Scripted jam near Red Fort',
                km: 1.2,
                inRange: true),
          ],
        NearbyKind.event => const [
            _Row(
                colour: AppColors.event,
                icon: Icons.music_note_rounded,
                title: 'Music Fest 2025',
                subtitle: 'Today, 5 PM · demo event',
                km: 0.9,
                inRange: true),
          ],
        NearbyKind.weather => const [],
      };

  static Color _congestionColour(Congestion c) => switch (c) {
        Congestion.free => AppColors.green,
        Congestion.light => const Color(0xFFB8E04A),
        Congestion.moderate => AppColors.amber,
        Congestion.heavy || Congestion.closed => AppColors.red,
      };
}

class _Row extends StatelessWidget {
  const _Row({
    required this.colour,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.km,
    required this.inRange,
  });

  final Color colour;
  final IconData icon;
  final String title;
  final String subtitle;
  final double km;
  final bool inRange;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colour,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: colour.withValues(alpha: .55), blurRadius: 14)],
            ),
            child: Icon(icon, color: Colors.white, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: outfit(15, weight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: outfit(12.5, color: AppColors.muted)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(formatKm(km), style: outfit(14, weight: FontWeight.w700)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (inRange ? AppColors.green : AppColors.amber).withValues(alpha: .14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(inRange ? 'In range' : 'Out of range',
                  style: outfit(11, weight: FontWeight.w600, color: inRange ? AppColors.green : AppColors.amber)),
            ),
          ]),
        ]),
      );
}

class _WeatherPanel extends StatelessWidget {
  const _WeatherPanel({required this.weather});
  final Weather weather;

  @override
  Widget build(BuildContext context) {
    final w = weather;
    Widget stat(IconData i, String label, String value) => Expanded(
          child: Column(children: [
            Icon(i, color: AppColors.cyan, size: 22),
            const SizedBox(height: 6),
            Text(value, style: outfit(16, weight: FontWeight.w700)),
            Text(label, style: outfit(12, color: AppColors.muted)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(colors: [Color(0xF00E2260), Color(0xF0081440)]),
        border: Border.all(color: const Color(0x6678D2FF)),
        boxShadow: const [BoxShadow(color: Color(0x592FAAFF), blurRadius: 24)],
      ),
      child: Column(children: [
        Row(children: [
          Text('${w.temperatureC.round()}°C', style: outfit(44, weight: FontWeight.w800)),
          const SizedBox(width: 14),
          Expanded(child: Text(w.label, style: outfit(18, weight: FontWeight.w600))),
          Text('0 km', style: outfit(13, weight: FontWeight.w700, color: AppColors.cyan)),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          stat(Icons.water_drop_outlined, 'Humidity', '${w.humidityPct}%'),
          stat(Icons.air_rounded, 'Wind', '${w.windKmh.round()} km/h'),
          stat(Icons.umbrella_outlined, 'Rain', '${w.rainPct}%'),
        ]),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.kind, required this.mode});
  final NearbyKind kind;
  final NearbyMode mode;

  @override
  Widget build(BuildContext context) {
    final text = switch ((kind, mode)) {
      (_, NearbyMode.locating) => 'Finding your location…',
      (NearbyKind.event, _) => 'Events are coming in a later update (Ticketmaster / PredictHQ).',
      (NearbyKind.train, _) => 'No rail lines with trains found near you yet.',
      (NearbyKind.traffic, _) => 'No traffic data near you yet.',
      _ => 'Nothing nearby right now.',
    };
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, textAlign: TextAlign.center, style: outfit(15, color: AppColors.muted)),
    );
  }
}
