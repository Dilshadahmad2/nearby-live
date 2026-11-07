import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../core/geo/geo_point.dart';
import '../../core/geo/geo_utils.dart';
import 'train.dart';
import 'train_data_source.dart';

/// A train position estimated by the Nearby Live backend from the Indian
/// Railways timetable and station coordinates.
class BackendTrainEstimate {
  const BackendTrainEstimate({
    required this.number,
    required this.name,
    required this.fromCode,
    required this.toCode,
    required this.status,
    required this.position,
    required this.bearingDeg,
    required this.speedKmh,
    required this.distanceKm,
    this.prevCode,
    this.nextCode,
    this.prevPoint,
    this.nextPoint,
  });

  final String number;
  final String name;
  final String fromCode;
  final String toCode;

  /// `running` or `at_station`.
  final String status;
  final GeoPoint position;
  final double bearingDeg;
  final double speedKmh;
  final double distanceKm;
  final String? prevCode;
  final String? nextCode;
  final GeoPoint? prevPoint;
  final GeoPoint? nextPoint;
}

GeoPoint? _point(Object? j) {
  if (j is! Map) return null;
  final lat = j['lat'], lon = j['lon'];
  if (lat is! num || lon is! num) return null;
  return GeoPoint(lat.toDouble(), lon.toDouble());
}

/// Parses `GET /v1/trains/nearby`. Items without a location are skipped.
List<BackendTrainEstimate> parseNearbyTrains(Map<String, dynamic> json) {
  final items = json['items'];
  if (items is! List) return const [];
  final out = <BackendTrainEstimate>[];
  for (final it in items) {
    if (it is! Map) continue;
    final t = it['train'], p = it['position'];
    if (t is! Map || p is! Map) continue;
    final loc = _point(p['location']);
    if (loc == null) continue;
    final prev = p['prev_stop'], next = p['next_stop'];
    out.add(BackendTrainEstimate(
      number: '${t['number'] ?? ''}',
      name: '${t['name'] ?? ''}',
      fromCode: '${t['from_code'] ?? ''}',
      toCode: '${t['to_code'] ?? ''}',
      status: '${p['status'] ?? ''}',
      position: loc,
      bearingDeg: (p['bearing_deg'] as num?)?.toDouble() ?? 0,
      speedKmh: (p['speed_kmh'] as num?)?.toDouble() ?? 0,
      distanceKm: (it['distance_km'] as num?)?.toDouble() ?? 0,
      prevCode: prev is Map ? prev['code']?.toString() : null,
      nextCode: next is Map ? next['code']?.toString() : null,
      prevPoint: prev is Map ? _point(prev['location']) : null,
      nextPoint: next is Map ? _point(next['location']) : null,
    ));
  }
  return out;
}

/// Trains from the backend (`BACKEND_URL`), snapped onto the real OSM rail
/// line near each estimate so the 3D model runs on the track. When no rail
/// line is close, the train runs on the straight line between its previous
/// and next stations.
class BackendTrainSource implements TrainDataSource {
  BackendTrainSource(this._dio, this._baseUrl, this._rails, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Dio _dio;
  final String _baseUrl;
  final RailGeometryRepository _rails;
  final DateTime Function() _clock;

  @override
  Future<List<Train>> nearbyTrains(GeoPoint center, double radiusKm) async {
    final res = await _dio.get<Map<String, dynamic>>('$_baseUrl/v1/trains/nearby', queryParameters: {
      'lat': center.lat.toStringAsFixed(5),
      'lon': center.lon.toStringAsFixed(5),
      'radius_km': radiusKm.toStringAsFixed(1),
      'limit': 10,
    });
    final estimates = parseNearbyTrains(res.data ?? const {});
    List<List<GeoPoint>> rails = const [];
    try {
      rails = await _rails.railRoutes(center, radiusKm);
    } catch (_) {
      // Overpass unavailable: fall back to station-to-station lines.
    }
    final now = _clock();
    return [for (final e in estimates) snapToRail(e, rails, now)];
  }
}

/// Builds a [Train] for [e] on the nearest rail route (≤ 400 m away),
/// oriented along the estimate's bearing.
Train snapToRail(BackendTrainEstimate e, List<List<GeoPoint>> rails, DateTime now) {
  List<GeoPoint>? best;
  var bestD = 0.4; // km
  for (final r in rails) {
    final d = distanceToPolylineKm(e.position, r);
    if (d < bestD) {
      bestD = d;
      best = r;
    }
  }
  var route = best ??
      [
        e.prevPoint ?? destinationPoint(e.position, e.bearingDeg + 180, 2),
        e.position,
        e.nextPoint ?? destinationPoint(e.position, e.bearingDeg, 2),
      ];
  final proj = LocalProjector(e.position);
  var line = Polyline.fromGeo(route, proj);
  var arc = line.nearestArc(e.position);
  // Orient the route so increasing arc length matches the direction of travel.
  final ahead = line.at(math.min(line.length, arc + 30)).bearing;
  final diff = ((ahead - e.bearingDeg + 540) % 360) - 180;
  if (diff.abs() > 90) {
    route = route.reversed.toList();
    line = Polyline.fromGeo(route, proj);
    arc = line.nearestArc(e.position);
  }
  final stopped = e.status == 'at_station';
  return Train(
    id: 'ir-${e.number}',
    name: e.name,
    number: e.number,
    from: e.fromCode,
    to: e.toCode,
    route: route,
    arcM: arc,
    speedMs: stopped ? 0 : e.speedKmh / 3.6,
    position: line.geoAt(arc),
    fixTime: now,
    status: stopped ? TrainStatus.stopped : TrainStatus.moving,
  );
}
