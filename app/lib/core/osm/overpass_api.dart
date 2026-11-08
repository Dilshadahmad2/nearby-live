import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../geo/geo_point.dart';
import '../geo/geo_utils.dart';

/// An OSM way with its geometry.
class OsmWay {
  const OsmWay({required this.id, required this.points, this.tags = const {}});
  final int id;
  final List<GeoPoint> points;
  final Map<String, String> tags;

  String? get name => tags['name'] ?? tags['ref'];
}

/// Overpass API client (free, no key). Used for rail geometry and, when no
/// TomTom key is configured, for the major roads the mock traffic runs on.
class OverpassApi {
  OverpassApi(this._dio);
  final Dio _dio;

  static const _url = 'https://overpass-api.de/api/interpreter';

  Future<List<OsmWay>> railLines(GeoBounds b) =>
      _ways('way["railway"="rail"]["service"!~"yard|siding|spur"]', b);

  Future<List<OsmWay>> majorRoads(GeoBounds b) =>
      _ways('way["highway"~"^(motorway|trunk|primary)\$"]', b);

  Future<List<OsmWay>> _ways(String selector, GeoBounds b) async {
    final bbox = '${b.south},${b.west},${b.north},${b.east}';
    final query = '[out:json][timeout:25];$selector($bbox);out geom;';
    final res = await _dio.post<Map<String, dynamic>>(
      _url,
      data: {'data': query},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    return parseOverpassWays(res.data ?? const {});
  }
}

/// Parses `out geom` way elements.
List<OsmWay> parseOverpassWays(Map<String, dynamic> json) {
  final els = json['elements'];
  if (els is! List) return const [];
  final out = <OsmWay>[];
  for (final e in els) {
    if (e is! Map || e['type'] != 'way') continue;
    final geom = e['geometry'];
    if (geom is! List || geom.length < 2) continue;
    final pts = <GeoPoint>[
      for (final g in geom)
        if (g is Map && g['lat'] is num && g['lon'] is num)
          GeoPoint((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
    ];
    if (pts.length < 2) continue;
    final tags = <String, String>{};
    final t = e['tags'];
    if (t is Map) t.forEach((k, v) => tags['$k'] = '$v');
    out.add(OsmWay(id: (e['id'] as num?)?.toInt() ?? 0, points: pts, tags: tags));
  }
  return out;
}

/// Greedily joins ways whose ends meet (within [toleranceM]) into longer
/// continuous routes, longest first.
List<List<GeoPoint>> stitchWays(List<List<GeoPoint>> ways, {double toleranceM = 8}) {
  final pool = [for (final w in ways) List<GeoPoint>.of(w)];
  final tolKm = toleranceM / 1000;
  bool near(GeoPoint a, GeoPoint b) => haversineKm(a, b) <= tolKm;
  final routes = <List<GeoPoint>>[];
  while (pool.isNotEmpty) {
    final cur = pool.removeLast();
    var grown = true;
    while (grown) {
      grown = false;
      for (var i = 0; i < pool.length; i++) {
        final w = pool[i];
        if (near(cur.last, w.first)) {
          cur.addAll(w.skip(1));
        } else if (near(cur.last, w.last)) {
          cur.addAll(w.reversed.skip(1));
        } else if (near(cur.first, w.last)) {
          cur.insertAll(0, w.take(w.length - 1));
        } else if (near(cur.first, w.first)) {
          cur.insertAll(0, w.reversed.take(w.length - 1));
        } else {
          continue;
        }
        pool.removeAt(i);
        grown = true;
        break;
      }
    }
    routes.add(cur);
  }
  double len(List<GeoPoint> l) {
    var s = 0.0;
    for (var i = 1; i < l.length; i++) {
      s += haversineKm(l[i - 1], l[i]);
    }
    return s;
  }

  routes.sort((a, b) => len(b).compareTo(len(a)));
  return routes;
}

final overpassApiProvider = Provider<OverpassApi>((ref) => OverpassApi(ref.watch(dioProvider)));
