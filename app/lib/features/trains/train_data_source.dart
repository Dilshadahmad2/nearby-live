import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/geo/geo_point.dart';
import '../../core/geo/geo_utils.dart';
import '../../core/osm/overpass_api.dart';
import 'backend_train_source.dart';
import 'train.dart';

/// Source of live (or estimated) train positions. India has no free official
/// live-train API, so the app ships a mock; a freemium provider can implement
/// this interface later (snap its lat/lon with [Polyline.nearestArc], or
/// interpolate between stations along the rail geometry).
abstract interface class TrainDataSource {
  Future<List<Train>> nearbyTrains(GeoPoint center, double radiusKm);
}

/// Rail lines in range from Overpass, stitched into continuous routes and
/// cached per area.
class RailGeometryRepository {
  RailGeometryRepository(this._overpass);
  final OverpassApi _overpass;

  GeoPoint? _cacheCenter;
  double _cacheRadius = 0;
  List<List<GeoPoint>> _cache = const [];

  Future<List<List<GeoPoint>>> railRoutes(GeoPoint center, double radiusKm) async {
    // Rail density is high in cities; cap the query area.
    final r = math.min(radiusKm, 12.0);
    final c = _cacheCenter;
    if (c != null && _cacheRadius >= r && haversineKm(c, center) < r * .3) return _cache;
    final ways = await _overpass.railLines(boundingBox(center, r));
    _cache = stitchWays([for (final w in ways) w.points]);
    _cacheCenter = center;
    _cacheRadius = r;
    return _cache;
  }
}

/// Runs a few named trains along the real rail lines near the user. Positions
/// are a pure function of wall-clock time, so every poll agrees with the last.
class MockTrainSource implements TrainDataSource {
  MockTrainSource(this._rails, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final RailGeometryRepository _rails;
  final DateTime Function() _clock;

  static const _catalogue = [
    ('Rajdhani Express', '12951', 'NDLS', 'BPL'),
    ('Shatabdi Express', '12002', 'NDLS', 'LKO'),
    ('Duronto Express', '12260', 'DLI', 'HWH'),
    ('Garib Rath', '12910', 'ANVT', 'BDTS'),
  ];

  @override
  Future<List<Train>> nearbyTrains(GeoPoint center, double radiusKm) async {
    final routes = await _rails.railRoutes(center, radiusKm);
    return mockTrainsOnRoutes(routes, center, _clock());
  }
}

/// Places up to 3 trains on the longest [routes] (≥ 1.5 km). Each loops along
/// its route at 14–28 m/s; the loop includes an off-route gap so trains come
/// and go.
List<Train> mockTrainsOnRoutes(List<List<GeoPoint>> routes, GeoPoint origin, DateTime now) {
  final proj = LocalProjector(origin);
  final out = <Train>[];
  var i = 0;
  for (final r in routes) {
    if (out.length >= 3) break;
    final line = Polyline.fromGeo(r, proj);
    if (line.length < 1500) continue;
    final (name, number, from, to) = MockTrainSource._catalogue[i % MockTrainSource._catalogue.length];
    final speed = 14.0 + (i * 5) % 15;
    const gap = 2500.0;
    final loop = line.length + gap;
    final t = now.millisecondsSinceEpoch / 1000.0;
    final arc = ((t * speed) + i * 3100) % loop - gap / 2;
    final forward = i.isEven;
    final s = forward ? arc : line.length - arc;
    out.add(Train(
      id: 'mock-$number',
      name: name,
      number: number,
      from: forward ? from : to,
      to: forward ? to : from,
      route: forward ? r : r.reversed.toList(),
      arcM: forward ? s : line.length - s,
      speedMs: speed,
      position: line.geoAt(s.clamp(0.0, line.length)),
      fixTime: now,
    ));
    i++;
  }
  return out;
}

final railGeometryProvider = Provider<RailGeometryRepository>((ref) => RailGeometryRepository(ref.watch(overpassApiProvider)));

/// Backend timetable estimates when `BACKEND_URL` is set, otherwise the mock.
final trainDataSourceProvider = Provider<TrainDataSource>((ref) {
  final rails = ref.watch(railGeometryProvider);
  const url = AppConfig.backendUrl;
  if (url.isEmpty) return MockTrainSource(rails);
  return BackendTrainSource(ref.watch(dioProvider), url.endsWith('/') ? url.substring(0, url.length - 1) : url, rails);
});
