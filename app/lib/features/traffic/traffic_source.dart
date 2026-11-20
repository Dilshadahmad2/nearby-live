import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/geo/geo_point.dart';
import '../../core/geo/geo_utils.dart';
import '../../core/osm/overpass_api.dart';
import 'traffic.dart';

abstract interface class TrafficDataSource {
  bool get isMock;
  Future<List<TrafficSegment>> segments(GeoPoint center, double radiusKm);
}

/// TomTom Traffic Flow API: samples flow segments on a ring pattern around
/// the user inside the range.
class TomTomTrafficSource implements TrafficDataSource {
  TomTomTrafficSource(this._dio, this._key);
  final Dio _dio;
  final String _key;

  @override
  bool get isMock => false;

  static const _url = 'https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/10/json';

  @override
  Future<List<TrafficSegment>> segments(GeoPoint center, double radiusKm) async {
    final samples = samplePoints(center, radiusKm);
    final results = await Future.wait(samples.map((p) async {
      try {
        final res = await _dio.get<Map<String, dynamic>>(_url, queryParameters: {
          'point': '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}',
          'unit': 'KMPH',
          'key': _key,
        });
        return parseTomTomFlow(res.data ?? const {});
      } catch (_) {
        return null;
      }
    }));
    // De-duplicate segments that several samples snapped onto.
    final seen = <String>{};
    final out = <TrafficSegment>[];
    for (final s in results.whereType<TrafficSegment>()) {
      if (seen.add(s.id)) out.add(s);
    }
    return out;
  }

  /// Centre plus two rings (6 + 6 points) at 25 % and 60 % of the range,
  /// capped at 8 km so samples stay on city roads.
  static List<GeoPoint> samplePoints(GeoPoint c, double radiusKm) {
    final r = math.min(radiusKm, 8.0);
    return [
      c,
      for (var i = 0; i < 6; i++) destinationPoint(c, i * 60.0, r * .25),
      for (var i = 0; i < 6; i++) destinationPoint(c, 30 + i * 60.0, r * .6),
    ];
  }
}

/// Parses a TomTom `flowSegmentData` response.
TrafficSegment? parseTomTomFlow(Map<String, dynamic> json) {
  final f = json['flowSegmentData'];
  if (f is! Map) return null;
  final coords = f['coordinates'];
  final list = coords is Map ? coords['coordinate'] : null;
  if (list is! List || list.length < 2) return null;
  final pts = <GeoPoint>[
    for (final c in list)
      if (c is Map && c['latitude'] is num && c['longitude'] is num)
        GeoPoint((c['latitude'] as num).toDouble(), (c['longitude'] as num).toDouble()),
  ];
  if (pts.length < 2) return null;
  final first = pts.first, last = pts.last;
  return TrafficSegment(
    id: '${first.lat.toStringAsFixed(5)},${first.lon.toStringAsFixed(5)}-${last.lat.toStringAsFixed(5)},${last.lon.toStringAsFixed(5)}',
    points: pts,
    currentSpeedKmh: (f['currentSpeed'] as num?)?.toDouble() ?? 0,
    freeFlowSpeedKmh: (f['freeFlowSpeed'] as num?)?.toDouble() ?? 0,
    closed: f['roadClosure'] == true,
    roadName: frcLabel(f['frc']?.toString()),
  );
}

/// TomTom functional road class → readable label.
String? frcLabel(String? frc) => switch (frc) {
      'FRC0' => 'Motorway',
      'FRC1' => 'Major Road',
      'FRC2' => 'Main Road',
      'FRC3' => 'Secondary Road',
      'FRC4' => 'Connecting Road',
      'FRC5' || 'FRC6' => 'Local Road',
      _ => null,
    };

/// Used when no TomTom key is set: real major roads from Overpass with
/// deterministic, slowly varying congestion.
class MockTrafficSource implements TrafficDataSource {
  MockTrafficSource(this._overpass);
  final OverpassApi _overpass;

  @override
  bool get isMock => true;

  @override
  Future<List<TrafficSegment>> segments(GeoPoint center, double radiusKm) async {
    final ways = await _overpass.majorRoads(boundingBox(center, math.min(radiusKm, 6.0)));
    return mockSegmentsFromWays(ways, DateTime.now());
  }
}

/// Assigns congestion to [ways] from a hash of the way id and the time of day
/// so jams stay put between polls but shift through the day.
List<TrafficSegment> mockSegmentsFromWays(List<OsmWay> ways, DateTime now) {
  final slot = now.millisecondsSinceEpoch ~/ (15 * 60 * 1000);
  final out = <TrafficSegment>[];
  for (final w in ways.take(80)) {
    final h = ((w.id * 2654435761) ^ (slot * 40503)) & 0xFFFF;
    final ratio = 0.2 + (h / 0xFFFF) * 0.9; // 0.2 .. 1.1
    const free = 50.0;
    out.add(TrafficSegment(
      id: 'osm-${w.id}',
      points: w.points,
      currentSpeedKmh: free * math.min(1.0, ratio),
      freeFlowSpeedKmh: free,
      roadName: w.name,
    ));
  }
  return out;
}

final trafficSourceProvider = Provider<TrafficDataSource>((ref) {
  const key = AppConfig.tomTomKey;
  if (key.isEmpty) return MockTrafficSource(ref.watch(overpassApiProvider));
  return TomTomTrafficSource(ref.watch(dioProvider), key);
});
