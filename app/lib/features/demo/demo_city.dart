import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo/geo_point.dart';

/// OSM extract of Old Delhi used by the demo (`assets/demo/city-old-delhi.json`,
/// same file as `prototype/city-old-delhi.json`).
class DemoCity {
  const DemoCity({required this.train, required this.routes, required this.rail});

  /// Railway line the demo train runs on.
  final List<GeoPoint> train;

  /// Ring Road / major roads used for the traffic jam.
  final List<List<GeoPoint>> routes;

  /// Other rail ways.
  final List<List<GeoPoint>> rail;

  static List<GeoPoint> _line(Object? raw) => [
        if (raw is List)
          for (final c in raw)
            if (c is List && c.length >= 2) GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ];

  factory DemoCity.fromJson(Map<String, dynamic> j) => DemoCity(
        train: _line(j['train']),
        routes: [for (final r in (j['routes'] as List? ?? const [])) _line(r)],
        rail: [for (final r in (j['rail'] as List? ?? const [])) _line(r)],
      );
}

final demoCityProvider = FutureProvider<DemoCity>((ref) async {
  final raw = await rootBundle.loadString('assets/demo/city-old-delhi.json');
  return DemoCity.fromJson(jsonDecode(raw) as Map<String, dynamic>);
});
