import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/geo/geo_point.dart';
import 'flight.dart';

/// Thrown when OpenSky answers HTTP 429 (rate limited).
class RateLimitedException implements Exception {
  const RateLimitedException([this.retryAfter]);
  final Duration? retryAfter;
  @override
  String toString() => 'RateLimitedException(retryAfter: $retryAfter)';
}

/// OpenSky Network `/api/states/all` (anonymous access).
class OpenSkyApi {
  OpenSkyApi(this._dio);
  final Dio _dio;

  static const _url = 'https://opensky-network.org/api/states/all';

  Future<List<FlightState>> states(GeoBounds box) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(_url, queryParameters: {
        'lamin': box.south.toStringAsFixed(4),
        'lomin': box.west.toStringAsFixed(4),
        'lamax': box.north.toStringAsFixed(4),
        'lomax': box.east.toStringAsFixed(4),
      });
      return parseOpenSkyStates(res.data ?? const {});
    } on DioException catch (e) {
      if (e.response?.statusCode == 429) {
        final ra = int.tryParse(e.response?.headers.value('x-rate-limit-retry-after-seconds') ?? '');
        throw RateLimitedException(ra == null ? null : Duration(seconds: ra));
      }
      rethrow;
    }
  }
}

/// Parses an OpenSky states response. Rows without a position are skipped.
///
/// Row layout: 0 icao24, 1 callsign, 2 origin_country, 3 time_position,
/// 4 last_contact, 5 longitude, 6 latitude, 7 baro_altitude, 8 on_ground,
/// 9 velocity, 10 true_track, 11 vertical_rate, 12 sensors, 13 geo_altitude, …
List<FlightState> parseOpenSkyStates(Map<String, dynamic> json) {
  final rows = json['states'];
  if (rows is! List) return const [];
  final responseTime = (json['time'] as num?)?.toInt();
  final out = <FlightState>[];
  for (final r in rows) {
    if (r is! List || r.length < 11) continue;
    final lon = (r[5] as num?)?.toDouble();
    final lat = (r[6] as num?)?.toDouble();
    if (lat == null || lon == null) continue;
    final tPos = (r[3] as num?)?.toInt() ?? (r[4] as num?)?.toInt() ?? responseTime;
    final geoAlt = r.length > 13 ? (r[13] as num?)?.toDouble() : null;
    out.add(FlightState(
      icao24: '${r[0] ?? ''}',
      callsign: '${r[1] ?? ''}'.trim(),
      originCountry: '${r[2] ?? ''}',
      position: GeoPoint(lat, lon),
      altitudeM: geoAlt ?? (r[7] as num?)?.toDouble() ?? 0,
      onGround: r[8] == true,
      velocityMs: (r[9] as num?)?.toDouble() ?? 0,
      trackDeg: (r[10] as num?)?.toDouble() ?? 0,
      fixTime: tPos == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(tPos * 1000, isUtc: true),
    ));
  }
  return out;
}

/// Callsign → route text ("DEL → BOM") from adsbdb.com, cached per callsign.
class FlightRouteLookup {
  FlightRouteLookup(this._dio);
  final Dio _dio;
  final _cache = <String, String?>{};

  Future<String?> route(String callsign) async {
    final cs = callsign.trim().toUpperCase();
    if (cs.isEmpty) return null;
    if (_cache.containsKey(cs)) return _cache[cs];
    try {
      final res = await _dio.get<Map<String, dynamic>>('https://api.adsbdb.com/v0/callsign/$cs');
      return _cache[cs] = parseAdsbdbRoute(res.data ?? const {});
    } catch (_) {
      return _cache[cs] = null;
    }
  }
}

/// Parses an adsbdb callsign response into "DEL → BOM".
String? parseAdsbdbRoute(Map<String, dynamic> json) {
  final resp = json['response'];
  if (resp is! Map) return null;
  final fr = resp['flightroute'];
  if (fr is! Map) return null;
  String? code(Object? a) {
    if (a is! Map) return null;
    return (a['iata_code'] ?? a['icao_code'])?.toString();
  }

  final o = code(fr['origin']);
  final d = code(fr['destination']);
  if (o == null || d == null) return null;
  return '$o → $d';
}

/// Exponential back-off used after HTTP 429.
class Backoff {
  Backoff({required this.base, this.max = const Duration(minutes: 5)}) : _current = base;

  final Duration base;
  final Duration max;
  Duration _current;

  Duration get current => _current;

  Duration fail([Duration? hint]) {
    final doubled = Duration(milliseconds: _current.inMilliseconds * 2);
    var next = hint != null && hint > doubled ? hint : doubled;
    if (next > max) next = max;
    return _current = next;
  }

  Duration succeed() => _current = base;
}

final openSkyApiProvider = Provider<OpenSkyApi>((ref) => OpenSkyApi(ref.watch(dioProvider)));
final flightRouteLookupProvider = Provider<FlightRouteLookup>((ref) => FlightRouteLookup(ref.watch(dioProvider)));
