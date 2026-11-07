import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../alerts/alerts.dart';
import 'settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final c = ref.read(settingsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _Header('Map'),
          _StyleTile(
            selected: s.mapStyle == MapStyleKind.satellite,
            onTap: () => c.setMapStyle(MapStyleKind.satellite),
            title: 'Satellite 3D',
            subtitle: 'Esri World Imagery with translucent 3D buildings',
          ),
          _StyleTile(
            selected: s.mapStyle == MapStyleKind.neon,
            onTap: () => c.setMapStyle(MapStyleKind.neon),
            title: 'Neon city',
            subtitle: 'Navy land, cyan water, neon roads, buildings coloured by height',
          ),
          const _Header('Range'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              segments: [for (final r in AppConfig.ranges) ButtonSegment(value: r, label: Text('$r km'))],
              selected: {s.rangeKm},
              onSelectionChanged: (v) => c.setRange(v.first),
            ),
          ),
          const _Header('Location'),
          SwitchListTile(
            value: s.demo == DemoPreference.always,
            onChanged: (v) => c.setDemo(v ? DemoPreference.always : DemoPreference.auto),
            title: const Text('Demo mode (Old Delhi)'),
            subtitle: const Text('Replay the 40-second scenario near Red Fort instead of your real location. '
                'Used automatically when location permission is denied.'),
          ),
          const _Header('Alerts'),
          const _AlertsSection(),
          const _Header('Accessibility'),
          SwitchListTile(
            value: s.reduceMotion,
            onChanged: c.setReduceMotion,
            title: const Text('Reduce motion'),
            subtitle: const Text('Stops the camera sway, particles and scan effect'),
          ),
          const _Header('Data sources'),
          const _Source('Map', 'OpenFreeMap vector tiles · Esri World Imagery', true),
          const _Source('Weather', 'Open-Meteo (no key)', true),
          const _Source('Flights', 'OpenSky Network (anonymous)', true),
          const _Source('Rail geometry', 'OpenStreetMap via Overpass', true),
          _Source(
            'Road traffic',
            AppConfig.tomTomKey.isEmpty ? 'Simulated on real roads — build with --dart-define=TOMTOM_KEY=…' : 'TomTom Traffic Flow',
            AppConfig.tomTomKey.isNotEmpty,
          ),
          const _Source('Trains', 'Simulated on real rail lines (no free live API for India)', false),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Map data © OpenStreetMap contributors. Imagery © Esri, Maxar, Earthstar Geographics. '
              'Weather data by Open-Meteo.com. Flight data © The OpenSky Network.',
              style: outfit(12, color: AppColors.muted),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(text.toUpperCase(),
            style: outfit(12, weight: FontWeight.w600, color: AppColors.cyan).copyWith(letterSpacing: 1.6)),
      );
}

class _Source extends StatelessWidget {
  const _Source(this.name, this.detail, this.live);
  final String name;
  final String detail;
  final bool live;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        leading: Icon(Icons.circle, size: 10, color: live ? AppColors.green : AppColors.amber),
        title: Text(name),
        subtitle: Text(detail),
      );
}

class _StyleTile extends StatelessWidget {
  const _StyleTile({required this.selected, required this.onTap, required this.title, required this.subtitle});
  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
        selected: selected,
        selectedColor: AppColors.cyan,
        onTap: onTap,
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off),
        title: Text(title),
        subtitle: Text(subtitle),
      );
}

class _AlertsSection extends ConsumerWidget {
  const _AlertsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(alertSettingsProvider);
    final c = ref.read(alertSettingsProvider.notifier);
    Widget choice<T>(String label, T value, List<(T, String)> options, ValueChanged<T> onChanged) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(children: [
            Expanded(child: Text(label)),
            SegmentedButton<T>(
              showSelectedIcon: false,
              segments: [for (final (v, l) in options) ButtonSegment(value: v, label: Text(l))],
              selected: {value},
              onSelectionChanged: a.enabled ? (v) => onChanged(v.first) : null,
            ),
          ]),
        );
    return Column(children: [
      SwitchListTile(
        value: a.enabled,
        onChanged: (v) => c.update(a.copyWith(enabled: v)),
        title: const Text('Alerts & notifications'),
        subtitle: const Text('Trains nearby, flights overhead, watched trains running late'),
      ),
      choice<double>('Train within', a.trainKm, const [(0, 'Off'), (1, '1 km'), (2, '2 km'), (5, '5 km')],
          (v) => c.update(a.copyWith(trainKm: v))),
      choice<double>('Flight within', a.flightKm, const [(0, 'Off'), (2, '2 km'), (5, '5 km')],
          (v) => c.update(a.copyWith(flightKm: v))),
      choice<int>('Watched train late by', a.lateMin, const [(0, 'Off'), (15, '15m'), (30, '30m'), (60, '1h')],
          (v) => c.update(a.copyWith(lateMin: v))),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: TextFormField(
          enabled: a.enabled,
          initialValue: a.watchedTrains.join(', '),
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Watched train numbers',
            hintText: 'e.g. 12951, 12002 (empty = any train)',
          ),
          onFieldSubmitted: (v) => c.update(a.copyWith(watchedTrains: parseTrainNumbers(v))),
        ),
      ),
      SwitchListTile(
        value: a.quietStart >= 0,
        onChanged: a.enabled ? (v) => c.update(a.copyWith(quietStart: v ? 22 : -1, quietEnd: v ? 7 : -1)) : null,
        title: const Text('Quiet hours (22:00–07:00)'),
      ),
    ]);
  }
}

/// "12951, 12002 abc" → ["12951", "12002"].
List<String> parseTrainNumbers(String v) =>
    RegExp(r'\d{4,5}').allMatches(v).map((m) => m.group(0)!).toSet().toList();

